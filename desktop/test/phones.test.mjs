import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { installVersion, reviewInstall } from '../src/core/installer.mjs';
import {
  updatePhone,
  deletePhone,
  createPhone,
  listPhones,
  requirePhoneStopped,
  withPhoneOperation,
} from '../src/core/phones.mjs';
import { fixture, stopped, license } from './managed-fixtures.mjs';

async function ready(t) {
  const f = await fixture(t),
    plan = await reviewInstall({ paths: f.paths, version: f.version });
  f.phone = await installVersion({
    paths: f.paths,
    plan,
    acceptedLicenses: [license.id],
    download: f.download,
    availableBytes: f.availableBytes,
  });
  return f;
}

test('editing preserves unknown settings, comments, duplicate keys, permissions and userdata', async (t) => {
  const f = await ready(t),
    file = f.phone.configPath;
  await fs.appendFile(file, '# personal comment\nunknown.setting=kept\nhw.ramSize=2048\n');
  await fs.chmod(file, 0o640);
  const data = path.join(path.dirname(file), 'userdata-qemu.img');
  await fs.writeFile(data, 'precious');
  const edited = await updatePhone({
    paths: f.paths,
    id: f.phone.id,
    changes: { name: 'My Phone', memory: 4096 },
    ...stopped,
  });
  assert.equal(edited.name, 'My Phone');
  assert.equal(edited.memory, 4096);
  const content = await fs.readFile(file, 'utf8');
  assert.equal(content.match(/hw.ramSize=4096/g).length, 2);
  assert.ok(content.includes('# personal comment\nunknown.setting=kept\n'));
  if (process.platform !== 'win32') assert.equal((await fs.stat(file)).mode & 0o777, 0o640);
  assert.equal(await fs.readFile(data, 'utf8'), 'precious');
  const before = await fs.stat(file);
  await updatePhone({ paths: f.paths, id: f.phone.id, changes: { name: 'My Phone' }, ...stopped });
  assert.equal((await fs.stat(file)).ino, before.ino);
});

test('invalid edits and live hardware locks preserve config bytes', async (t) => {
  const f = await ready(t),
    before = await fs.readFile(f.phone.configPath);
  for (const changes of [
    { name: 'bad\nkey=value' },
    { width: 1081 },
    { memory: 1 },
    { image: '../outside' },
  ])
    await assert.rejects(updatePhone({ paths: f.paths, id: f.phone.id, changes, ...stopped }));
  await fs.writeFile(
    path.join(path.dirname(f.phone.configPath), 'hardware-qemu.ini.lock'),
    String(process.pid) + '\0',
  );
  await assert.rejects(
    updatePhone({ paths: f.paths, id: f.phone.id, changes: { name: 'no' }, ...stopped }),
    /in use/,
  );
  assert.deepEqual(await fs.readFile(f.phone.configPath), before);
});

test('editing synchronizes conflicting duplicates and respects read-only configuration', async (t) => {
  const f = await ready(t);
  await fs.appendFile(f.phone.configPath, 'hw.ramSize=4096\n');
  await updatePhone({ paths: f.paths, id: f.phone.id, changes: { memory: 4096 }, ...stopped });
  assert.equal((await fs.readFile(f.phone.configPath, 'utf8')).match(/hw.ramSize=4096/g).length, 2);
  await fs.chmod(f.phone.configPath, 0o400);
  await assert.rejects(
    updatePhone({ paths: f.paths, id: f.phone.id, changes: { name: 'No change' }, ...stopped }),
    /read-only/,
  );
});

test('external ADB instances, offline devices, and failed process inspection block mutation', async (t) => {
  const f = await ready(t);
  for (const status of ['offline', 'device']) {
    const run = async (_, args) => ({
      code: 0,
      stderr: '',
      stdout:
        args[0] === 'devices'
          ? `List of devices attached\nemulator-5554\t${status}\n`
          : `${f.phone.id}\nOK\n`,
    });
    await assert.rejects(
      requirePhoneStopped({ paths: f.paths, phone: f.phone, run, inspect: stopped.inspect }),
      /emulator|phone/i,
    );
  }
  await assert.rejects(
    requirePhoneStopped({
      paths: f.paths,
      phone: f.phone,
      ...stopped,
      inspect: async () => {
        throw new Error('process access denied');
      },
    }),
    /access denied/,
  );
});

test('persistent multiinstance file alone is not treated as active and is never removed', async (t) => {
  const f = await ready(t),
    lock = path.join(path.dirname(f.phone.configPath), 'multiinstance.lock');
  await fs.writeFile(lock, 'persistent');
  await updatePhone({ paths: f.paths, id: f.phone.id, changes: { name: 'Renamed' }, ...stopped });
  assert.equal(await fs.readFile(lock, 'utf8'), 'persistent');
});

test('Trash receives a single bundle containing phone data and index; image remains for recreation', async (t) => {
  const f = await ready(t),
    destination = path.join(f.root, 'Test Trash');
  await fs.mkdir(destination);
  await deletePhone({
    paths: f.paths,
    id: f.phone.id,
    ...stopped,
    trash: async (source) => {
      const entries = await fs.readdir(source);
      assert.ok(entries.includes(`${f.phone.id}.ini`));
      assert.ok(entries.includes(`${f.phone.id}.avd`));
      await fs.rename(source, path.join(destination, 'phone'));
    },
  });
  assert.deepEqual(await listPhones(f.paths), []);
  assert.equal((await reviewInstall({ paths: f.paths, version: f.version })).downloadBytes, 0);
  await createPhone({ paths: f.paths, version: f.version });
  assert.equal((await listPhones(f.paths)).length, 1);
  assert.equal(f.downloads.length, 3);
});

test('failed Trash restores original phone and index without permanently deleting data', async (t) => {
  const f = await ready(t),
    before = await fs.readFile(f.phone.configPath);
  await assert.rejects(
    deletePhone({
      paths: f.paths,
      id: f.phone.id,
      ...stopped,
      trash: async () => {
        throw new Error('Trash unavailable');
      },
    }),
    /Trash unavailable/,
  );
  assert.deepEqual(await fs.readFile(f.phone.configPath), before);
  assert.equal((await listPhones(f.paths)).length, 1);
});

test('phone IDs, linked configs, and concurrent mutations fail closed', async (t) => {
  const f = await ready(t);
  await assert.rejects(
    updatePhone({ paths: f.paths, id: '../outside', changes: {}, ...stopped }),
    /ID/,
  );
  await withPhoneOperation(f.paths, f.phone.id, async () => {
    await assert.rejects(
      updatePhone({ paths: f.paths, id: f.phone.id, changes: {}, ...stopped }),
      /Another DroidDock/,
    );
  });
  const original = f.phone.configPath + '.original';
  await fs.rename(f.phone.configPath, original);
  try {
    await fs.symlink(original, f.phone.configPath);
  } catch (error) {
    if (process.platform === 'win32' && error.code === 'EPERM') {
      t.diagnostic(
        'File symlink fixture requires Windows Developer Mode; ID and concurrent-operation checks passed.',
      );
      return;
    }
    throw error;
  }
  await assert.rejects(
    updatePhone({ paths: f.paths, id: f.phone.id, changes: { name: 'unsafe' }, ...stopped }),
    /Unsafe/,
  );
});
