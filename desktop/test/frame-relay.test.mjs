import test from 'node:test';
import assert from 'node:assert/strict';
import { FrameRelay } from '../src/core/frame-relay.mjs';
test('a dropped delta stays suppressed through codec metadata until a new keyframe', () => {
  const relay = new FrameRelay(1),
    frame = { id: 'phone', kind: 'frame', key: false, data: Buffer.from([1]) };
  const first = relay.packet(frame);
  assert.ok(first);
  assert.equal(relay.packet(frame), null);
  relay.acknowledge(first.sequence);
  const config = relay.packet({ ...frame, kind: 'config' });
  assert.ok(config);
  relay.acknowledge(config.sequence);
  assert.equal(relay.packet(frame), null);
  const key = relay.packet({ ...frame, key: true });
  assert.equal(key.reset, true);
  assert.ok(key.data instanceof Uint8Array);
  relay.acknowledge(key.sequence);
  assert.equal(relay.packet(frame).reset, false);
});
test('acks cannot add capacity and dropping one phone does not poison another', () => {
  const relay = new FrameRelay(1);
  const first = relay.packet({ id: 'a', kind: 'frame', key: false });
  relay.acknowledge(9999);
  assert.equal(relay.packet({ id: 'a', kind: 'frame', key: false }), null);
  relay.acknowledge(first.sequence);
  assert.ok(relay.packet({ id: 'b', kind: 'frame', key: false }));
  relay.clear();
  assert.equal(relay.pending.size, 0);
});

test('metadata traffic has a hard bound when the renderer stops acknowledging', () => {
  const relay = new FrameRelay(1);
  for (let i = 0; i < 5; i++) relay.packet({ id: 'a', kind: 'config' });
  assert.throws(() => relay.packet({ id: 'a', kind: 'config' }), /not consuming/);
});
