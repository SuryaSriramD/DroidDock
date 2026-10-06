import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import {
  ByteReader,
  parseVideoMetadata,
  parsePacketHeader,
  encodeControl,
  MAX_PACKET,
} from '../src/core/scrcpy-protocol.mjs';

test('fragmented TCP headers and combined packets retain exact byte boundaries', async () => {
  const socket = new PassThrough(),
    reader = new ByteReader(socket);
  const reading = reader.read(12);
  const header = Buffer.alloc(12);
  header.writeUInt32BE(0x68323634);
  header.writeUInt32BE(1080, 4);
  header.writeUInt32BE(1920, 8);
  socket.write(header.subarray(0, 3));
  socket.write(Buffer.concat([header.subarray(3), Buffer.from([9, 8, 7])]));
  assert.deepEqual(parseVideoMetadata(await reading), {
    kind: 'metadata',
    width: 1080,
    height: 1920,
  });
  assert.deepEqual(await reader.read(3), Buffer.from([9, 8, 7]));
  socket.destroy();
});
test('64-bit packet flags are parsed without JavaScript bitwise truncation', () => {
  const bytes = Buffer.alloc(12);
  bytes.writeBigUInt64BE((1n << 62n) | 4294967297n);
  bytes.writeUInt32BE(1024, 8);
  assert.deepEqual(parsePacketHeader(bytes), {
    kind: 'frame',
    key: true,
    pts: 4294967297,
    size: 1024,
  });
  bytes.writeBigUInt64BE(1n << 63n);
  assert.equal(parsePacketHeader(bytes).kind, 'config');
  bytes.writeUInt32BE(MAX_PACKET + 1, 8);
  assert.throws(() => parsePacketHeader(bytes), /length/);
  bytes.writeUInt32BE(0, 8);
  assert.throws(() => parsePacketHeader(bytes), /length/);
});
test('touch, key and scroll wire layouts match the pinned server', () => {
  assert.deepEqual(encodeControl({ type: 'resetVideo' }), Buffer.from([17]));
  const touch = encodeControl({
    type: 'touch',
    action: 0,
    x: 100,
    y: 200,
    width: 1080,
    height: 1920,
  });
  assert.equal(touch.length, 32);
  assert.equal(touch.readBigUInt64BE(2), 0xfffffffffffffffen);
  assert.equal(touch.readUInt32BE(10), 100);
  assert.equal(touch.readUInt16BE(22), 65535);
  const up = encodeControl({ type: 'touch', action: 1, x: 100, y: 200, width: 1080, height: 1920 });
  assert.equal(up.readUInt16BE(22), 0);
  assert.equal(
    encodeControl({ type: 'key', action: 0, keycode: 4 }).toString('hex'),
    '0000000000040000000000000000',
  );
  const scroll = encodeControl({
    type: 'scroll',
    x: 0,
    y: 0,
    width: 10,
    height: 10,
    horizontal: -16,
    vertical: 16,
  });
  assert.equal(scroll.length, 21);
  assert.equal(scroll.readInt16BE(13), -32768);
  assert.equal(scroll.readInt16BE(15), 32767);
});
test('untrusted input and oversized UTF-8 are rejected before writing', () => {
  assert.throws(() => encodeControl({ type: 'raw', data: [1] }), /Unsupported/);
  assert.throws(() => encodeControl({ type: 'key', action: 10, keycode: 4 }), /action/);
  assert.throws(
    () => encodeControl({ type: 'touch', action: 0, x: 10, y: 1, width: 10, height: 10 }),
    /coordinate/,
  );
  assert.throws(() => encodeControl({ type: 'text', text: '😀'.repeat(76) }), /limit/);
  const text = encodeControl({ type: 'text', text: '日本語' });
  assert.equal(text.readUInt32BE(1), 9);
});
test('socket close, cancellation and oversized buffers reject pending reads', async () => {
  const socket = new PassThrough(),
    reader = new ByteReader(socket, 16);
  const pending = assert.rejects(reader.read(10), /limit/);
  socket.write(Buffer.alloc(17));
  await pending;
  const other = new PassThrough(),
    r = new ByteReader(other),
    controller = new AbortController();
  const cancelled = assert.rejects(r.read(1, { signal: controller.signal }), {
    name: 'AbortError',
  });
  controller.abort();
  await cancelled;
  other.destroy();
  await assert.rejects(r.read(1), /closed/);
});
