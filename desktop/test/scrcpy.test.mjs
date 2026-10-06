import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ScrcpyBridge } from '../src/core/scrcpy.mjs';
import { delay } from '../src/core/process.mjs';

const bundledServer = fileURLToPath(new URL('../../Resources/scrcpy-server', import.meta.url));
function packet(flags, data) {
  const header = Buffer.alloc(12);
  header.writeBigUInt64BE(flags);
  header.writeUInt32BE(data.length, 8);
  return Buffer.concat([header, data]);
}
class Child extends EventEmitter {
  constructor() {
    super();
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this.signals = [];
  }
  kill(signal) {
    this.signals.push(signal);
    this.emit('exit', 0);
    return true;
  }
}
test('real loopback fixture verifies video/control connection order, packet parsing, input and scoped cleanup', async (t) => {
  const sockets = [],
    controlBytes = [],
    calls = [],
    child = new Child();
  const metadata = Buffer.alloc(12);
  metadata.writeUInt32BE(0x68323634);
  metadata.writeUInt32BE(1080, 4);
  metadata.writeUInt32BE(1920, 8);
  const config = Buffer.from([0, 0, 0, 1, 0x67, 0x42, 0, 0x1e, 0, 0, 0, 1, 0x68, 0]);
  const frame = Buffer.from([0, 0, 0, 1, 0x65, 1, 2, 3]);
  const server = createServer((socket) => {
    sockets.push(socket);
    socket.on('error', () => {});
    if (sockets.length === 1) socket.write(Buffer.from([0]));
    else {
      socket.on('data', (data) => controlBytes.push(Buffer.from(data)));
      // Metadata intentionally waits for the control connection.
      sockets[0].write(metadata.subarray(0, 5));
      sockets[0].write(
        Buffer.concat([
          metadata.subarray(5),
          packet(1n << 63n, config),
          packet((1n << 62n) | 12345n, frame),
        ]),
      );
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const bridge = new ScrcpyBridge({
    adb: '/fixture/adb',
    environment: { FIXTURE: '1' },
    serial: 'emulator-5560',
    serverPath: bundledServer,
    run: async (_exe, args, options) => {
      calls.push({ args, options });
      return {
        code: 0,
        stdout: args.includes('tcp:0') ? String(server.address().port) : '',
        stderr: '',
      };
    },
    spawnProcess: (_exe, args, options) => {
      child.args = args;
      child.options = options;
      return child;
    },
  });
  t.after(async () => {
    await bridge.stop();
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
  });
  const events = [];
  bridge.on('video', (event) => events.push(event));
  await bridge.start();
  assert.equal(sockets.length, 2);
  assert.deepEqual(
    events.map((event) => event.kind),
    ['metadata', 'config', 'frame'],
  );
  assert.deepEqual(events[1].data, config);
  assert.equal(events[2].key, true);
  assert.equal(events[2].pts, 12345);
  assert.ok(child.args.includes('send_device_meta=false'));
  assert.ok(child.args.includes('audio=false'));
  assert.equal(child.options.env.FIXTURE, '1');
  bridge.input({ type: 'key', action: 0, keycode: 4 });
  const deadline = Date.now() + 1000;
  while (!controlBytes.length) {
    assert.ok(Date.now() < deadline);
    await delay(1);
  }
  assert.equal(Buffer.concat(controlBytes).readUInt32BE(2), 4);
  await bridge.stop();
  assert.ok(
    calls.some(
      (call) =>
        call.args.includes('--remove') && call.args.includes(`tcp:${server.address().port}`),
    ),
  );
  assert.ok(
    calls.some(
      (call) => call.args.includes('shell') && call.args.at(-1).includes(bridge.remotePath),
    ),
  );
  assert.ok(calls.every((call) => call.args[0] === '-s' && call.args[1] === 'emulator-5560'));
  assert.deepEqual(child.signals, ['SIGTERM']);
});

test('invalid bundled server is rejected before any ADB call', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'droiddock-scrcpy-'));
  const file = path.join(root, 'server');
  await fs.writeFile(file, 'invalid');
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  let calls = 0;
  const bridge = new ScrcpyBridge({
    adb: '/fixture/adb',
    serial: 'emulator-5560',
    serverPath: file,
    run: async () => {
      calls++;
      return { code: 0, stdout: '' };
    },
  });
  await assert.rejects(bridge.start(), /integrity/);
  assert.equal(calls, 0);
});

test('cancelled forward allocation removes only the exact random SCID mapping', async () => {
  const removed = [];
  let bridge;
  bridge = new ScrcpyBridge({
    adb: '/fixture/adb',
    serial: 'emulator-5560',
    serverPath: bundledServer,
    run: async (_exe, args) => {
      if (args.includes('tcp:0'))
        throw new DOMException('Cancelled after forward creation', 'AbortError');
      if (args.includes('--list'))
        return {
          code: 0,
          stdout: `emulator-5560 tcp:34567 localabstract:scrcpy_${bridge.scid}\nemulator-5554 tcp:34568 localabstract:scrcpy_other\n`,
        };
      if (args.includes('--remove')) removed.push(args.at(-1));
      return { code: 0, stdout: '' };
    },
  });
  await assert.rejects(bridge.start(), { name: 'AbortError' });
  assert.deepEqual(removed, ['tcp:34567']);
});
