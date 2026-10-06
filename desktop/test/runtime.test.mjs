import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { RuntimeManager } from '../src/core/runtime.mjs';
import { delay, checkAbort } from '../src/core/process.mjs';

class Child extends EventEmitter {
  constructor() {
    super();
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this.exitCode = null;
    this.signalCode = null;
    this.signals = [];
    this.pid = 1234567;
  }
  exit(code = 0, signal = null) {
    if (this.exitCode !== null || this.signalCode !== null) return;
    this.exitCode = code;
    this.signalCode = signal;
    this.emit('exit', code, signal);
    this.emit('close', code, signal);
  }
  kill(signal) {
    this.signals.push(signal);
    if (!this.ignoreKill) this.exit(null, signal);
    return true;
  }
}
class Bridge extends EventEmitter {
  async start({ signal }) {
    checkAbort(signal);
    this.emit('video', { kind: 'metadata', width: 1080, height: 1920 });
  }
  async stop() {
    this.stopped = true;
  }
  input(action) {
    this.lastInput = action;
  }
}
async function fixture(t, overrides = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'droiddock-runtime-'));
  const paths = {
    root,
    sdk: path.join(root, 'sdk'),
    avd: path.join(root, 'avd'),
    userHome: path.join(root, 'user-home'),
  };
  const id = 'Fixture_Phone',
    directory = path.join(paths.avd, `${id}.avd`);
  await fs.mkdir(directory, { recursive: true });
  await fs.mkdir(paths.sdk);
  const configPath = path.join(directory, 'config.ini');
  await fs.writeFile(configPath, 'hw.ramSize=2048\n');
  const phone = { id, name: 'Fixture Phone', abi: 'x86_64', configPath };
  const context = {
    calls: [],
    children: [],
    bridges: [],
    name: id,
    root,
    paths,
    phone,
    bootTimeouts: 0,
    staleDevicePolls: 0,
    released: 0,
  };
  const environment = {
    ...process.env,
    ANDROID_HOME: paths.sdk,
    ANDROID_AVD_HOME: paths.avd,
    DROIDDOCK_FIXTURE: 'yes',
  };
  const run = async (executable, args, options = {}) => {
    checkAbort(options.signal);
    context.calls.push({ executable, args, options });
    if (context.blockAcceleration && args[0] === '-accel-check')
      await delay(10_000, options.signal);
    if (args[0] === '-accel-check')
      return { code: context.noAcceleration ? 1 : 0, stdout: 'accel: 0', stderr: '' };
    if (args[0] === 'devices') {
      const childRunning = context.children.some(
        (child) => child.exitCode === null && child.signalCode === null,
      );
      const stale = !childRunning && context.staleDevicePolls-- > 0;
      return {
        code: 0,
        stdout: `List of devices attached\n${childRunning || context.orphan ? 'emulator-5560\tdevice\n' : stale ? 'emulator-5560\toffline\n' : ''}`,
        stderr: '',
      };
    }
    if (args.includes('shell') && args.at(-1).includes('sys.boot_completed')) {
      if (context.bootTimeouts-- > 0) throw new Error('Transient ADB timeout');
      if (context.blockBoot) await delay(10_000, options.signal);
      return { code: 0, stdout: '1\n', stderr: '' };
    }
    if (args.includes('emu') && args.at(-1) === 'name')
      return { code: 0, stdout: `${context.name}\nOK\n`, stderr: '' };
    if (args.includes('emu') && args.at(-1) === 'kill') {
      if (!context.ignoreGraceful) context.children.at(-1).exit();
      return { code: 0, stdout: 'OK', stderr: '' };
    }
    if (args.includes('install')) return { code: 0, stdout: 'Success\n', stderr: '' };
    return { code: 0, stdout: '', stderr: '' };
  };
  const manager = new RuntimeManager({
    paths,
    executables: { emulator: '/fixture/emulator', adb: '/fixture/adb' },
    environment,
    serverPath: '/fixture/server',
    platform: 'linux',
    run,
    spawnProcess: (_executable, args, options) => {
      const child = new Child();
      child.args = args;
      child.options = options;
      context.children.push(child);
      queueMicrotask(() => child.emit('spawn'));
      return child;
    },
    reservePorts: async () => ({
      port: 5560,
      closeSockets: async () => {},
      release: async () => {
        context.released++;
      },
    }),
    requireStopped: async () => {
      if (context.external) throw new Error('An external emulator already uses this phone.');
    },
    withOperation: async (_paths, _id, callback) => callback(),
    bridgeFactory: () => {
      const bridge = new Bridge();
      context.bridges.push(bridge);
      return bridge;
    },
    timings: { poll: 1, graceful: 1, terminate: 1, force: 1 },
    ...overrides,
  });
  context.manager = manager;
  t.after(async () => {
    context.orphan = false;
    context.ignoreGraceful = false;
    for (const child of context.children) {
      child.ignoreKill = false;
      child.exit();
    }
    await manager.stopAll().catch(() => {});
    await fs.rm(root, { recursive: true, force: true });
  });
  return context;
}
const eventually = async (condition) => {
  const end = Date.now() + 2000;
  while (!condition()) {
    assert.ok(Date.now() < end, 'Fixture gate timed out');
    await delay(1);
  }
};

