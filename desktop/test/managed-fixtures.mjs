import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { runtimeVersion } from '../src/core/catalog.mjs';

export const host = { os: 'linux', arch: 'x64', abi: 'x86_64' };
export const license = { id: 'sdk-license', text: '\n Exact & untrimmed license text.\n ' };
const crcTable = Array.from({ length: 256 }, (_, n) => {
  for (let k = 0; k < 8; k++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

export function zip(entries) {
  const locals = [],
    central = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name),
      data = Buffer.from(entry.data ?? ''),
      crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50);
    local.writeUInt16LE(20, 4);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    const directory = Buffer.alloc(46);
    directory.writeUInt32LE(0x02014b50);
    directory.writeUInt16LE(0x0314, 4);
    directory.writeUInt16LE(20, 6);
    directory.writeUInt32LE(crc, 16);
    directory.writeUInt32LE(data.length, 20);
    directory.writeUInt32LE(data.length, 24);
    directory.writeUInt16LE(name.length, 28);
    directory.writeUInt32LE(((entry.mode ?? 0o100644) << 16) >>> 0, 38);
    directory.writeUInt32LE(offset, 42);
    locals.push(local, name, data);
    central.push(directory, name);
    offset += local.length + name.length + data.length;
  }
  const body = Buffer.concat(locals),
    records = Buffer.concat(central),
    end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(records.length, 12);
  end.writeUInt32LE(body.length, 16);
  return Buffer.concat([body, records, end]);
}

export async function fixture(t, { osName = 'linux', api = '36' } = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'droiddock-core-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const paths = {
    root,
    sdk: path.join(root, 'sdk'),
    avd: path.join(root, 'avd'),
    userHome: path.join(root, 'user-home'),
    platform: osName === 'windows' ? 'win32' : 'linux',
  };
  const archives = new Map(),
    downloads = [];
  function versionFor(
    api,
    { engine = '37.2.12', minimum = '36.5.11', imageRevision = '1.0.0' } = {},
  ) {
    const identity = runtimeVersion(`system-images;android-${api};google_apis;x86_64`),
      extension = osName === 'windows' ? '.exe' : '';
    const entries = [
      [
        'emulator',
        engine,
        [
          { name: `emulator/emulator${extension}`, data: '#!/bin/sh\nexit 0\n', mode: 0o100755 },
          { name: 'emulator/source.properties', data: `Pkg.Revision=${engine}\n` },
        ],
      ],
      [
        'platform-tools',
        '37.0.1',
        [
          { name: `platform-tools/adb${extension}`, data: '#!/bin/sh\nexit 0\n', mode: 0o100755 },
          { name: 'platform-tools/source.properties', data: 'Pkg.Revision=37.0.1\n' },
        ],
      ],
      [
        identity.id,
        imageRevision,
        ['system.img', 'ramdisk.img', 'kernel-ranchu', 'data/empty_data_disk'].map((name) => ({
          name: `x86_64/${name}`,
          data: `${api}:${name}`,
        })),
      ],
    ];
    const packages = entries.map(([id, revision, members]) => {
      const bytes = zip(members),
        url = `https://dl.google.com/android/repository/fixture-${crypto.randomUUID()}.zip`;
      archives.set(url, bytes);
      return {
        id,
        revision,
        displayName: id,
        url,
        size: bytes.length,
        checksumType: 'sha256',
        checksum: crypto.createHash('sha256').update(bytes).digest('hex'),
        license,
        licenses: [license],
        archiveRoot: id === identity.id ? 'x86_64' : id,
        relativeInstallPath: id.replaceAll(';', '/'),
        minimumDependencies: id === identity.id ? { emulator: minimum } : {},
      };
    });
    return {
      ...identity,
      revision: imageRevision,
      host: { ...host, os: osName },
      packages,
      licenses: [license],
    };
  }
  const version = versionFor(api);
  const download = async (pkg, file, { signal } = {}) => {
    signal?.throwIfAborted();
    downloads.push(pkg.id);
    await fs.writeFile(file, archives.get(pkg.url), { flag: 'wx' });
  };
  return {
    root,
    paths,
    version,
    versionFor,
    archives,
    downloads,
    download,
    availableBytes: async () => 100 * 1024 ** 3,
  };
}

export const stopped = {
  inspect: async () => {},
  run: async () => ({ stdout: 'List of devices attached\n', stderr: '', code: 0 }),
};
