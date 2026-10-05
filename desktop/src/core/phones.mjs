import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { runtimeVersion } from './catalog.mjs';
import { runProcess } from './process.mjs';
import { sdkEnvironment } from './platform.mjs';

export const SDK_MARKER = '.droiddock-managed';
const PHONE_MARKER = '.droiddock-phone.json';
const MAX_FILE = 1024 * 1024;
const phoneID = (id) =>
  typeof id === 'string' && /^DroidDock_Phone_API_[1-9][0-9]{1,3}(?:_[0-9]{1,3})?_x86_64$/.test(id);
export async function lstatOrNull(file) {
  try {
    return await fs.lstat(file);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

export async function safeDirectory(directory, { create = false } = {}) {
  if (
    typeof directory !== 'string' ||
    !path.isAbsolute(directory) ||
    /[\u0000-\u001f\u007f]/.test(directory)
  )
    throw new Error('Invalid private directory.');
  const absolute = path.resolve(directory),
    parent = path.dirname(absolute);
  if (parent !== absolute) await safeDirectory(parent, { create });
  const info = await lstatOrNull(absolute);
  if (!info) {
    if (create) {
      try {
        await fs.mkdir(absolute, { mode: 0o700 });
      } catch (e) {
        if (e.code !== 'EEXIST') throw e;
      }
      return safeDirectory(absolute);
    }
    return;
  }
  if (info.isDirectory() && !info.isSymbolicLink()) return;
  // Native macOS fixture homes can use these OS-owned aliases. User-created
  // directory links remain disallowed on every platform.
  const alias = { '/var': '/private/var', '/tmp': '/private/tmp', '/etc': '/private/etc' }[
    absolute
  ];
  if (
    process.platform === 'darwin' &&
    alias &&
    info.isSymbolicLink() &&
    (await fs.realpath(absolute)) === alias
  )
    return;
  throw new Error(`Refusing a linked or non-directory path: ${absolute}`);
}

export function assertPrivatePaths(paths) {
  if (!paths || typeof paths.root !== 'string' || !path.isAbsolute(paths.root))
    throw new Error('Invalid managed Android paths.');
  for (const [key, suffix] of Object.entries({ sdk: 'sdk', avd: 'avd', userHome: 'user-home' })) {
    if (paths[key] !== path.join(paths.root, suffix))
      throw new Error(`The ${key} directory is outside the managed Android layout.`);
  }
}

export async function snapshot(file, { optional = false } = {}) {
  await safeDirectory(path.dirname(file));
  const info = await lstatOrNull(file);
  if (!info) {
    if (optional) return null;
    throw new Error(`Missing file: ${file}`);
  }
  if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_FILE)
    throw new Error(`Unsafe or oversized file: ${file}`);
  const handle = await fs.open(
    file,
    constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0),
  );
  try {
    const before = await handle.stat();
    if (
      !before.isFile() ||
      before.size > MAX_FILE ||
      before.ino !== info.ino ||
      before.dev !== info.dev
    )
      throw new Error(`File changed: ${file}`);
    const bytes = Buffer.alloc(before.size);
    let offset = 0;
    while (offset < bytes.length) {
      const result = await handle.read(bytes, offset, bytes.length - offset, offset);
      if (!result.bytesRead) break;
      offset += result.bytesRead;
    }
    const after = await handle.stat();
    if (offset !== bytes.length || before.size !== after.size || before.mtimeMs !== after.mtimeMs)
      throw new Error(`File changed: ${file}`);
    return {
      bytes,
      ino: after.ino,
      dev: after.dev,
      mode: after.mode & 0o777,
      mtimeMs: after.mtimeMs,
    };
  } finally {
    await handle.close();
  }
}

export async function requireSnapshot(file, expected) {
  const actual = await snapshot(file, { optional: true });
  if (!actual && !expected) return;
  if (
    !actual ||
    !expected ||
    actual.ino !== expected.ino ||
    actual.dev !== expected.dev ||
    actual.mode !== expected.mode ||
    !actual.bytes.equals(expected.bytes)
  )
    throw new Error(`File changed during this operation; it was preserved: ${file}`);
}

