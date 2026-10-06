import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { createServer } from 'node:http';
import { gzipSync } from 'node:zlib';
import {
  reviewInstall,
  installVersion,
  extractArchive,
  downloadPackage,
  verifyArchive,
  validateArchivePath,
} from '../src/core/installer.mjs';
import { listPhones, withOperationLock } from '../src/core/phones.mjs';
import { fixture, zip, license } from './managed-fixtures.mjs';

async function install(f, version = f.version, options = {}) {
  const plan = await reviewInstall({ paths: f.paths, version });
  return installVersion({
    paths: f.paths,
    plan,
    acceptedLicenses: [license.id],
    download: f.download,
    availableBytes: f.availableBytes,
    ...options,
  });
}

test('fresh Linux and Windows installations verify real ZIPs, receipts, private AVD and consent', async (t) => {
  for (const osName of ['linux', 'windows']) {
    const f = await fixture(t, { osName });
    const plan = await reviewInstall({ paths: f.paths, version: f.version });
    await assert.rejects(
      installVersion({
        paths: f.paths,
        plan,
        acceptedLicenses: [],
        download: f.download,
        availableBytes: f.availableBytes,
      }),
      /Accept all/,
    );
    assert.equal(f.downloads.length, 0);
    const phone = await install(f);
    assert.equal(phone.api, '36');
    assert.equal(phone.abi, 'x86_64');
    assert.equal(phone.width, 1080);
    assert.equal(f.downloads.length, 3);
    const receipt = JSON.parse(
      await fs.readFile(path.join(f.paths.sdk, 'emulator/.droiddock-package.json')),
    );
    assert.equal(receipt.licenses[0].text, license.text);
    assert.equal(
      receipt.licenses[0].sha256,
      crypto.createHash('sha256').update(license.text).digest('hex'),
    );
    assert.deepEqual(await listPhones(f.paths), [phone]);
    const second = await reviewInstall({ paths: f.paths, version: f.version });
    assert.equal(second.downloadBytes, 0);
    assert.equal(second.requiredBytes, 0);
    assert.equal(second.phoneExists, true);
  }
});

test('new API downloads only missing image and preserves shared tools and old phone data', async (t) => {
  const f = await fixture(t),
    original = await install(f);
  const userdata = path.join(path.dirname(original.configPath), 'userdata-qemu.img');
  await fs.writeFile(userdata, 'precious phone data');
  const engine = await fs.readFile(path.join(f.paths.sdk, 'emulator/emulator'));
  const version = f.versionFor('37.0'),
    review = await reviewInstall({ paths: f.paths, version });
  assert.deepEqual(
    review.packages.map((pkg) => pkg.id),
    [version.id],
  );
  const phone = await install(f, version);
  assert.notEqual(phone.id, original.id);
  assert.equal(f.downloads.length, 4);
  assert.equal(await fs.readFile(userdata, 'utf8'), 'precious phone data');
  assert.deepEqual(await fs.readFile(path.join(f.paths.sdk, 'emulator/emulator')), engine);
  assert.equal((await listPhones(f.paths)).length, 2);
  const patch = f.versionFor('37.0', { imageRevision: '99.0.0' });
  assert.equal((await reviewInstall({ paths: f.paths, version: patch })).downloadBytes, 0);
});

test('new version refuses an incompatible shared engine without overwriting anything', async (t) => {
  const f = await fixture(t);
  await install(f);
  const version = f.versionFor('37.0', { minimum: '99.0.0' });
  await assert.rejects(
    reviewInstall({ paths: f.paths, version }),
    /cannot update the shared Android engine/,
  );
  assert.equal(f.downloads.length, 3);
  assert.equal((await listPhones(f.paths)).length, 1);
});

test('review fingerprint rejects concurrent metadata change and low space before downloading', async (t) => {
  const f = await fixture(t);
  await install(f);
  const version = f.versionFor('37.0'),
    plan = await reviewInstall({ paths: f.paths, version });
  await fs.appendFile(
    path.join(f.paths.sdk, 'emulator/source.properties'),
    'Pkg.Revision=38.0.0\n',
  );
  await assert.rejects(
    installVersion({
      paths: f.paths,
      plan,
      acceptedLicenses: [license.id],
      download: f.download,
      availableBytes: f.availableBytes,
    }),
    /changed/,
  );
  const fresh = await fixture(t);
  await assert.rejects(
    install(fresh, fresh.version, { availableBytes: async () => 1 }),
    /free disk/,
  );
  assert.equal(fresh.downloads.length, 0);
});

test('checksum failure, cancellation, and retry clean staging and preserve existing images', async (t) => {
  const f = await fixture(t);
  await assert.rejects(
    install(f, f.version, {
      download: async (pkg, file) => fs.writeFile(file, Buffer.alloc(pkg.size, 0)),
    }),
    /Checksum/,
  );
  assert.equal(
    (await fs.readdir(f.root)).some((name) => name.startsWith('.setup-')),
    false,
  );
  assert.equal((await fs.readdir(f.root)).includes('sdk'), false);
  await install(f);
  const next = f.versionFor('37.0'),
    controller = new AbortController();
  await assert.rejects(
    install(f, next, {
      signal: controller.signal,
      download: async (...args) => {
        await f.download(...args);
        controller.abort();
      },
    }),
    { name: 'AbortError' },
  );
  assert.equal((await listPhones(f.paths)).length, 1);
  assert.equal(
    (await fs.readdir(f.root)).some((name) => name.startsWith('.setup-')),
    false,
  );
  await install(f, next);
  assert.equal((await listPhones(f.paths)).length, 2);
});

