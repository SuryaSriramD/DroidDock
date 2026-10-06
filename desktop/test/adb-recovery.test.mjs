import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { adbServerPort, repairAdb, stopOwnedAdbServer } from '../src/core/adb-recovery.mjs';

const ok = (stdout) => ({ code: 0, stdout, stderr: '' });
test('repair refuses remote, privileged and malformed server endpoints', () => {
  assert.equal(adbServerPort({}), 5037);
  assert.equal(adbServerPort({ ADB_SERVER_SOCKET: 'tcp:127.0.0.1:5038' }), 5038);
  for (const env of [
    { ADB_SERVER_SOCKET: 'tcp:192.0.2.1:5037' },
    { ADB_SERVER_SOCKET: 'localfilesystem:/tmp/adb' },
    { ANDROID_ADB_SERVER_PORT: '80' },
    { ANDROID_ADB_SERVER_ADDRESS: 'remote' },
  ])
    assert.throws(() => adbServerPort(env));
});
test('timed-out graceful restart uses only the ownership-checked fallback, then waits for devices', async () => {
  const calls = [];
  let offline = true;
  const result = await repairAdb({
    adb: '/managed/adb',
    env: {},
    wait: async () => {},
    forceStop: async ({ adb, port }) => {
      assert.equal(adb, '/managed/adb');
      assert.equal(port, 5037);
      calls.push('owned-fallback');
    },
    run: async (_exe, args, options) => {
      assert.ok(options.timeout <= 10000);
      calls.push(args[0]);
      if (args[0] === 'kill-server') throw new Error('timeout');
      if (args[0] === 'devices' && offline) {
        offline = false;
        return ok('emulator-5554\toffline\n');
      }
      return ok('List of devices attached\nemulator-5554\tdevice\n');
    },
  });
  assert.deepEqual(calls, ['kill-server', 'owned-fallback', 'start-server', 'devices', 'devices']);
  assert.match(result.message, /repaired/);
});
test('repair preserves an unowned stalled server and never starts another on its port', async () => {
  const calls = [];
  await assert.rejects(
    repairAdb({
      adb: '/managed/adb',
      env: {},
      run: async (_exe, args) => {
        calls.push(args[0]);
        throw new Error('timeout');
      },
      forceStop: async () => {
        throw new Error('belongs to other Android tools');
      },
    }),
    /other Android tools/,
  );
  assert.deepEqual(calls, ['kill-server']);
});
test(
  'native fallback terminates only the matching executable listening on the selected port',
  { timeout: 30000 },
  async () => {
    // A disposable Node listener stands in for the unresponsive daemon. Its
    // arguments carry the same server marker; no actual Android server is touched.
    const child = spawn(
      process.execPath,
      [
        '-e',
        "require('net').createServer(()=>{}).listen(0,'127.0.0.1',function(){console.log(this.address().port)})",
        'fork-server',
        'server',
      ],
      { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true },
    );
    const exited = once(child, 'exit');
    try {
      const [data] = await once(child.stdout, 'data');
      const port = Number(data.toString().trim());
      await assert.rejects(
        stopOwnedAdbServer({
          adb: process.platform === 'win32' ? process.env.ComSpec : '/bin/sh',
          port,
          env: process.env,
        }),
        /other Android tools|Recover the owned/,
      );
      assert.equal(child.exitCode, null);
      await stopOwnedAdbServer({ adb: process.execPath, port, env: process.env });
      await exited;
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
  },
);
