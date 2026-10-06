import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { pathsFor } from '../src/core/platform.mjs';
import { parseExpoArgs, expoEnvironment, expoProject, runExpo } from '../src/core/expo.mjs';

test('Expo arguments reject extra commands and invalid ports', () => {
  assert.deepEqual(parseExpoArgs(['Phone', '--port', '8082']), { id: 'Phone', port: 8082 });
  for (const args of [
    [],
    ['../Phone'],
    ['Phone', '--port', '80'],
    ['Phone', '--port', '70000'],
    ['Phone', '--port', '8081;whoami'],
    ['Phone', '--exec', 'foo'],
  ])
    assert.throws(() => parseExpoArgs(args));
});
test('Expo environment scopes IPv4 and bundled Node to its child on both platforms', () => {
  for (const platform of ['win32', 'linux']) {
    const home = platform === 'win32' ? 'C:\\Users\\test' : '/home/test';
    const paths = pathsFor({ platform, home, env: {} });
    const env = { PATH: 'old-tools', NODE_OPTIONS: '--max-old-space-size=4096' };
    const child = expoEnvironment(paths, env);
    assert.equal(child.ANDROID_HOME, paths.sdk);
    assert.equal(child.ELECTRON_RUN_AS_NODE, '1');
    assert.equal(child.NODE_OPTIONS, '--max-old-space-size=4096 --dns-result-order=ipv4first');
    assert.equal(env.NODE_OPTIONS, '--max-old-space-size=4096');
  }
});
test('Expo uses the project local CLI with an explicit executable, preserving exit status', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'droiddock-expo-'));
  try {
    await assert.rejects(expoProject(directory), /package.json/);
    await writeFile(
      path.join(directory, 'package.json'),
      JSON.stringify({ dependencies: { expo: '57.0.0' } }),
    );
    await assert.rejects(expoProject(directory), /dependencies first/);
    const root = path.join(directory, 'node_modules', 'expo');
    await mkdir(path.join(root, 'bin'), { recursive: true });
    await writeFile(
      path.join(root, 'package.json'),
      JSON.stringify({ name: 'expo', version: '57.0.0' }),
    );
    await writeFile(path.join(root, 'bin', 'cli'), '');
    const project = await expoProject(directory);
    const paths = pathsFor();
    const code = await runExpo({
      paths,
      project,
      port: 8082,
      cwd: directory,
      executable: '/explicit/runtime',
      spawnProcess: (exe, args, options) => {
        assert.equal(exe, '/explicit/runtime');
        assert.equal(args[0], path.join(root, 'bin', 'cli'));
        assert.deepEqual(args.slice(1), [
          'start',
          '--android',
          '--go',
          '--localhost',
          '--port',
          '8082',
        ]);
        assert.equal(options.shell, false);
        assert.equal(options.cwd, directory);
        const child = new EventEmitter();
        queueMicrotask(() => child.emit('close', 7, null));
        return child;
      },
    });
    assert.equal(code, 7);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
