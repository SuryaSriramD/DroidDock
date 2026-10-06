import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathsFor } from '../src/core/platform.mjs';
import { installTerminal } from '../src/core/terminal.mjs';
import { startCommandServer } from '../src/core/commands.mjs';

if (!['win32', 'linux'].includes(process.platform))
  throw new Error('This check must run on a native Windows or Linux packaging runner.');
const windows = process.platform === 'win32';
const execute = promisify(execFile);
const home = await fs.mkdtemp(path.join(os.tmpdir(), 'droiddock-packaged-cli-'));
const executable =
  process.env.DROIDDOCK_TEST_EXECUTABLE ||
  path.resolve(
    import.meta.dirname,
    windows ? '../dist/win-unpacked/DroidDock.exe' : '../dist/linux-unpacked/droiddock',
  );
await fs.access(executable);
const fixtureEnv = {
  ...process.env,
  HOME: home,
  LOCALAPPDATA: home,
  APPDATA: path.join(home, 'roaming'),
  USERPROFILE: home,
  XDG_DATA_HOME: path.join(home, 'data'),
  XDG_CONFIG_HOME: path.join(home, 'config'),
  XDG_CACHE_HOME: path.join(home, 'cache'),
};
const paths = pathsFor({ home, env: fixtureEnv });
const original = {
  Path: null,
  ANDROID_HOME: null,
  ANDROID_SDK_ROOT: null,
  ANDROID_SDK_HOME: null,
  ANDROID_AVD_HOME: null,
  ANDROID_USER_HOME: null,
  ANDROID_EMULATOR_HOME: null,
};
let closeServer;
try {
  // Exercise the actual launcher generator while all writes stay in this
  // fixture. Registry reads/writes are simulated, never executed.
  await installTerminal({
    paths,
    home,
    executable,
    run: async () => ({ stdout: JSON.stringify(original) }),
  });
  const wrapper = path.join(paths.terminal, 'bin', windows ? 'droiddock.cmd' : 'droiddock');
  const cmd = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'cmd.exe');
  const invoke = (command) =>
    execute(
      windows ? cmd : wrapper,
      windows ? ['/d', '/s', '/c', `""${wrapper}" ${command}"`] : command.split(' '),
      {
        windowsVerbatimArguments: windows,
        windowsHide: true,
        timeout: 30000,
        maxBuffer: 1024 * 1024,
        env: fixtureEnv,
        cwd: home,
      },
    );
  const help = await invoke('--help');
  assert.match(help.stdout, /droiddock boot PHONE_ID/, `CLI help failed for ${executable}: ${help.stderr}`);
  assert.doesNotMatch(
    help.stderr,
    /Unable to move the cache|Gpu Cache Creation failed|Unable to create cache/,
  );
  await assert.rejects(invoke('definitely-not-a-command'), (error) => {
    assert.equal(error.code, 1);
    assert.match(error.stderr, /Unknown command/);
    return true;
  });
  closeServer = await startCommandServer({
    directory: path.join(paths.root, 'commands'),
    dispatch: async (command) => {
      await new Promise((resolve) => setTimeout(resolve, 1200));
      return command.command === 'boot' ? { state: 'running', displayReady: true } : [];
    },
  });
  const concurrent = await Promise.all([invoke('list'), invoke('list'), invoke('list')]);
  for (const result of concurrent) {
    assert.deepEqual(JSON.parse(result.stdout), []);
    assert.doesNotMatch(
      result.stderr,
      /Unable to move the cache|Gpu Cache Creation failed|Unable to create cache/,
    );
  }
  const expo = path.join(home, 'node_modules', 'expo');
  await fs.mkdir(path.join(expo, 'bin'), { recursive: true });
  await fs.writeFile(
    path.join(home, 'package.json'),
    JSON.stringify({ dependencies: { expo: '57.0.0' } }),
  );
  await fs.writeFile(
    path.join(expo, 'package.json'),
    JSON.stringify({ name: 'expo', version: '57.0.0' }),
  );
  await fs.writeFile(
    path.join(expo, 'bin', 'cli'),
    `console.log('EXPO_CHILD ' + JSON.stringify({node:process.versions.node,args:process.argv.slice(2),options:process.env.NODE_OPTIONS,sdk:process.env.ANDROID_HOME}));`,
  );
  const launched = await invoke('expo Fixture_Phone --port 8082');
  const child = JSON.parse(
    launched.stdout
      .split(/\r?\n/)
      .find((line) => line.startsWith('EXPO_CHILD '))
      .slice(11),
  );
  assert.ok(Number(child.node.split('.')[0]) >= 22);
  assert.deepEqual(child.args, ['start', '--android', '--go', '--localhost', '--port', '8082']);
  assert.match(child.options, /--dns-result-order=ipv4first/);
  assert.equal(child.sdk, paths.sdk);
  console.log(
    'DROIDDOCK_PACKAGED_CLI_OK: wrapper waits, captures output, and preserves error exit status.',
  );
} finally {
  await closeServer?.();
  await fs.rm(home, { recursive: true, force: true });
}