test('late cancellation keeps completed image reusable without creating incomplete phone', async (t) => {
  const f = await fixture(t),
    controller = new AbortController();
  await assert.rejects(
    install(f, f.version, {
      signal: controller.signal,
      onProgress: (event) => {
        if (event.message === 'Creating your Android phone') controller.abort();
      },
    }),
    { name: 'AbortError' },
  );
  const review = await reviewInstall({ paths: f.paths, version: f.version });
  assert.equal(review.downloadBytes, 0);
  assert.equal(review.phoneExists, false);
  await install(f);
  assert.equal(f.downloads.length, 3);
  assert.equal((await listPhones(f.paths)).length, 1);
});

test('existing unowned SDK and symlinked parents are preserved', async (t) => {
  const f = await fixture(t);
  await fs.mkdir(f.paths.sdk);
  await fs.writeFile(path.join(f.paths.sdk, 'mine.txt'), 'keep');
  await assert.rejects(reviewInstall({ paths: f.paths, version: f.version }), /Missing file/);
  assert.equal(await fs.readFile(path.join(f.paths.sdk, 'mine.txt'), 'utf8'), 'keep');
  const other = await fixture(t);
  await fs.symlink(f.paths.sdk, other.paths.sdk, process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(reviewInstall({ paths: other.paths, version: other.version }), /linked/);
});

test('exclusive install lock rejects a second writer', async (t) => {
  const f = await fixture(t);
  await withOperationLock(f.paths, 'install', async () => {
    await assert.rejects(install(f), /Another DroidDock operation/);
  });
  await install(f);
});

test('extractor rejects traversal, Windows aliases, duplicate case, links and local/central disagreement', async (t) => {
  const f = await fixture(t);
  for (const name of [
    'emulator/../outside',
    'emulator/C:ads',
    'emulator/CON',
    'emulator/a.',
    'emulator//a',
    '/emulator/a',
    'emulator\\a',
  ])
    assert.throws(() => validateArchivePath(name, 'emulator'));
  const cases = [
    [{ name: 'emulator/alias', data: '../../outside', mode: 0o120777 }],
    [
      { name: 'emulator/A', data: 'one' },
      { name: 'emulator/a', data: 'two' },
    ],
    [
      { name: 'emulator/a', data: 'file' },
      { name: 'emulator/a/child', data: 'child' },
    ],
  ];
  for (const [i, entries] of cases.entries()) {
    const archive = path.join(f.root, `unsafe-${i}.zip`);
    await fs.writeFile(archive, zip(entries));
    await assert.rejects(extractArchive(archive, path.join(f.root, `out-${i}`), 'emulator'));
  }
  const archive = path.join(f.root, 'mismatch.zip'),
    bytes = zip([{ name: 'emulator/a', data: 'x' }]);
  bytes[30] = 47;
  await fs.writeFile(archive, bytes);
  await assert.rejects(
    extractArchive(archive, path.join(f.root, 'mismatch'), 'emulator'),
    /filenames disagree/,
  );
});

test('bounded downloads reject overflow, truncation and off-host redirects', async (t) => {
  const f = await fixture(t),
    pkg = { ...f.version.packages[0], size: 4 };
  await assert.rejects(
    downloadPackage(pkg, path.join(f.root, 'overflow'), {
      fetchImpl: async () => new Response('12345'),
    }),
    /exceeded/,
  );
  await assert.rejects(
    downloadPackage(pkg, path.join(f.root, 'short'), {
      fetchImpl: async () => new Response('123'),
    }),
    /truncated/,
  );
  await assert.rejects(
    downloadPackage(pkg, path.join(f.root, 'wrong-header'), {
      fetchImpl: async () => new Response('1234', { headers: { 'content-length': '3' } }),
    }),
    /Unexpected download size/,
  );
  await assert.rejects(
    downloadPackage(pkg, path.join(f.root, 'redirect'), {
      fetchImpl: async () =>
        new Response(null, { status: 302, headers: { location: 'https://evil.test/file' } }),
    }),
    /untrusted/,
  );
});

test('HTTP-compressed archives validate decoded size and checksum', async (t) => {
  const f = await fixture(t),
    pkg = f.version.packages[0],
    archive = f.archives.get(pkg.url);
  let body = archive;
  const server = createServer((_request, response) => {
    const encoded = gzipSync(body);
    response.writeHead(200, {
      'Content-Type': 'application/zip',
      'Content-Encoding': 'gzip',
      'Content-Length': encoded.length,
    });
    response.end(encoded);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  t.after(
    () =>
      new Promise((resolve) => {
        server.close(resolve);
        server.closeAllConnections();
      }),
  );
  const fetchImpl = (_url, options) =>
    fetch(`http://127.0.0.1:${server.address().port}/archive`, options);
  const destination = path.join(f.root, 'compressed.zip');
  await downloadPackage(pkg, destination, { fetchImpl });
  assert.deepEqual(await fs.readFile(destination), archive);
  await verifyArchive(destination, pkg);
  body = Buffer.concat([archive, Buffer.from('extra')]);
  await assert.rejects(
    downloadPackage(pkg, path.join(f.root, 'compressed-overflow'), { fetchImpl }),
    /exceeded/,
  );
  body = archive.subarray(0, archive.length - 1);
  await assert.rejects(
    downloadPackage(pkg, path.join(f.root, 'compressed-short'), { fetchImpl }),
    /truncated/,
  );
  body = Buffer.from(archive);
  body[body.length - 1] ^= 1;
  const corrupt = path.join(f.root, 'compressed-corrupt');
  await downloadPackage(pkg, corrupt, { fetchImpl });
  await assert.rejects(verifyArchive(corrupt, pkg), /Checksum verification failed/);
});
