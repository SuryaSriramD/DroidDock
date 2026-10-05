import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { DeviceWindows } from '../src/device-windows.mjs';

const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
};
class Window extends EventEmitter {
  constructor() {
    super();
    this.destroyed = false;
    this.minimized = false;
    this.shown = 0;
    this.focused = 0;
    this.messages = [];
    this.webContents = new EventEmitter();
    this.webContents.send = (channel, value) => this.messages.push({ channel, value });
    this.webContents.isDestroyed = () => this.destroyed;
  }
  isDestroyed() {
    return this.destroyed;
  }
  isMinimized() {
    return this.minimized;
  }
  restore() {
    this.minimized = false;
    this.restored = true;
  }
  show() {
    this.shown++;
  }
  focus() {
    this.focused++;
  }
  setTitle(value) {
    this.title = value;
  }
  loadURL(value) {
    this.url = value;
    return Promise.resolve();
  }
  close() {
    this.destroyed = true;
    this.emit('closed');
  }
}
function fixture(options = {}) {
  const statuses = new Map(),
    calls = [],
    errors = [],
    closed = [];
  const runtime = {
    status: (id) => statuses.get(id) ?? { id, state: 'idle' },
    attach: async (id) => {
      calls.push(['attach', id]);
    },
    detach: async (id) => {
      calls.push(['detach', id]);
    },
  };
  const manager = new DeviceWindows({
    createWindow: () => new Window(),
    url: 'file:///phone.html',
    runtime,
    onError: (id, error) => errors.push({ id, message: error.message }),
    onClosed: (id) => closed.push(id),
    readyTimeout: 1000,
    ...options,
  });
  const phone = { id: 'a', name: 'Android Phone' };
  const status = (id = 'a', state = 'running', sessionID = 'session-a') => {
    const value = { id, state, sessionID };
    statuses.set(id, value);
    manager.statusChanged(value);
    return value;
  };
  return { manager, runtime, statuses, calls, errors, closed, phone, status };
}
const frame = (entry, fields = {}) => ({
  streamID: entry.streamID,
  sessionID: entry.sessionID,
  width: 1080,
  height: 2400,
  ...fields,
});

test('a phone window opens before boot and reuse restores its title and focus', () => {
  const f = fixture();
  const entry = f.manager.open(f.phone);
  assert.equal(entry.window.url, 'file:///phone.html');
  assert.deepEqual(f.calls, []);
  f.status('a', 'starting');
  entry.window.emit('ready-to-show');
  assert.equal(entry.window.shown, 1);
  assert.equal(entry.window.focused, 1);
  entry.window.minimized = true;
  assert.equal(f.manager.open({ ...f.phone, name: 'Renamed phone' }), entry);
  assert.equal(entry.phone.name, 'Renamed phone');
  assert.equal(entry.window.title, 'Renamed phone');
  assert.equal(entry.window.restored, true);
  assert.equal(entry.window.focused, 2);
  assert.deepEqual(f.calls, [], 'Opening or observing running state must not auto-attach');
});

test('readiness waits for an explicit decoded frame and deduplicates pending attach', async () => {
  const f = fixture();
  const entry = f.manager.open(f.phone);
  f.status();
  const gate = deferred();
  f.runtime.attach = async (id) => {
    f.calls.push(['attach', id]);
    await gate.promise;
  };
  const attaching = f.manager.attach('a');
  assert.equal(f.manager.attach('a'), attaching);
  await Promise.resolve();
  let ready = false;
  const waiting = f.manager.waitForDisplay('a', 'session-a').then((value) => {
    ready = true;
    return value;
  });
  f.manager.video({ id: 'a', kind: 'config', data: Buffer.from([1]) });
  await Promise.resolve();
  assert.equal(ready, false);
  assert.equal(f.manager.frameReady('a', frame(entry)), true);
  await Promise.resolve();
  assert.equal(ready, false, 'Bridge startup must also succeed');
  gate.resolve();
  await attaching;
  assert.equal((await waiting).displayReady, true);
  assert.equal((await f.manager.waitForDisplay('a', 'session-a')).streamID, entry.streamID);
  assert.deepEqual(f.calls, [['attach', 'a']]);
});

test('attach failure rejects readiness but keeps the phone window and error visible', async () => {
  const f = fixture();
  const entry = f.manager.open(f.phone);
  f.status();
  f.runtime.attach = async () => {
    throw new Error('H.264 handshake failed');
  };
  const waiting = assert.rejects(f.manager.waitForDisplay('a', 'session-a'), /H.264 handshake/);
  await assert.rejects(f.manager.attach('a'), /H.264 handshake/);
  await waiting;
  assert.equal(entry.window.isDestroyed(), false);
  assert.equal(entry.error, 'H.264 handshake failed');
  assert.equal(entry.window.messages.at(-1).channel, 'dock:error');
  await assert.rejects(f.manager.waitForDisplay('a', 'session-a'), /H.264 handshake/);
  f.runtime.attach = async () => {};
  await f.manager.attach('a');
  assert.equal(entry.error, null);
  f.manager.frameReady('a', frame(entry));
  assert.equal((await f.manager.waitForDisplay('a', 'session-a')).displayReady, true);
});

