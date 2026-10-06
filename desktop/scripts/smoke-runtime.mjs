import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';

// Generated testsrc2, 180x320, one baseline H.264 IDR, with libx264. This is
// decoded by Chromium in smoke tests; it never starts Android or accesses ADB.
const fixture = readFileSync(new URL('../test/fixtures/smoke-phone.h264', import.meta.url));
const starts = [];
for (let i = 0; i + 3 < fixture.length; i++) {
  const size =
    fixture[i] === 0 && fixture[i + 1] === 0 && fixture[i + 2] === 1
      ? 3
      : fixture[i] === 0 && fixture[i + 1] === 0 && fixture[i + 2] === 0 && fixture[i + 3] === 1
        ? 4
        : 0;
  if (size) {
    starts.push({ offset: i, type: fixture[i + size] & 31 });
    i += size - 1;
  }
}
const nals = starts.map((entry, i) => ({
  type: entry.type,
  bytes: fixture.subarray(entry.offset, starts[i + 1]?.offset ?? fixture.length),
}));
const codec = Buffer.concat(
  nals.filter(({ type }) => [7, 8].includes(type)).map(({ bytes }) => bytes),
);
const picture = Buffer.concat(
  nals.filter(({ type }) => ![7, 8].includes(type)).map(({ bytes }) => bytes),
);
if (!nals.some(({ type }) => type === 5) || !codec.length)
  throw new Error('Invalid smoke H.264 fixture.');

export class SmokeRuntime extends EventEmitter {
  constructor() {
    super();
    this.entries = new Map();
    this.startCount = 0;
    this.attachCount = 0;
    this.inputs = [];
    this.failures = new Map();
    this.videoPaused = false;
    this.pendingVideo = [];
  }
  status(id) {
    const entry = this.entries.get(id);
    return entry
      ? {
          id,
          state: entry.state,
          sessionID: entry.sessionID,
          canStop: entry.state !== 'idle',
          ...(entry.state === 'running' && { serial: 'smoke-fixture' }),
        }
      : { id, state: 'idle', canStop: false };
  }
  statuses() {
    return [...this.entries.keys()].map((id) => this.status(id));
  }
  publish(entry, state) {
    entry.state = state;
    this.emit('state', this.status(entry.id));
  }
  async start(phone) {
    const previous = this.entries.get(phone.id);
    if (previous?.state === 'running') return this.status(phone.id);
    if (previous?.state === 'starting') return previous.startTask;
    const entry = {
      id: phone.id,
      sessionID: randomUUID(),
      state: 'starting',
      displayGeneration: 0,
      timers: new Set(),
    };
    this.entries.set(phone.id, entry);
    this.startCount++;
    const gate = new Promise((resolve, reject) => {
      entry.releaseBoot = resolve;
      entry.cancelBoot = reject;
    });
    this.publish(entry, 'starting');
    entry.startTask = (async () => {
      await gate;
      if (this.entries.get(phone.id) !== entry || entry.state !== 'starting')
        throw new Error('Smoke boot was cancelled.');
      this.publish(entry, 'running');
      return this.status(phone.id);
    })();
    return entry.startTask;
  }
  releaseBoot(id) {
    this.entries.get(id)?.releaseBoot();
  }
  failNextAttachment(id, message = 'Fixture display connection failed') {
    this.failures.set(id, message);
  }
  pauseVideo() {
    this.videoPaused = true;
  }
  releaseVideo() {
    this.videoPaused = false;
    const pending = this.pendingVideo;
    this.pendingVideo = [];
    for (const send of pending) send();
  }
  async attach(id) {
    const entry = this.entries.get(id);
    if (entry?.state !== 'running') throw new Error('Smoke phone is not running.');
    this.attachCount++;
    const generation = ++entry.displayGeneration;
    if (this.failures.has(id)) {
      const message = this.failures.get(id);
      this.failures.delete(id);
      throw new Error(message);
    }
    const send = () => {
      if (
        this.entries.get(id) !== entry ||
        entry.state !== 'running' ||
        entry.displayGeneration !== generation
      )
        return;
      this.emit('video', { id, kind: 'metadata', width: 180, height: 320 });
      this.emit('video', { id, kind: 'config', pts: 0, key: false, data: codec });
      const frame = (pts) => {
        if (entry.state === 'running' && entry.displayGeneration === generation)
          this.emit('video', { id, kind: 'frame', pts, key: true, data: picture });
      };
      frame(0);
      for (const ms of [80, 160]) {
        const timer = setTimeout(() => {
          entry.timers.delete(timer);
          frame(ms * 1000);
        }, ms);
        entry.timers.add(timer);
      }
    };
    if (this.videoPaused) this.pendingVideo.push(send);
    else send();
    return this.status(id);
  }
  async detach(id) {
    const entry = this.entries.get(id);
    if (!entry) return;
    entry.displayGeneration++;
    for (const timer of entry.timers) clearTimeout(timer);
    entry.timers.clear();
  }
  input(id, action) {
    if (this.status(id).state !== 'running') throw new Error('Smoke phone is not running.');
    this.inputs.push({ id, action });
  }
  async stop(id) {
    const entry = this.entries.get(id);
    if (!entry) return this.status(id);
    const starting = entry.state === 'starting';
    this.publish(entry, 'stopping');
    if (starting) entry.cancelBoot(new Error('Smoke boot was cancelled.'));
    await entry.startTask?.catch(() => {});
    await this.detach(id);
    this.publish(entry, 'idle');
    return this.status(id);
  }
  async stopAll() {
    await Promise.all([...this.entries.keys()].map((id) => this.stop(id)));
  }
}
