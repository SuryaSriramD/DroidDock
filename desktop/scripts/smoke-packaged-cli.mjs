import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathsFor } from '../src/core/platform.mjs';
import { installTerminal } from '../src/core/terminal.mjs';

if (process.platform !== 'win32')
  throw new Error('This check must run on the native Windows packaging runner.');
const execute = promisify(execFile);
const home = await fs.mkdtemp(path.join(os.tmpdir(), 'droiddock-packaged-cli-'));
const executable = path.resolve(import.meta.dirname, '../dist/win-unpacked/DroidDock.exe');
await fs.access(executable);
const paths = pathsFor({ platform: 'win32', home, env: { LOCALAPPDATA: home } });
const original = {
  Path: null,
  ANDROID_HOME: null,
  ANDROID_SDK_ROOT: null,
  ANDROID_SDK_HOME: null,
  ANDROID_AVD_HOME: null,
  ANDROID_USER_HOME: null,
  ANDROID_EMULATOR_HOME: null,
};
try {
  // Exercise the actual launcher generator while all writes stay in this
  // fixture. Registry reads/writes are simulated, never executed.
  await installTerminal({
    paths,
    home,
    executable,
    run: async () => ({ stdout: JSON.stringify(original) }),
  });
  const wrapper = path.join(paths.terminal, 'bin', 'droiddock.cmd');
  const cmd = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'cmd.exe');
  const invoke = (command) =>
    execute(cmd, ['/d', '/s', '/c', `""${wrapper}" ${command}"`], {
      windowsVerbatimArguments: true,
      windowsHide: true,
      timeout: 15000,
      maxBuffer: 1024 * 1024,
      env: {
        ...process.env,
        LOCALAPPDATA: home,
        APPDATA: path.join(home, 'roaming'),
        USERPROFILE: home,
      },
    });
  const help = await invoke('--help');
  assert.match(help.stdout, /droiddock boot PHONE_ID/);
  await assert.rejects(invoke('definitely-not-a-command'), (error) => {
    assert.equal(error.code, 1);
    assert.match(error.stderr, /Unknown command/);
    return true;
  });
  console.log(
    'DROIDDOCK_PACKAGED_CLI_OK: wrapper waits, captures output, and preserves error exit status.',
  );
} finally {
  await fs.rm(home, { recursive: true, force: true });
}
