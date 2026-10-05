import test from 'node:test';
import assert from 'node:assert/strict';
import { annexBNALs, PhoneVideo } from '../src/renderer/video.mjs';
const config = new Uint8Array([0, 0, 0, 1, 0x67, 0x42, 0xe0, 0x1f, 1, 0, 0, 1, 0x68, 2]);
const frame = { kind: 'frame', key: true, pts: 123, data: new Uint8Array([0, 0, 0, 1, 0x65, 9]) };
test('Annex B parsing preserves SPS/PPS across three/four-byte start codes', () => {
  assert.deepEqual(
    annexBNALs(config).map((v) => [...v]),
    [
      [0x67, 0x42, 0xe0, 0x1f, 1],
      [0x68, 2],
    ],
  );
});
test('first key frame waits for codec support, includes parameter sets, and closes output frames', async () => {
  const originals = {
    VideoDecoder: globalThis.VideoDecoder,
    EncodedVideoChunk: globalThis.EncodedVideoChunk,
  };
  const decoded = [],
    errors = [];
  let draw = 0,
    closed = 0,
    supported;
  globalThis.VideoDecoder = class {
    static isConfigSupported() {
      return new Promise((resolve) => (supported = resolve));
    }
    constructor(callbacks) {
      this.callbacks = callbacks;
      this.state = 'unconfigured';
      this.decodeQueueSize = 0;
    }
    configure(config) {
      this.configuration = config;
      this.state = 'configured';
    }
    decode(chunk) {
      decoded.push(chunk);
      this.callbacks.output({ displayWidth: 720, displayHeight: 1280, close: () => closed++ });
    }
    reset() {
      this.state = 'unconfigured';
    }
    close() {
      this.state = 'closed';
    }
  };
  globalThis.EncodedVideoChunk = class {
    constructor(value) {
      Object.assign(this, value);
    }
  };
  const canvas = {
    width: 0,
    height: 0,
    getContext: () => ({ drawImage: () => draw++, clearRect() {} }),
  };
  try {
    const video = new PhoneVideo(canvas, { onFrame() {}, onError: (error) => errors.push(error) });
    video.handle({ kind: 'config', data: config });
    video.handle(frame);
    assert.equal(decoded.length, 0);
    supported({ supported: true });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(decoded.length, 1);
    assert.equal(decoded[0].timestamp, 123);
    assert.deepEqual(
      annexBNALs(decoded[0].data).map((n) => n[0] & 31),
      [7, 8, 5],
    );
    assert.equal(video.decoder.configuration.codec, 'avc1.42e01f');
    assert.equal(video.decoder.configuration.description, undefined);
    assert.equal(canvas.width, 720);
    assert.equal(draw, 1);
    assert.equal(closed, 1);
    assert.deepEqual(errors, []);
    video.handle({ ...frame, key: false, reset: true });
    assert.equal(decoded.length, 1, 'a dropped reference frame requires a new key frame');
    video.handle(frame);
    assert.equal(decoded.length, 2);
    video.close();
    assert.equal(video.decoder, null);
  } finally {
    Object.assign(globalThis, originals);
  }
});