test('boot uses selected SDK environment; attach/detach reconnect display without another Android launch', async (t) => {
  const f = await fixture(t);
  const packets = [];
  f.manager.on('video', (packet) => packets.push(packet));
  assert.equal((await f.manager.start(f.phone)).state, 'running');
  assert.equal(f.bridges.length, 0, 'Start leaves the stream for explicit Attach');
  assert.deepEqual(f.children[0].args, [
    '-avd',
    f.phone.id,
    '-no-window',
    '-port',
    '5560',
    '-gpu',
    'host',
  ]);
  assert.equal(f.children[0].options.env.ANDROID_HOME, f.paths.sdk);
  await f.manager.attach(f.phone.id);
  await f.manager.attach(f.phone.id);
  assert.equal(f.children.length, 1);
  assert.equal(f.bridges.length, 2);
  assert.equal(f.bridges[0].stopped, true);
  assert.equal(packets[0].id, f.phone.id);
  await f.manager.detach(f.phone.id);
  assert.equal(f.bridges[1].stopped, true);
  assert.equal(f.manager.status(f.phone.id).state, 'running');
  assert.ok(f.calls.every((call) => call.options.env.DROIDDOCK_FIXTURE === 'yes'));
});

test('verified graceful Stop joins duplicates and preserves phone data', async (t) => {
  const f = await fixture(t);
  await f.manager.start(f.phone);
  await Promise.all([f.manager.stop(f.phone.id), f.manager.stop(f.phone.id)]);
  assert.equal(
    f.calls.filter((call) => call.args.includes('emu') && call.args.at(-1) === 'kill').length,
    1,
  );
  assert.deepEqual(f.children[0].signals, []);
  assert.deepEqual(f.manager.status(f.phone.id), {
    id: f.phone.id,
    sessionID: f.manager.status(f.phone.id).sessionID,
    state: 'idle',
    canStop: false,
  });
  assert.equal(await fs.readFile(f.phone.configPath, 'utf8'), 'hw.ramSize=2048\n');
});

test('changed serial identity is never sent emu kill; fallback targets only original child', async (t) => {
  const f = await fixture(t);
  await f.manager.start(f.phone);
  f.name = 'Unrelated_Phone';
  await f.manager.stop(f.phone.id);
  assert.equal(f.calls.filter((call) => call.args.at(-1) === 'kill').length, 0);
  assert.deepEqual(f.children[0].signals, ['SIGTERM']);
});

test('Stop cancels acceleration before a child exists', async (t) => {
  const f = await fixture(t);
  f.blockAcceleration = true;
  const started = f.manager.start(f.phone);
  const rejected = assert.rejects(started, { name: 'AbortError' });
  await eventually(() => f.calls.some((call) => call.args[0] === '-accel-check'));
  await f.manager.stop(f.phone.id);
  await rejected;
  assert.equal(f.children.length, 0);
  assert.equal(f.manager.status(f.phone.id).state, 'idle');
});

