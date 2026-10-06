import test from 'node:test';
import assert from 'node:assert/strict';
import { hostInfo, pathsFor, sdkEnvironment, sdkExecutables } from '../src/core/platform.mjs';

test('host support is explicit and does not confuse host and Android ABI', () => {
  assert.deepEqual(hostInfo('win32', 'x64'), { os: 'windows', arch: 'x64', abi: 'x86_64' });
  assert.deepEqual(hostInfo('linux', 'x64'), { os: 'linux', arch: 'x64', abi: 'x86_64' });
  for (const [os, arch] of [
    ['darwin', 'arm64'],
    ['linux', 'arm64'],
    ['win32', 'ia32'],
  ])
    assert.throws(() => hostInfo(os, arch), /supports/);
});

test('Windows SDK uses local data, private AVDs, and executable suffixes', () => {
  const paths = pathsFor({
    platform: 'win32',
    home: 'C:\\Users\\Test User',
    env: { LOCALAPPDATA: 'D:\\Local Data' },
  });
  assert.equal(paths.root, 'D:\\Local Data\\DroidDock\\Android');
  assert.equal(paths.avd, 'D:\\Local Data\\DroidDock\\Android\\avd');
  assert.equal(paths.userHome, 'D:\\Local Data\\DroidDock\\Android\\user-home');
  assert.equal(
    sdkExecutables(paths).adb,
    'D:\\Local Data\\DroidDock\\Android\\sdk\\platform-tools\\adb.exe',
  );
  assert.equal(
    sdkExecutables(paths).emulator,
    'D:\\Local Data\\DroidDock\\Android\\sdk\\emulator\\emulator.exe',
  );
  assert.throws(
    () =>
      pathsFor({
        platform: 'win32',
        home: 'C:\\Users\\Test',
        env: { LOCALAPPDATA: '\\\\host\\share' },
      }),
    /local Windows/,
  );
});

test('Linux honors XDG data location and rejects relative overrides', () => {
  const paths = pathsFor({
    platform: 'linux',
    home: '/home/a',
    env: { XDG_DATA_HOME: '/data/users/a' },
  });
  assert.equal(paths.root, '/data/users/a/DroidDock/Android');
  assert.equal(paths.userHome, '/data/users/a/DroidDock/Android/user-home');
  assert.equal(
    pathsFor({ platform: 'linux', home: '/home/a', env: {} }).root,
    '/home/a/.local/share/DroidDock/Android',
  );
  assert.equal(sdkExecutables(paths).adb, `${paths.sdk}/platform-tools/adb`);
  assert.throws(
    () => pathsFor({ platform: 'linux', home: '/home/a', env: { XDG_DATA_HOME: 'relative' } }),
    /absolute/,
  );
});

test('SDK process environment preserves unrelated variables and normalizes Windows PATH casing', () => {
  const paths = pathsFor({ platform: 'win32', home: 'C:\\Users\\A', env: {} });
  const original = {
    Path: 'C:\\Windows;C:\\Other',
    PATH: 'c:\\windows;C:\\Second',
    HELLO: 'world',
    Android_Home: 'C:\\old',
  };
  const environment = sdkEnvironment(paths, original);
  assert.equal(environment.HELLO, 'world');
  assert.equal(environment.Path, undefined);
  assert.equal(environment.Android_Home, undefined);
  assert.equal(
    environment.PATH.split(';').filter((p) => p.toLowerCase() === 'c:\\windows').length,
    1,
  );
  assert.match(environment.PATH, /C:\\Second$/);
  assert.equal(environment.ANDROID_HOME, paths.sdk);
  assert.equal(environment.ANDROID_SDK_HOME, paths.root);
  assert.equal(environment.ANDROID_AVD_HOME, paths.avd);
  assert.deepEqual(original, {
    Path: 'C:\\Windows;C:\\Other',
    PATH: 'c:\\windows;C:\\Second',
    HELLO: 'world',
    Android_Home: 'C:\\old',
  });
});
