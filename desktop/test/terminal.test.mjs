import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathsFor } from '../src/core/platform.mjs';
import { terminalPreview, installTerminal, windowsUserEnvironment } from '../src/core/terminal.mjs';

const run = promisify(execFile);
const linuxTest = (name, body) => test(name, { skip: process.platform === 'win32' }, body);
async function fixture(t) {
  const temp = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'droiddock-terminal-')));
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  const home = path.join(temp, "Home ' quoted $(no-command)");
  await fs.mkdir(home);
  return {
    home,
    platform: 'linux',
    env: {},
    executable: path.join(home, "DroidDock's App"),
    paths: pathsFor({ platform: 'linux', home, env: {} }),
  };
}

linuxTest('preview is read-only and does not create profiles or data directories', async (t) => {
  const options = await fixture(t);
  const before = await fs.readdir(options.home);
  const preview = await terminalPreview(options);
  assert.equal(preview.files.length, 5);
  assert.match(preview.summary, /backups/);
  assert.deepEqual(await fs.readdir(options.home), before);
});

linuxTest('setup preserves profile text, creates backups, and is idempotent', async (t) => {
  const options = await fixture(t);
  const profile = path.join(options.home, '.bashrc');
  const original = 'export CUSTOM="my existing setting"\n';
  await fs.writeFile(profile, original, { mode: 0o640 });
  const first = await installTerminal(options);
  assert.equal(first.backups.length, 1);
  assert.equal(await fs.readFile(first.backups[0], 'utf8'), original);
  const updated = await fs.readFile(profile, 'utf8');
  assert.ok(updated.startsWith(original));
  assert.equal((await fs.stat(profile)).mode & 0o777, 0o640);
  assert.equal((updated.match(/>>> DroidDock/g) ?? []).length, 1);
  const second = await installTerminal(options);
  assert.deepEqual(second.backups, []);
  assert.equal(await fs.readFile(profile, 'utf8'), updated);
});

linuxTest(
  'generated wrapper and environment quote shell metacharacters and preserve arguments',
  async (t) => {
    const options = await fixture(t);
    await fs.writeFile(options.executable, '#!/bin/sh\nprintf "%s\\n" "$@"\n', { mode: 0o755 });
    await installTerminal(options);
    const wrapper = path.join(options.paths.terminal, 'bin', 'droiddock');
    const argumentsList = ['boot', 'a b', '$(touch never)', 'quote\'and"semi;'];
    assert.equal(
      (await run(wrapper, argumentsList)).stdout,
      ['--cli', ...argumentsList].join('\n') + '\n',
    );
    const sourceFile = path.join(options.paths.terminal, 'environment.sh');
    const shell = await run(
      '/bin/sh',
      [
        '-c',
        '. "$1"; . "$1"; printf "%s\\n%s\\n" "$PATH" "${ANDROID_HOME-unset}"',
        'sh',
        sourceFile,
      ],
      { env: { PATH: '/usr/bin:/bin' } },
    );
    assert.equal(
      shell.stdout,
      `${path.join(options.paths.terminal, 'bin')}:/usr/bin:/bin\nunset\n`,
    );
    for (const [directory, binary] of [
      ['platform-tools', 'adb'],
      ['emulator', 'emulator'],
    ]) {
      await fs.mkdir(path.join(options.paths.sdk, directory), { recursive: true });
      await fs.writeFile(path.join(options.paths.sdk, directory, binary), '', { mode: 0o755 });
    }
    const ready = await run(
      '/bin/sh',
      ['-c', '. "$1"; printf "%s\\n%s\\n" "$PATH" "$ANDROID_HOME"', 'sh', sourceFile],
      { env: { PATH: '/usr/bin:/bin' } },
    );
    assert.equal(
      ready.stdout,
      `${options.paths.sdk}/platform-tools:${options.paths.sdk}/emulator:${options.paths.terminal}/bin:/usr/bin:/bin\n${options.paths.sdk}\n`,
    );
  },
);

linuxTest(
  'symlinked profiles and malformed managed blocks fail before any profile write',
  async (t) => {
    const options = await fixture(t);
    const external = path.join(options.home, 'keep');
    await fs.writeFile(external, 'untouched');
    await fs.symlink(external, path.join(options.home, '.zshrc'));
    await assert.rejects(installTerminal(options), /symbolic link/);
    assert.equal(await fs.readFile(external, 'utf8'), 'untouched');
    await fs.unlink(path.join(options.home, '.zshrc'));
    await fs.writeFile(path.join(options.home, '.bashrc'), '# >>> DroidDock terminal setup >>>\n');
    await assert.rejects(installTerminal(options), /incomplete or duplicated/);
    await assert.rejects(fs.stat(options.paths.terminal), { code: 'ENOENT' });
  },
);