test('Stop cancels boot and then joins exact-child cleanup', async (t) => {
  const f = await fixture(t);
  f.blockBoot = true;
  const started = f.manager.start(f.phone);
  const rejected = assert.rejects(started, { name: 'AbortError' });
  await eventually(() => f.calls.some((call) => call.args.includes('shell')));
  await f.manager.stop(f.phone.id);
  await rejected;
  assert.equal(f.children[0].exitCode, 0);
  assert.equal(f.manager.status(f.phone.id).canStop, false);
});

test('ADB boot timeouts are retried within the boot deadline', async (t) => {
  const f = await fixture(t);
  f.bootTimeouts = 2;
  assert.equal((await f.manager.start(f.phone)).state, 'running');
  assert.equal(f.children.length, 1);
});

test('external and unavailable-acceleration phones never spawn', async (t) => {
  const f = await fixture(t);
  f.external = true;
  await assert.rejects(f.manager.start(f.phone), /external/);
  assert.equal(f.children.length, 0);
  f.external = false;
  f.noAcceleration = true;
  await assert.rejects(f.manager.start(f.phone), /acceleration/);
  assert.equal(f.children.length, 0);
  assert.equal(f.manager.status(f.phone.id).canStop, false);
});

test('same-name different configuration cannot reopen, replace or stop original runtime', async (t) => {
  const f = await fixture(t);
  await f.manager.start(f.phone);
  const outside = path.join(f.root, 'different.ini');
  await fs.writeFile(outside, 'other');
  await assert.rejects(f.manager.start({ ...f.phone, configPath: outside }), /outside|different/);
  assert.equal(f.children.length, 1);
  assert.equal(f.children[0].exitCode, null);
});

test('APK and URL actions verify identity and quote remote shell values', async (t) => {
  const f = await fixture(t);
  await f.manager.start(f.phone);
  const apk = path.join(f.root, "my phone's app.apk");
  await fs.writeFile(apk, 'fixture-apk');
  await f.manager.installAPK(f.phone.id, apk);
  const value = "exp://127.0.0.1:8081/'$(touch bad)'";
  await f.manager.openURL(f.phone.id, value);
  const command = f.calls.find(
    (call) =>
      call.args.includes('shell') && call.args.at(-1).includes('android.intent.action.VIEW'),
  );
  assert.ok(command.args.at(-1).includes("'\\''$(touch bad)'\\''"));
  f.name = 'Another_Phone';
  const before = f.calls.filter((call) => call.args.includes('install')).length;
  await assert.rejects(f.manager.installAPK(f.phone.id, apk), /identity/);
  assert.equal(f.calls.filter((call) => call.args.includes('install')).length, before);
  await assert.rejects(f.manager.openURL(f.phone.id, 'javascript:alert(1)'), /Unsupported/);
});

test('Windows Stop waits for stale offline ADB transport without controlling it again', async (t) => {
  const f = await fixture(t, { platform: 'win32', timings: { graceful: 1000 } });
  await f.manager.start(f.phone);
  f.staleDevicePolls = 2;
  assert.equal((await f.manager.stop(f.phone.id)).state, 'idle');
  assert.equal(f.manager.status(f.phone.id).canStop, false);
  const kill = f.calls.findIndex(
    (call) => call.args.includes('emu') && call.args.at(-1) === 'kill',
  );
  assert.ok(kill >= 0);
  assert.deepEqual(
    f.calls.slice(kill + 1).map((call) => call.args),
    [
      ['devices', '-l'],
      ['devices', '-l'],
      ['devices', '-l'],
    ],
  );
  assert.deepEqual(f.children[0].signals, []);
});