test('closed-window cleanup joins before a reopened phone attaches and cannot detach its replacement', async () => {
  const f = fixture();
  const old = f.manager.open(f.phone);
  f.status();
  await f.manager.attach('a');
  const gate = deferred();
  f.runtime.detach = async (id) => {
    f.calls.push(['detach', id]);
    await gate.promise;
  };
  const rejected = assert.rejects(f.manager.waitForDisplay('a', 'session-a'), /closed/);
  old.window.close();
  await rejected;
  const next = f.manager.open(f.phone);
  const attaching = f.manager.attach('a');
  await Promise.resolve();
  assert.equal(
    next.streamID,
    null,
    'Packets from old cleanup must not be relabelled as the new stream',
  );
  f.manager.video({ id: 'a', kind: 'frame', key: true, data: Buffer.from([1]) });
  assert.equal(next.window.messages.length, 0);
  assert.equal(f.calls.filter(([kind]) => kind === 'attach').length, 1);
  old.window.emit('closed');
  old.window.webContents.emit('render-process-gone');
  gate.resolve();
  await attaching;
  assert.equal(f.manager.entries.get('a'), next);
  assert.equal(f.calls.filter(([kind]) => kind === 'detach').length, 1);
  assert.equal(f.calls.filter(([kind]) => kind === 'attach').length, 2);
  assert.deepEqual(f.closed, ['a']);
});

test('video and flow-control acknowledgements stay isolated per phone', async () => {
  const f = fixture();
  const a = f.manager.open(f.phone),
    b = f.manager.open({ id: 'b', name: 'Other phone' });
  f.status();
  f.status('b', 'running', 'session-b');
  await Promise.all([f.manager.attach('a'), f.manager.attach('b')]);
  f.manager.video({ id: 'a', kind: 'frame', key: true, data: Buffer.from([1]) });
  f.manager.video({ id: 'b', kind: 'frame', key: true, data: Buffer.from([2]) });
  assert.equal(a.window.messages.length, 1);
  assert.equal(b.window.messages.length, 1);
  const packet = a.window.messages[0].value;
  assert.equal(packet.id, 'a');
  assert.equal(packet.streamID, a.streamID);
  assert.equal(packet.sessionID, 'session-a');
  f.manager.acknowledge('a', packet.sequence);
  assert.equal(a.relay.pending.size, 0);
  assert.equal(b.relay.pending.size, 1);
  assert.equal(f.manager.frameReady('b', frame(a)), false);
});

test('timeout is a persistent per-phone error, with no false display success', async () => {
  const f = fixture({ readyTimeout: 5 });
  const entry = f.manager.open(f.phone);
  f.status();
  await f.manager.attach('a');
  await assert.rejects(f.manager.waitForDisplay('a', 'session-a'), /no decoded frame/);
  assert.match(entry.error, /no decoded frame/);
  assert.equal(entry.window.isDestroyed(), false);
  assert.equal(f.errors.at(-1).id, 'a');
  assert.equal(entry.displayReady, false);
});

test('stale sessions, streams, and invalid dimensions cannot acknowledge readiness', async () => {
  const f = fixture();
  const entry = f.manager.open(f.phone);
  f.status();
  await f.manager.attach('a');
  const old = frame(entry);
  const rejected = assert.rejects(f.manager.waitForDisplay('a', 'session-a'), /session changed/);
  f.status('a', 'starting', 'session-new');
  await rejected;
  assert.equal(f.manager.frameReady('a', old), false);
  assert.equal(entry.streamID, null);
  f.status('a', 'running', 'session-new');
  await f.manager.attach('a');
  for (const fields of [
    { streamID: old.streamID },
    { sessionID: 'session-a' },
    { width: 0 },
    { height: 8193 },
    { width: 1.5 },
  ])
    assert.equal(f.manager.frameReady('a', frame(entry, fields)), false);
  assert.equal(entry.displayReady, false);
  assert.equal(f.manager.frameReady('a', frame(entry)), true);
});

test('Stop and renderer crash reject pending readiness without closing the device window', async () => {
  const f = fixture();
  const entry = f.manager.open(f.phone);
  f.status();
  await f.manager.attach('a');
  const stopped = assert.rejects(f.manager.waitForDisplay('a', 'session-a'), /stopped/);
  f.status('a', 'stopping');
  await stopped;
  assert.equal(entry.streamID, null);
  f.status('a', 'running');
  await f.manager.attach('a');
  const crashed = assert.rejects(f.manager.waitForDisplay('a', 'session-a'), /stopped responding/);
  entry.window.webContents.emit('render-process-gone');
  await crashed;
  assert.equal(entry.window.isDestroyed(), false);
  assert.match(entry.error, /stopped responding/);
  assert.deepEqual(f.calls.at(-1), ['detach', 'a']);
});