linuxTest('concurrent terminal setup is refused without removing its lock', async (t) => {
  const options = await fixture(t);
  const lock = path.join(options.paths.terminal, '.setup-lock');
  await fs.mkdir(lock, { recursive: true });
  await assert.rejects(installTerminal(options), /in progress/);
  assert.equal((await fs.stat(lock)).isDirectory(), true);
});

linuxTest('invalid UTF-8 and embedded marker text are preserved without edits', async (t) => {
  const options = await fixture(t);
  const profile = path.join(options.home, '.profile');
  await fs.writeFile(profile, Buffer.from([0xff, 0xfe]));
  await assert.rejects(installTerminal(options), /UTF-8/);
  assert.deepEqual(await fs.readFile(profile), Buffer.from([0xff, 0xfe]));
  const text =
    'export EXAMPLE="# >>> DroidDock terminal setup >>>\n# <<< DroidDock terminal setup <<<"\n';
  await fs.writeFile(profile, text);
  await assert.rejects(installTerminal(options), /separate lines/);
  assert.equal(await fs.readFile(profile, 'utf8'), text);
});

test('Windows user PATH is preserved and deduplicated without altering machine settings', () => {
  const paths = pathsFor({ platform: 'win32', home: 'C:\\Users\\Test', env: {} });
  const bin = path.win32.join(paths.terminal, 'bin');
  const before = {
    Path: `C:\\Custom;${bin.toUpperCase()}`,
    ANDROID_HOME: 'D:\\External SDK',
    USER_VARIABLE: 'keep',
  };
  const pending = windowsUserEnvironment(before, { paths, bin, sdkReady: false });
  assert.equal(pending.ANDROID_HOME, before.ANDROID_HOME);
  assert.equal(pending.Path, `${bin};C:\\Custom`);
  const ready = windowsUserEnvironment(before, { paths, bin, sdkReady: true });
  assert.equal(ready.ANDROID_HOME, paths.sdk);
  assert.equal(ready.USER_VARIABLE, 'keep');
  assert.equal(ready.Path.split(';').length, 4);
  assert.deepEqual(windowsUserEnvironment(ready, { paths, bin, sdkReady: true }), ready);
});

test('Windows rejects unsafe command paths before launching PowerShell', async () => {
  const paths = pathsFor({ platform: 'win32', home: 'C:\\Users\\Test', env: {} });
  let called = false;
  await assert.rejects(
    terminalPreview({
      paths,
      platform: 'win32',
      home: 'C:\\Users\\Test',
      executable: 'C:\\%EVIL%\\DroidDock.exe',
      run: async () => {
        called = true;
      },
    }),
    /safely/,
  );
  assert.equal(called, false);
});

test(
  'Windows setup backs up only its user environment and is idempotent with an injected registry',
  { skip: process.platform !== 'win32' },
  async (t) => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), 'droiddock-terminal-'));
    t.after(() => fs.rm(home, { recursive: true, force: true }));
    const paths = pathsFor({ platform: 'win32', home, env: { LOCALAPPDATA: home } });
    let user = {
      Path: 'C:\\Custom',
      ANDROID_HOME: null,
      ANDROID_SDK_ROOT: null,
      ANDROID_SDK_HOME: null,
      ANDROID_AVD_HOME: null,
      ANDROID_USER_HOME: null,
      ANDROID_EMULATOR_HOME: null,
    };
    let writes = 0;
    const options = {
      paths,
      platform: 'win32',
      home,
      executable: path.join(home, 'DroidDock.exe'),
      run: async (_exe, args) => {
        const source = Buffer.from(args.at(-1), 'base64').toString('utf16le');
        if (source.includes('GetEnvironmentVariable')) return { stdout: JSON.stringify(user) };
        assert.ok(source.includes("'User'"));
        assert.ok(!source.includes("'Machine'"));
        user = JSON.parse(
          Buffer.from(source.match(/FromBase64String\('([^']+)'\)/)[1], 'base64').toString('utf8'),
        );
        writes += 1;
        return { stdout: '' };
      },
    };
    const preview = await terminalPreview(options);
    assert.ok(preview.files.some((file) => file.startsWith('HKEY_CURRENT_USER\\Environment')));
    assert.equal(writes, 0);
    const first = await installTerminal(options);
    assert.equal(first.backups.length, 1);
    assert.equal(JSON.parse(await fs.readFile(first.backups[0], 'utf8')).Path, 'C:\\Custom');
    assert.equal(writes, 1);
    const wrapper = await fs.readFile(path.join(paths.terminal, 'bin', 'droiddock.cmd'), 'utf8');
    assert.ok(wrapper.includes('" --cli %*'));
    await installTerminal(options);
    assert.equal(writes, 1);
  },
);
