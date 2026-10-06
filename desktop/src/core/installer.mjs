import fs from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import yauzl from 'yauzl';
import { runtimeVersion, compareRevisions, officialURL, officialResponse } from './catalog.mjs';
import {
  SDK_MARKER,
  assertPrivatePaths,
  safeDirectory,
  snapshot,
  lstatOrNull,
  writeExclusive,
  withOperationLock,
  createPhone,
  listPhones,
  readINI,
} from './phones.mjs';

const RECEIPT = '.droiddock-package.json';
const GIB = 1024 ** 3;
const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');
const abort = (signal) => signal?.throwIfAborted();
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object')
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
      .join(',')}}`;
  return JSON.stringify(value);
}

function validateVersion(version) {
  const identity = runtimeVersion(version?.id);
  if (
    version.api !== identity.api ||
    version.abi !== identity.abi ||
    version.imagePath !== identity.imagePath ||
    version.deviceName !== identity.deviceName ||
    !['windows', 'linux'].includes(version.host?.os) ||
    version.host?.arch !== 'x64' ||
    version.host?.abi !== 'x86_64'
  )
    throw new Error('Invalid or unsupported Android version.');
  const ids = ['emulator', 'platform-tools', identity.id];
  if (
    !Array.isArray(version.packages) ||
    version.packages.length !== 3 ||
    new Set(version.packages.map((pkg) => pkg.id)).size !== 3 ||
    version.packages.some((pkg) => !ids.includes(pkg.id))
  )
    throw new Error('The required Android packages are missing.');
  const licenses = new Map();
  for (const pkg of version.packages) {
    const root = pkg.id === identity.id ? identity.abi : pkg.id;
    if (
      pkg.relativeInstallPath !== pkg.id.replaceAll(';', '/') ||
      pkg.archiveRoot !== root ||
      !Number.isSafeInteger(pkg.size) ||
      pkg.size <= 0 ||
      pkg.size > 20 * GIB
    )
      throw new Error('Invalid Android package layout or size.');
    if (
      officialURL(pkg.url) !== pkg.url ||
      !pkg.url.endsWith('.zip') ||
      !['sha1', 'sha256'].includes(pkg.checksumType) ||
      !new RegExp(`^[0-9a-f]{${pkg.checksumType === 'sha1' ? 40 : 64}}$`).test(pkg.checksum)
    )
      throw new Error('Invalid Android package URL or checksum.');
    compareRevisions(pkg.revision, '0');
    for (const [component, minimum] of Object.entries(pkg.minimumDependencies ?? {})) {
      if (!['emulator', 'platform-tools'].includes(component))
        throw new Error('This image needs an unsupported additional component.');
      compareRevisions(minimum, '0');
    }
    const required = pkg.licenses ?? (pkg.license ? [pkg.license] : []);
    if (!required.length) throw new Error('Missing Android license text.');
    for (const license of required) {
      if (
        typeof license.id !== 'string' ||
        !license.id ||
        typeof license.text !== 'string' ||
        !license.text.trim() ||
        Buffer.byteLength(license.text) > 1024 * 1024
      )
        throw new Error('Invalid Android license.');
      if (licenses.has(license.id) && licenses.get(license.id).text !== license.text)
        throw new Error('Conflicting Android license text.');
      licenses.set(license.id, license);
    }
  }
  return { identity, licenses };
}

async function regular(file, { executable = false } = {}) {
  await safeDirectory(path.dirname(file));
  const info = await lstatOrNull(file);
  if (
    !info?.isFile() ||
    info.isSymbolicLink() ||
    !info.size ||
    (executable && process.platform !== 'win32' && !(info.mode & 0o111))
  )
    throw new Error(`Android installation is incomplete or unsafe: ${file}`);
  return { size: info.size, ino: info.ino, dev: info.dev, mtime: info.mtimeMs, mode: info.mode };
}

async function validateImage(sdk, version) {
  const image = path.join(sdk, runtimeVersion(version.id).imagePath);
  await safeDirectory(image);
  const files = [];
  for (const name of ['system.img', 'ramdisk.img', 'kernel-ranchu'])
    files.push(await regular(path.join(image, name)));
  const legacy = path.join(image, 'userdata.img'),
    modern = path.join(image, 'data', 'empty_data_disk');
  files.push(await regular((await lstatOrNull(legacy)) ? legacy : modern));
  return files;
}

async function ownedSDK(paths, version) {
  await safeDirectory(paths.sdk);
  const marker = await snapshot(path.join(paths.sdk, SDK_MARKER));
  let ownership;
  try {
    ownership = JSON.parse(marker.bytes);
  } catch {
    throw new Error(
      'Existing SDK is not owned by this DroidDock desktop preview; its files were preserved.',
    );
  }
  if (
    ownership.format !== 1 ||
    ownership.host?.os !== version.host.os ||
    ownership.host?.arch !== 'x64'
  )
    throw new Error(
      'The existing SDK belongs to a different host or installation. It was preserved.',
    );
  const extension = version.host.os === 'windows' ? '.exe' : '';
  const binaries = [];
  for (const component of ['emulator', 'platform-tools']) {
    const name = component === 'emulator' ? 'emulator' : 'adb';
    binaries.push(
      await regular(path.join(paths.sdk, component, name + extension), {
        executable: version.host.os !== 'windows',
      }),
    );
  }
  return { marker: hash(marker.bytes), binaries };
}

async function installedRevision(paths, id) {
  const source = await snapshot(path.join(paths.sdk, id, 'source.properties'), { optional: true });
  const value = source ? readINI(source.bytes)['Pkg.Revision'] : null;
  if (value) {
    compareRevisions(value, '0');
    return value;
  }
  const receipt = await snapshot(path.join(paths.sdk, id, RECEIPT), { optional: true });
  if (!receipt) return null;
  const data = JSON.parse(receipt.bytes);
  if (data.id !== id) throw new Error(`Invalid install receipt for ${id}.`);
  compareRevisions(data.revision, '0');
  return data.revision;
}

async function inspection(paths, version) {
  assertPrivatePaths(paths);
  validateVersion(version);
  await safeDirectory(paths.root);
  let packages,
    state = { sdk: null, image: null, phone: null };
  if (!(await lstatOrNull(paths.sdk))) {
    packages = version.packages;
    for (const pkg of packages)
      for (const [component, minimum] of Object.entries(pkg.minimumDependencies ?? {})) {
        if (
          compareRevisions(
            packages.find((candidate) => candidate.id === component).revision,
            minimum,
          ) < 0
        )
          throw new Error(`The selected ${component} package is too old for this image.`);
      }
  } else {
    state.sdk = await ownedSDK(paths, version);
    const image = path.join(paths.sdk, runtimeVersion(version.id).imagePath);
    if (await lstatOrNull(image)) {
      const receipt = await snapshot(path.join(image, RECEIPT));
      const installed = JSON.parse(receipt.bytes);
      if (installed.id !== version.id)
        throw new Error(
          'Existing Android image ownership cannot be verified. Its files were preserved.',
        );
      state.image = {
        files: await validateImage(paths.sdk, version),
        receipt: hash(receipt.bytes),
      };
      packages = [];
    } else {
      const pkg = version.packages.find((candidate) => candidate.id === version.id);
      for (const [component, minimum] of Object.entries(pkg.minimumDependencies ?? {})) {
        const installed = await installedRevision(paths, component);
        if (
          compareRevisions(minimum, '0') > 0 &&
          (!installed || compareRevisions(installed, minimum) < 0)
        )
          throw new Error(
            `This Android version needs ${component} ${minimum} or newer; installed: ${installed ?? 'unknown'}. This preview cannot update the shared Android engine. Existing phones are preserved.`,
          );
      }
      state.sdk.revisions = await Promise.all(
        ['emulator', 'platform-tools'].map((id) => installedRevision(paths, id)),
      );
      packages = [pkg];
    }
  }
  const phone = (await listPhones(paths)).find((candidate) => candidate.imageId === version.id);
  const identity = runtimeVersion(version.id);
  if (
    !phone &&
    ((await lstatOrNull(path.join(paths.avd, `${identity.deviceName}.avd`))) ||
      (await lstatOrNull(path.join(paths.avd, `${identity.deviceName}.ini`))))
  )
    throw new Error(
      'An existing phone or index at the destination could not be verified; it was preserved.',
    );
  state.phone = phone ? hash((await snapshot(phone.configPath)).bytes) : null;
  return { packages, state, phone };
}

export async function reviewInstall({ paths, version }) {
  const { packages, state, phone } = await inspection(paths, version);
  const licenses = new Map();
  for (const pkg of packages)
    for (const license of pkg.licenses ?? [pkg.license]) licenses.set(license.id, license);
  const downloadBytes = packages.reduce((sum, pkg) => sum + pkg.size, 0);
  const requiredBytes = downloadBytes
    ? Math.max(12 * GIB, 4 * downloadBytes + 4 * GIB)
    : phone
      ? 0
      : 4 * GIB;
  return {
    token: hash(canonical({ root: paths.root, version, state })),
    version: structuredClone(version),
    packages: structuredClone(packages),
    downloadBytes,
    requiredBytes,
    licenses: structuredClone([...licenses.values()]),
    installed: Boolean(state.image),
    phoneExists: Boolean(phone),
  };
}

export async function downloadPackage(
  pkg,
  destination,
  { signal, onProgress = () => {}, fetchImpl = fetch } = {},
) {
  const deadline = AbortSignal.timeout(2 * 60 * 60 * 1000),
    combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
  const response = await officialResponse(pkg.url, { signal: combined, fetchImpl });
  const expectedLength = response.headers.get('content-length');
  const encoding = response.headers.get('content-encoding')?.trim().toLowerCase();
  // Fetch decodes HTTP compression, but Content-Length still counts encoded bytes.
  // Only compare that header for identity responses; always bound and verify the
  // decoded archive against the catalog size and checksum below.
  if (
    (!encoding || encoding === 'identity') &&
    expectedLength !== null &&
    Number(expectedLength) !== pkg.size
  ) {
    await response.body.cancel();
    throw new Error(`Unexpected download size for ${pkg.displayName}.`);
  }
  let total = 0;
  const bounded = new Transform({
    transform(chunk, _, callback) {
      total += chunk.length;
      if (total > pkg.size)
        return callback(new Error('Android download exceeded its declared size.'));
      onProgress({ message: `Downloading ${pkg.displayName}`, completed: total, total: pkg.size });
      callback(null, chunk);
    },
  });
  await pipeline(
    response.body,
    bounded,
    createWriteStream(destination, { flags: 'wx', mode: 0o600 }),
    { signal: combined },
  );
  if (total !== pkg.size) throw new Error('Android download was truncated.');
}

export async function verifyArchive(archive, pkg, signal) {
  const info = await regular(archive);
  if (info.size !== pkg.size)
    throw new Error(`Checksum verification failed for ${pkg.displayName}.`);
  const digest = crypto.createHash(pkg.checksumType);
  for await (const chunk of createReadStream(archive, { highWaterMark: 1024 * 1024 })) {
    abort(signal);
    digest.update(chunk);
  }
  if (digest.digest('hex') !== pkg.checksum)
    throw new Error(`Checksum verification failed for ${pkg.displayName}.`);
}

function openZIP(file) {
  return new Promise((resolve, reject) =>
    yauzl.open(
      file,
      {
        lazyEntries: true,
        autoClose: false,
        decodeStrings: true,
        validateEntrySizes: true,
        strictFileNames: true,
      },
      (error, zip) => (error ? reject(error) : resolve(zip)),
    ),
  );
}

export function validateArchivePath(name, archiveRoot) {
  if (
    typeof name !== 'string' ||
    /[\\:<>"|?*\u0000-\u001f\u007f]/.test(name) ||
    name.startsWith('/') ||
    name.length > 2048
  )
    throw new Error(`Unsafe archive pathname: ${name}`);
  const parts = name.replace(/\/$/, '').split('/');
  if (
    parts[0] !== archiveRoot ||
    parts.some(
      (part) =>
        !part ||
        part === '.' ||
        part === '..' ||
        /[. ]$/.test(part) ||
        /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part),
    )
  )
    throw new Error(`Unsafe archive pathname: ${name}`);
  return parts.join('/');
}

async function ZIPEntries(zip, root) {
  return new Promise((resolve, reject) => {
    const entries = [],
      paths = new Map();
    let total = 0;
    const failed = (error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      zip.off('error', failed);
      zip.off('entry', entry);
      zip.off('end', done);
    };
    const done = () => {
      cleanup();
      resolve(entries);
    };
    const entry = (item) => {
      try {
        const normalized = validateArchivePath(item.fileName, root),
          key = normalized.toLowerCase();
        const kind = (item.externalFileAttributes >>> 16) & 0o170000;
        if (
          ++total > 100_000 ||
          paths.has(key) ||
          ![0, 0o040000, 0o100000].includes(kind) ||
          item.isEncrypted() ||
          ![0, 8].includes(item.compressionMethod)
        )
          throw new Error('Unsupported, linked, encrypted, or duplicate archive entry.');
        const directory = item.fileName.endsWith('/');
        if ((kind === 0o040000 && !directory) || (kind === 0o100000 && directory))
          throw new Error('Archive entry type mismatch.');
        if (
          !Number.isSafeInteger(item.uncompressedSize) ||
          item.uncompressedSize < 0 ||
          item.uncompressedSize > 64 * GIB
        )
          throw new Error('Archive entry exceeds extraction limits.');
        for (const [other, isDirectory] of paths) {
          if (
            (!isDirectory && key.startsWith(other + '/')) ||
            (!directory && other.startsWith(key + '/'))
          )
            throw new Error('Archive file/directory collision.');
        }
        paths.set(key, directory);
        entries.push(item);
        zip.readEntry();
      } catch (error) {
        failed(error);
      }
    };
    zip.on('error', failed);
    zip.on('entry', entry);
    zip.on('end', done);
    zip.readEntry();
  });
}

function entryStream(zip, entry) {
  return new Promise((resolve, reject) =>
    zip.openReadStream(entry, (error, stream) => (error ? reject(error) : resolve(stream))),
  );
}

// Extraction never creates links. Official x64 packages contain regular files
// and directories; refusing links is simpler than permitting cross-platform
// junction/reparse-point behavior in this preview.
export async function extractArchive(archive, destination, archiveRoot, { signal } = {}) {
  const zip = await openZIP(archive);
  try {
    const entries = await ZIPEntries(zip, archiveRoot);
    if (!entries.length || entries.reduce((sum, item) => sum + item.uncompressedSize, 0) > 64 * GIB)
      throw new Error('Empty or oversized Android archive.');
    // Inspect local names too: ZIP central and local records must agree.
    const handle = await fs.open(archive, 'r');
    try {
      for (const entry of entries) {
        abort(signal);
        const header = Buffer.alloc(30);
        const { bytesRead } = await handle.read(header, 0, 30, entry.relativeOffsetOfLocalHeader);
        if (
          bytesRead !== 30 ||
          header.readUInt32LE(0) !== 0x04034b50 ||
          header.readUInt16LE(6) !== entry.generalPurposeBitFlag ||
          header.readUInt16LE(8) !== entry.compressionMethod
        )
          throw new Error('Invalid ZIP local header.');
        const bytes = Buffer.alloc(header.readUInt16LE(26));
        const result = await handle.read(
          bytes,
          0,
          bytes.length,
          entry.relativeOffsetOfLocalHeader + 30,
        );
        if (result.bytesRead !== bytes.length || !bytes.equals(Buffer.from(entry.fileName, 'utf8')))
          throw new Error('ZIP local and central filenames disagree.');
      }
    } finally {
      await handle.close();
    }
    await safeDirectory(destination, { create: true });
    for (const entry of entries) {
      abort(signal);
      const relative = validateArchivePath(entry.fileName, archiveRoot),
        output = path.join(destination, ...relative.split('/'));
      if (entry.fileName.endsWith('/')) {
        await safeDirectory(output, { create: true });
        continue;
      }
      await safeDirectory(path.dirname(output), { create: true });
      const stream = await entryStream(zip, entry);
      const mode = (entry.externalFileAttributes >>> 16) & 0o111 ? 0o700 : 0o600;
      await pipeline(stream, createWriteStream(output, { flags: 'wx', mode }), { signal });
    }
  } finally {
    zip.close();
  }
}

async function publishDirectory(source, destination, marker) {
  await safeDirectory(path.dirname(destination), { create: true });
  // An exclusive reservation avoids rename's overwrite behavior on POSIX.
  // Readers recognize readiness only after the final receipt/marker is moved.
  await fs.mkdir(destination, { mode: 0o700 });
  const token = crypto.randomUUID(),
    reservation = path.join(destination, '.droiddock-publishing');
  const created = [];
  async function record(file) {
    const info = await fs.lstat(file);
    created.push({
      file,
      ino: info.ino,
      dev: info.dev,
      size: info.size,
      mtime: info.mtimeMs,
      directory: info.isDirectory(),
    });
  }
  async function moveExclusive(from, to) {
    const info = await fs.lstat(from);
    if (info.isDirectory() && !info.isSymbolicLink()) {
      await fs.mkdir(to, { mode: 0o700 });
      await record(to);
      for (const name of await fs.readdir(from))
        await moveExclusive(path.join(from, name), path.join(to, name));
      await fs.rmdir(from);
    } else if (info.isFile() && !info.isSymbolicLink()) {
      // Same-volume hard links provide atomic no-replace publication on NTFS
      // and POSIX. An unexpected existing destination is never overwritten.
      await fs.link(from, to);
      await record(to);
      await fs.unlink(from);
    } else throw new Error('Unexpected linked or special file in staged Android package.');
  }
  try {
    await writeExclusive(reservation, token);
    const entries = await fs.readdir(source);
    if (!entries.includes(marker))
      throw new Error('Missing readiness marker for Android publication.');
    for (const name of entries.filter((name) => name !== marker))
      await moveExclusive(path.join(source, name), path.join(destination, name));
    await moveExclusive(path.join(source, marker), path.join(destination, marker));
    await fs.unlink(reservation);
  } catch (error) {
    if (
      (await snapshot(reservation, { optional: true }).catch(() => null))?.bytes.toString() ===
      token
    ) {
      for (const item of created.reverse()) {
        const info = await lstatOrNull(item.file);
        if (!info || info.ino !== item.ino || info.dev !== item.dev) continue;
        if (item.directory && info.isDirectory()) await fs.rmdir(item.file).catch(() => {});
        else if (info.isFile() && info.size === item.size && info.mtimeMs === item.mtime)
          await fs.unlink(item.file).catch(() => {});
      }
      await fs.unlink(reservation);
      await fs.rmdir(destination).catch(() => {});
    }
    throw error;
  }
}

export async function installVersion({
  paths,
  plan,
  acceptedLicenses,
  signal,
  onProgress = () => {},
  download = downloadPackage,
  extract = extractArchive,
  availableBytes = async (root) => {
    const info = await fs.statfs(root);
    return info.bavail * info.bsize;
  },
}) {
  assertPrivatePaths(paths);
  abort(signal);
  if (!plan || typeof plan.token !== 'string')
    throw new Error('Review this Android installation before continuing.');
  validateVersion(plan.version);
  await safeDirectory(paths.root, { create: true });
  return withOperationLock(paths, 'install', async () => {
    const current = await reviewInstall({ paths, version: plan.version });
    if (
      current.token !== plan.token ||
      canonical(current.packages) !== canonical(plan.packages) ||
      canonical(current.licenses) !== canonical(plan.licenses)
    )
      throw new Error(
        'Installed components or download information changed. Review this version again.',
      );
    if (
      !Array.isArray(acceptedLicenses) ||
      current.licenses.some((license) => !acceptedLicenses.includes(license.id))
    )
      throw new Error('Accept all displayed Android licenses before downloading.');
    if (current.requiredBytes && (await availableBytes(paths.root)) < current.requiredBytes)
      throw new Error(
        `Android setup needs at least ${(current.requiredBytes / GIB).toFixed(1)} GiB of free disk space. Existing phones were preserved.`,
      );
    if (!current.packages.length) {
      abort(signal);
      return createPhone({ paths, version: current.version });
    }
    const stage = path.join(paths.root, `.setup-${crypto.randomUUID()}`);
    await fs.mkdir(stage, { mode: 0o700 });
    try {
      const stagedSDK = path.join(stage, 'sdk');
      await fs.mkdir(stagedSDK);
      for (const [index, pkg] of current.packages.entries()) {
        abort(signal);
        const archive = path.join(stage, `package-${index}.zip`),
          unpacked = path.join(stage, `unpacked-${index}`);
        onProgress({ message: `Downloading ${pkg.displayName}`, completed: 0, total: pkg.size });
        await download(pkg, archive, { signal, onProgress });
        abort(signal);
        onProgress({ message: `Checking ${pkg.displayName}` });
        await verifyArchive(archive, pkg, signal);
        onProgress({ message: `Installing ${pkg.displayName}` });
        await extract(archive, unpacked, pkg.archiveRoot, { signal });
        abort(signal);
        const source = path.join(unpacked, pkg.archiveRoot),
          destination = path.join(stagedSDK, pkg.relativeInstallPath);
        await safeDirectory(source);
        await safeDirectory(path.dirname(destination), { create: true });
        await fs.rename(source, destination);
        await writeExclusive(
          path.join(destination, RECEIPT),
          JSON.stringify(
            {
              id: pkg.id,
              revision: pkg.revision,
              checksum: pkg.checksum,
              checksumType: pkg.checksumType,
              url: pkg.url,
              acceptedAt: new Date().toISOString(),
              licenses: current.licenses.map((license) => ({
                ...license,
                sha256: hash(license.text),
              })),
            },
            null,
            2,
          ),
        );
        await fs.unlink(archive);
        await fs.rm(unpacked, { recursive: true });
      }
      await validateImage(stagedSDK, current.version);
      const incremental = current.packages.length === 1;
      if (!incremental) {
        await writeExclusive(
          path.join(stagedSDK, SDK_MARKER),
          JSON.stringify({
            format: 1,
            host: current.version.host,
            createdAt: new Date().toISOString(),
          }),
        );
        await ownedSDK({ ...paths, sdk: stagedSDK }, current.version);
      }
      abort(signal);
      // Reinspect immediately before publication. The exclusive lock serializes
      // DroidDock installs, while this check detects external SDK mutations.
      if ((await reviewInstall({ paths, version: current.version })).token !== plan.token)
        throw new Error(
          'The Android installation changed during download. Existing files were preserved.',
        );
      if (incremental)
        await publishDirectory(
          path.join(stagedSDK, current.version.imagePath),
          path.join(paths.sdk, current.version.imagePath),
          RECEIPT,
        );
      else await publishDirectory(stagedSDK, paths.sdk, SDK_MARKER);
      onProgress({ message: 'Creating your Android phone' });
      abort(signal);
      const phone = await createPhone({ paths, version: current.version });
      onProgress({ message: `${current.version.title} is ready` });
      return phone;
    } finally {
      await fs.rm(stage, { recursive: true, force: true });
    }
  });
}