test('rotation verifies the owned guest and restores its policy before shutdown', async (t) => {
  const f = await fixture(t);
  await f.manager.start(f.phone);
  const run = f.manager.run;
  f.manager.run = async (executable, args, options) => {
    const result = await run(executable, args, options);
    if (args.at(-1) === "'wm' 'user-rotation'") return { ...result, stdout: 'free\n' };
    if (args.at(-1).includes("'get' 'system'"))
      return { ...result, stdout: args.at(-1).endsWith("'user_rotation'") ? '0\n' : '1\n' };
    return result;
  };
  await f.manager.rotate(f.phone.id, 1);
  f.name = 'Other_Phone';
  const before = f.calls.length;
  await assert.rejects(f.manager.rotate(f.phone.id, 0), /identity/);
  assert.ok(!f.calls.slice(before).some((call) => call.args.includes('shell')));
  f.name = f.phone.id;
  await f.manager.stop(f.phone.id);
  const restored = f.calls.findIndex((call) => call.args.at(-1) === "'wm' 'user-rotation' 'free'");
  const stopped = f.calls.findIndex(
    (call) => call.args.includes('emu') && call.args.at(-1) === 'kill',
  );
  assert.ok(restored >= 0 && restored < stopped);
});

test('Windows unresolved descendant retains Stop and failed Quit permits retry', async (t) => {
  const f = await fixture(t, { platform: 'win32' });
  await f.manager.start(f.phone);
  f.orphan = true;
  await assert.rejects(f.manager.stopAll(), AggregateError);
  assert.equal(f.manager.closed, false);
  assert.equal(f.manager.status(f.phone.id).state, 'error');
  assert.equal(f.manager.status(f.phone.id).canStop, true);
  f.orphan = false;
  await f.manager.stop(f.phone.id);
  assert.equal(f.manager.status(f.phone.id).canStop, false);
});

test('detach cancels an attachment waiting for serial verification', async (t) => {
  const f = await fixture(t);
  await f.manager.start(f.phone);
  const originalRun = f.manager.run;
  let blocked = false;
  f.manager.run = async (executable, args, options) => {
    if (args[0] === 'devices') {
      blocked = true;
      await delay(10_000, options.signal);
    }
    return originalRun(executable, args, options);
  };
  const attaching = f.manager.attach(f.phone.id),
    rejected = assert.rejects(attaching, { name: 'AbortError' });
  await eventually(() => blocked);
  await f.manager.detach(f.phone.id);
  await rejected;
  assert.equal(f.bridges.length, 0);
  assert.equal(f.manager.status(f.phone.id).state, 'running');
});

test('late display startup cannot publish into or clean up a replacement bridge', async (t) => {
  const f = await fixture(t);
  await f.manager.start(f.phone);
  const packets = [];
  f.manager.on('video', (packet) => packets.push(packet));
  let waiting = false;
  f.manager.bridgeFactory = () => {
    const bridge = new Bridge();
    f.bridges.push(bridge);
    if (f.bridges.length === 1)
      bridge.start = async ({ signal }) => {
        waiting = true;
        await delay(10_000, signal);
        bridge.emit('video', { kind: 'metadata', width: 1, height: 1 });
      };
    return bridge;
  };
  const attaching = f.manager.attach(f.phone.id),
    rejected = assert.rejects(attaching, { name: 'AbortError' });
  await eventually(() => waiting);
  await f.manager.detach(f.phone.id);
  await rejected;
  const old = f.bridges[0];
  assert.equal(old.stopped, true);
  await f.manager.attach(f.phone.id);
  const current = f.bridges[1];
  const count = packets.length;
  old.emit('video', { kind: 'frame', data: Buffer.from('stale') });
  old.emit('disconnect', new Error('Late disconnect'));
  assert.equal(packets.length, count);
  assert.equal(current.stopped, undefined);
  f.manager.input(f.phone.id, { type: 'key', action: 0, keycode: 3 });
  assert.equal(current.lastInput.keycode, 3);
  assert.equal(f.children.length, 1);
});

test('a restarted phone receives a fresh session identity for Stop confirmations', async (t) => {
  const f = await fixture(t);
  const first = await f.manager.start(f.phone);
  assert.match(first.sessionID, /^[0-9a-f-]{36}$/);
  await f.manager.stop(f.phone.id);
  const next = await f.manager.start(f.phone);
  assert.notEqual(next.sessionID, first.sessionID);
  assert.equal(next.canStop, true);
});