export async function writeExclusive(file, bytes, mode = 0o600) {
  await safeDirectory(path.dirname(file));
  const handle = await fs.open(file, 'wx', mode);
  try {
    await handle.writeFile(bytes);
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function replaceFile(file, bytes, original) {
  const temporary = path.join(path.dirname(file), `.droiddock-config-${crypto.randomUUID()}`);
  try {
    await writeExclusive(temporary, bytes, original.mode);
    await requireSnapshot(file, original);
    await fs.rename(temporary, file);
  } finally {
    await fs.unlink(temporary).catch((error) => {
      if (error.code !== 'ENOENT') throw error;
    });
  }
}

export async function withOperationLock(paths, name, callback) {
  assertPrivatePaths(paths);
  if (!/^[a-zA-Z0-9_.-]+$/.test(name)) throw new Error('Invalid operation lock.');
  const locks = path.join(paths.root, '.locks'),
    directory = path.join(locks, name);
  await safeDirectory(locks, { create: true });
  try {
    await fs.mkdir(directory, { mode: 0o700 });
  } catch (error) {
    if (error.code === 'EEXIST')
      throw new Error(
        'Another DroidDock operation owns this phone or installation. If a previous process crashed, verify that it has stopped before removing the matching lock directory.',
      );
    throw error;
  }
  const token = crypto.randomUUID(),
    owner = path.join(directory, 'owner.json');
  try {
    await writeExclusive(
      owner,
      JSON.stringify({ pid: process.pid, token, createdAt: new Date().toISOString() }),
    );
    return await callback();
  } finally {
    const current = await snapshot(owner, { optional: true }).catch(() => null);
    if (current && JSON.parse(current.bytes.toString()).token === token) {
      await fs.unlink(owner);
      await fs.rmdir(directory);
    }
  }
}

export function withPhoneOperation(paths, id, callback) {
  if (!phoneID(id)) throw new Error('Invalid managed phone ID.');
  return withOperationLock(paths, `phone-${id}`, callback);
}

export function readINI(bytes) {
  const result = Object.create(null);
  const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  if (text.includes('\0')) throw new Error('Invalid configuration text.');
  for (const line of text.split(/\r\n|\n|\r/)) {
    const trimmed = line.trim();
    if (!trimmed || /^[#;]/.test(trimmed)) continue;
    const separator = trimmed.indexOf('=');
    if (separator > 0)
      result[trimmed.slice(0, separator).trim()] = trimmed.slice(separator + 1).trim();
  }
  return result;
}

async function loadPhone(paths, id) {
  assertPrivatePaths(paths);
  if (!phoneID(id)) throw new Error('Invalid managed phone ID.');
  const directory = path.join(paths.avd, `${id}.avd`),
    configPath = path.join(directory, 'config.ini'),
    indexPath = path.join(paths.avd, `${id}.ini`);
  await safeDirectory(directory);
  const marker = await snapshot(path.join(directory, PHONE_MARKER)),
    configuration = await snapshot(configPath),
    index = await snapshot(indexPath);
  const ownership = JSON.parse(marker.bytes.toString('utf8'));
  const version = runtimeVersion(ownership.imageId),
    config = readINI(configuration.bytes),
    indexValues = readINI(index.bytes);
  if (
    ownership.id !== id ||
    version.deviceName !== id ||
    path.resolve(indexValues.path ?? '.') !== directory ||
    config['image.sysdir.1'] !== `${version.imagePath}/`
  )
    throw new Error(`Phone ownership or image configuration changed: ${id}`);
  const number = (key, fallback) =>
    /^\d+$/.test(config[key] ?? '') ? Number(config[key]) : fallback;
  const phone = {
    id,
    name: config['avd.ini.displayname'] || version.title,
    api: version.api,
    abi: version.abi,
    width: number('hw.lcd.width', 1080),
    height: number('hw.lcd.height', 2400),
    memory: number('hw.ramSize', 2048),
    cores: number('hw.cpu.ncore', 4),
    density: number('hw.lcd.density', 420),
    configPath,
    imageId: version.id,
  };
  return { phone, directory, indexPath, marker, configuration, index };
}

export async function listPhones(paths) {
  assertPrivatePaths(paths);
  await safeDirectory(paths.avd);
  const info = await lstatOrNull(paths.avd);
  if (!info) return [];
  const names = await fs.readdir(paths.avd),
    phones = [];
  for (const name of names) {
    if (!name.endsWith('.avd') || !phoneID(name.slice(0, -4))) continue;
    const marker = await lstatOrNull(path.join(paths.avd, name, PHONE_MARKER));
    if (marker) phones.push((await loadPhone(paths, name.slice(0, -4))).phone);
  }
  return phones.sort((a, b) => a.name.localeCompare(b.name));
}

export async function createPhone({ paths, version }) {
  const identity = runtimeVersion(version.id);
  return withPhoneOperation(paths, identity.deviceName, async () => {
    await safeDirectory(paths.avd, { create: true });
    await safeDirectory(paths.userHome, { create: true });
    const image = path.join(paths.sdk, identity.imagePath);
    await safeDirectory(image);
    await snapshot(path.join(paths.sdk, SDK_MARKER));
    await snapshot(path.join(image, '.droiddock-package.json'));
    const id = identity.deviceName,
      directory = path.join(paths.avd, `${id}.avd`),
      index = path.join(paths.avd, `${id}.ini`);
    if (await lstatOrNull(directory)) return (await loadPhone(paths, id)).phone;
    if (await lstatOrNull(index)) throw new Error('An existing phone index was preserved.');
    await fs.mkdir(directory, { mode: 0o700 });
    const nonce = crypto.randomUUID(),
      reservation = path.join(directory, '.creating');
    let createdIndex = false;
    try {
      await writeExclusive(reservation, nonce);
      const config = {
        'avd.ini.encoding': 'UTF-8',
        'avd.ini.displayname': `${identity.title} Phone`,
        'abi.type': 'x86_64',
        'hw.cpu.arch': 'x86_64',
        'hw.cpu.ncore': '4',
        'hw.ramSize': '2048',
        'hw.lcd.width': '1080',
        'hw.lcd.height': '2400',
        'hw.lcd.density': '420',
        'hw.keyboard': 'yes',
        'hw.mainKeys': 'no',
        'hw.gpu.enabled': 'yes',
        'hw.gpu.mode': 'auto',
        'hw.accelerometer': 'yes',
        'hw.sensors.orientation': 'yes',
        'hw.audioInput': 'yes',
        'hw.battery': 'yes',
        'hw.gps': 'yes',
        'hw.camera.back': 'virtualscene',
        'hw.camera.front': 'emulated',
        'disk.dataPartition.size': '4G',
        'image.sysdir.1': `${identity.imagePath}/`,
        'tag.id': 'google_apis',
        'tag.display': 'Google APIs',
        target: `android-${identity.api}`,
        'PlayStore.enabled': 'false',
        'fastboot.forceColdBoot': 'no',
        'fastboot.forceFastBoot': 'yes',
        showDeviceFrame: 'no',
      };
      await writeExclusive(
        path.join(directory, 'config.ini'),
        Object.entries(config)
          .map(([key, value]) => `${key}=${value}\n`)
          .join(''),
      );
      await writeExclusive(
        path.join(directory, PHONE_MARKER),
        JSON.stringify({ id, imageId: identity.id, format: 1 }),
      );
      await writeExclusive(
        index,
        `avd.ini.encoding=UTF-8\npath=${directory}\ntarget=android-${identity.api}\n`,
      );
      createdIndex = true;
      await fs.unlink(reservation);
      return (await loadPhone(paths, id)).phone;
    } catch (error) {
      if (
        (await snapshot(reservation, { optional: true }).catch(() => null))?.bytes.toString() ===
        nonce
      ) {
        if (createdIndex) await fs.unlink(index).catch(() => {});
        await fs.rm(directory, { recursive: true });
      }
      throw error;
    }
  });
}

async function inspectProcesses({ phone, paths, run, platform }) {
  if (platform === 'linux') {
    const ownUID = process.getuid?.();
    const entries = await fs.readdir('/proc');
    for (const pid of entries.filter((name) => /^\d+$/.test(name))) {
      const directory = `/proc/${pid}`;
      try {
        const info = await fs.stat(directory);
        if (ownUID !== undefined && info.uid !== ownUID) continue;
        const command = (await fs.readFile(`${directory}/cmdline`)).toString('utf8').split('\0');
        if (!/(?:qemu|emulator)/i.test(path.basename(command[0] ?? ''))) continue;
        if (
          command.some(
            (value) =>
              value === phone.id ||
              value === `@${phone.id}` ||
              value.includes(phone.configPath) ||
              value.includes(`${phone.id}.avd`),
          )
        )
          throw new Error(
            'This phone has an external emulator process. Stop it before continuing.',
          );
        if (!command.includes('-avd') && !command.some((value) => value.startsWith('@')))
          throw new Error(
            'An emulator process cannot be identified safely. Stop external emulators before continuing.',
          );
      } catch (error) {
        if (['ENOENT', 'ESRCH'].includes(error.code)) continue;
        throw error;
      }
    }
  } else if (platform === 'win32') {
    const result = await run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(emulator|qemu.*)\\.exe$' } | Select-Object Name,CommandLine | ConvertTo-Json -Compress",
      ],
      { timeout: 15_000, maxBytes: 1024 * 1024 },
    );
    if (result.code !== 0)
      throw new Error(
        'Cannot inspect external emulator processes. Stop them before editing this phone.',
      );
    const records = result.stdout.trim() ? JSON.parse(result.stdout) : [];
    for (const record of Array.isArray(records) ? records : [records]) {
      if (
        !record.CommandLine ||
        record.CommandLine.includes(phone.id) ||
        record.CommandLine.includes(paths.avd)
      )
        throw new Error(
          'An external or unidentified emulator is running. Stop it before continuing.',
        );
    }
  } else throw new Error('External emulator inspection is unavailable on this platform.');
}

export async function requirePhoneStopped({
  paths,
  phone,
  run = runProcess,
  platform = paths.platform ?? process.platform,
  inspect = inspectProcesses,
}) {
  const current = await loadPhone(paths, phone.id);
  if (current.phone.configPath !== phone.configPath)
    throw new Error('Phone identity changed. Refresh the library.');
  for (const name of ['hardware-qemu.ini.lock', 'userdata-qemu.img.lock']) {
    const lock = path.join(current.directory, name),
      info = await lstatOrNull(lock);
    if (!info) continue;
    if (!info.isFile() || info.isSymbolicLink())
      throw new Error(
        `The phone has an active or unrecognized emulator lock (${name}). Stop the emulator before continuing.`,
      );
    const content = (await snapshot(lock)).bytes.toString().trim();
    // Upstream emulator PID files can have one terminating NUL byte.
    const match = /^([1-9][0-9]*)\0?$/.exec(content),
      pid = match ? Number(match[1]) : 0;
    if (!Number.isSafeInteger(pid) || pid <= 0 || pid > 0x7fffffff)
      throw new Error(`The emulator lock cannot be verified (${name}).`);
    try {
      process.kill(pid, 0);
      throw new Error('The phone is in use by another emulator.');
    } catch (error) {
      if (error.code !== 'ESRCH') throw error;
    }
    // Stale locks are not removed here; only the emulator may manage them.
  }
  await inspect({ phone: current.phone, paths, run, platform });
  const env = sdkEnvironment(paths);
  const adb = path.join(paths.sdk, 'platform-tools', platform === 'win32' ? 'adb.exe' : 'adb');
  const result = await run(adb, ['devices'], { env, timeout: 15_000, maxBytes: 1024 * 1024 });
  if (result.code !== 0)
    throw new Error(
      'Cannot confirm that Android phones are stopped. Try again after stopping external emulators.',
    );
  for (const line of result.stdout.split(/\r?\n/)) {
    const match = /^(emulator-\d+)\s+(\S+)/.exec(line.trim());
    if (!match) continue;
    if (match[2] !== 'device')
      throw new Error(
        'An emulator is offline or still starting. Wait for it or stop it before continuing.',
      );
    const name = await run(adb, ['-s', match[1], 'emu', 'avd', 'name'], {
      env,
      timeout: 10_000,
      maxBytes: 64 * 1024,
    });
    const avd = name.stdout
      .split(/\r?\n/)
      .map((value) => value.trim())
      .find((value) => value && value !== 'OK');
    if (name.code !== 0 || !avd || avd === phone.id)
      throw new Error(
        'This phone or an unidentified emulator is running. Stop it before continuing.',
      );
  }
}

const EDIT_KEYS = {
  name: 'avd.ini.displayname',
  memory: 'hw.ramSize',
  cores: 'hw.cpu.ncore',
  width: 'hw.lcd.width',
  height: 'hw.lcd.height',
  density: 'hw.lcd.density',
};
function validatedChanges(changes) {
  if (!changes || typeof changes !== 'object' || Array.isArray(changes))
    throw new Error('Invalid phone changes.');
  const limits = {
    memory: [1536, 16384],
    cores: [1, 16],
    width: [320, 4096],
    height: [320, 4096],
    density: [120, 640],
  };
  for (const [key, value] of Object.entries(changes)) {
    if (!Object.hasOwn(EDIT_KEYS, key)) throw new Error(`Unsupported phone setting: ${key}`);
    if (key === 'name') {
      if (
        typeof value !== 'string' ||
        !value.trim() ||
        value.length > 120 ||
        /[\u0000-\u001f\u007f\u2028\u2029]/.test(value)
      )
        throw new Error('Phone name must be 1–120 characters on one line.');
    } else if (
      !Number.isInteger(value) ||
      value < limits[key][0] ||
      value > limits[key][1] ||
      (['width', 'height'].includes(key) && value % 2)
    )
      throw new Error(
        `Invalid ${key}: use ${limits[key].join('–')}${['width', 'height'].includes(key) ? ' and an even number' : ''}.`,
      );
  }
  return Object.fromEntries(
    Object.entries(changes).map(([key, value]) => [EDIT_KEYS[key], String(value)]),
  );
}

export async function updatePhone({ paths, id, changes, run, platform, inspect }) {
  const updates = validatedChanges(changes);
  return withPhoneOperation(paths, id, async () => {
    const current = await loadPhone(paths, id);
    await requirePhoneStopped({ paths, phone: current.phone, run, platform, inspect });
    const original = new TextDecoder('utf-8', { fatal: true }).decode(current.configuration.bytes);
    for (const key of Object.keys(updates)) {
      const values = original
        .split(/\r\n|\n|\r/)
        .map((line) => readINI(Buffer.from(line))[key])
        .filter((value) => value !== undefined);
      if (values.length && values.every((value) => value === updates[key])) delete updates[key];
    }
    if (!Object.keys(updates).length) return current.phone;
    if (!(current.configuration.mode & 0o222))
      throw new Error('The phone configuration is read-only and was preserved.');
    const newline = /\r\n|\n|\r/.exec(original)?.[0] ?? '\n',
      found = new Set();
    let next = (original.match(/[^\r\n]*(?:\r\n|\n|\r|$)/g) ?? [])
      .filter(Boolean)
      .map((line) => {
        const match = /^(\s*)([^#;\s=][^=]*?)(\s*=\s*)([^\r\n]*)(\r\n|\n|\r)?$/.exec(line);
        const key = match?.[2].trim();
        if (!Object.hasOwn(updates, key)) return line;
        found.add(key);
        return `${match[1]}${match[2]}${match[3]}${updates[key]}${match[5] ?? ''}`;
      })
      .join('');
    for (const [key, value] of Object.entries(updates))
      if (!found.has(key))
        next += (next && !/[\r\n]$/.test(next) ? newline : '') + `${key}=${value}${newline}`;
    await requireSnapshot(path.join(current.directory, PHONE_MARKER), current.marker);
    await requireSnapshot(current.indexPath, current.index);
    await replaceFile(current.phone.configPath, Buffer.from(next), current.configuration);
    return (await loadPhone(paths, id)).phone;
  });
}

export async function deletePhone({ paths, id, trash, run, platform, inspect }) {
  if (typeof trash !== 'function') throw new Error('A system Trash operation is required.');
  return withPhoneOperation(paths, id, async () => {
    const current = await loadPhone(paths, id);
    await requirePhoneStopped({ paths, phone: current.phone, run, platform, inspect });
    await requireSnapshot(current.phone.configPath, current.configuration);
    await requireSnapshot(current.indexPath, current.index);
    await requireSnapshot(path.join(current.directory, PHONE_MARKER), current.marker);
    const bundle = path.join(paths.avd, `.trash-${id}-${crypto.randomUUID()}`);
    await fs.mkdir(bundle, { mode: 0o700 });
    const movedPhone = path.join(bundle, path.basename(current.directory)),
      movedIndex = path.join(bundle, path.basename(current.indexPath));
    let directoryMoved = false,
      indexMoved = false;
    try {
      await fs.rename(current.directory, movedPhone);
      directoryMoved = true;
      await fs.rename(current.indexPath, movedIndex);
      indexMoved = true;
      await trash(bundle);
      return { id, deleted: true };
    } catch (error) {
      // Restore only into still-missing destinations. Never overwrite anything
      // another process created while the system Trash operation was pending.
      if (directoryMoved && !(await lstatOrNull(current.directory))) {
        await fs.rename(movedPhone, current.directory);
        directoryMoved = false;
      }
      if (indexMoved && !(await lstatOrNull(current.indexPath))) {
        await fs.rename(movedIndex, current.indexPath);
        indexMoved = false;
      }
      if (!directoryMoved && !indexMoved) await fs.rmdir(bundle);
      else
        throw new Error(
          `Trash failed; preserved phone files remain at ${bundle}. ${error.message}`,
        );
      throw error;
    }
  });
}
