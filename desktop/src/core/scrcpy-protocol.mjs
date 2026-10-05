export const SERVER_VERSION = '3.3.3';
export const SERVER_SHA256 = '7e70323ba7f259649dd4acce97ac4fefbae8102b2c6d91e2e7be613fd5354be0';
export const MAX_PACKET = 8 * 1024 * 1024;

export function parseVideoMetadata(data) {
  if (data.length !== 12 || data.readUInt32BE(0) !== 0x68323634)
    throw new Error('The display server did not provide H.264 video.');
  const width = data.readUInt32BE(4),
    height = data.readUInt32BE(8);
  if (!width || !height || width > 8192 || height > 8192)
    throw new Error('Invalid display dimensions.');
  return { kind: 'metadata', width, height };
}

export function parsePacketHeader(data) {
  if (data.length !== 12) throw new Error('Invalid video packet header.');
  const value = data.readBigUInt64BE(0),
    size = data.readUInt32BE(8);
  const pts = value & ((1n << 62n) - 1n);
  if (!size || size > MAX_PACKET || pts > BigInt(Number.MAX_SAFE_INTEGER))
    throw new Error('Invalid video packet length or timestamp.');
  return {
    kind: value & (1n << 63n) ? 'config' : 'frame',
    key: Boolean(value & (1n << 62n)),
    pts: Number(pts),
    size,
  };
}

/** TCP is a byte stream; reads may split headers or contain several packets. */
export class ByteReader {
  constructor(socket, maximum = MAX_PACKET * 2) {
    this.socket = socket;
    this.maximum = maximum;
    this.chunks = [];
    this.length = 0;
    this.pending = null;
    this.error = null;
    socket.on('data', (data) => {
      if (this.error) return;
      if (this.length + data.length > this.maximum) {
        this.fail(new Error('Display receive buffer exceeded its limit.'));
        socket.destroy();
        return;
      }
      this.chunks.push(data);
      this.length += data.length;
      this.pump();
    });
    socket.on('error', (error) => this.fail(error));
    socket.on('end', () => this.fail(new Error('The display stream closed.')));
    socket.on('close', () => this.fail(new Error('The display connection closed.')));
  }
  read(size, { timeout = 0, signal } = {}) {
    if (!Number.isInteger(size) || size < 0 || size > this.maximum)
      return Promise.reject(new Error('Invalid read length.'));
    if (this.pending)
      return Promise.reject(new Error('Concurrent reads on one display channel are not allowed.'));
    if (signal?.aborted) return Promise.reject(new DOMException('Cancelled', 'AbortError'));
    return new Promise((resolve, reject) => {
      let timer;
      const cancel = () => done(new DOMException('Cancelled', 'AbortError'));
      const done = (error, data) => {
        clearTimeout(timer);
        signal?.removeEventListener('abort', cancel);
        this.pending = null;
        error ? reject(error) : resolve(data);
      };
      this.pending = { size, done };
      if (timeout)
        timer = setTimeout(() => done(new Error('Display handshake timed out.')), timeout);
      signal?.addEventListener('abort', cancel, { once: true });
      this.pump();
    });
  }
  pump() {
    const pending = this.pending;
    if (!pending) return;
    if (this.length < pending.size) {
      if (this.error) pending.done(this.error);
      return;
    }
    const output = Buffer.allocUnsafe(pending.size);
    let written = 0;
    while (written < output.length) {
      const first = this.chunks[0],
        count = Math.min(first.length, output.length - written);
      first.copy(output, written, 0, count);
      written += count;
      this.length -= count;
      if (count === first.length) this.chunks.shift();
      else this.chunks[0] = first.subarray(count);
    }
    pending.done(null, output);
  }
  fail(error) {
    this.error ||= error;
    this.pump();
  }
}

function integer(value, min, max, name) {
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`Invalid ${name}.`);
  return value;
}
function position(action, output, offset) {
  const width = integer(action.width, 1, 8192, 'width'),
    height = integer(action.height, 1, 8192, 'height');
  output.writeUInt32BE(integer(action.x, 0, width - 1, 'x coordinate'), offset);
  output.writeUInt32BE(integer(action.y, 0, height - 1, 'y coordinate'), offset + 4);
  output.writeUInt16BE(width, offset + 8);
  output.writeUInt16BE(height, offset + 10);
}
function utf8(text, maximum) {
  if (typeof text !== 'string') throw new Error('Text must be a string.');
  const bytes = Buffer.from(text, 'utf8');
  if (bytes.length > maximum) throw new Error(`Text exceeds the ${maximum}-byte limit.`);
  return bytes;
}
function scroll(value) {
  if (!Number.isFinite(value)) throw new Error('Invalid scroll amount.');
  return Math.max(-32768, Math.min(32767, Math.trunc((value / 16) * 32768)));
}

/** Only typed actions are accepted from renderer IPC, never raw control bytes. */
export function encodeControl(action) {
  if (!action || typeof action !== 'object') throw new Error('Invalid input action.');
  let data;
  switch (action.type) {
    case 'key':
      data = Buffer.alloc(14);
      data[1] = integer(action.action, 0, 1, 'key action');
      data.writeUInt32BE(integer(action.keycode, 0, 65535, 'Android keycode'), 2);
      return data;
    case 'touch':
      data = Buffer.alloc(32);
      data[0] = 2;
      data[1] = integer(action.action, 0, 3, 'touch action');
      data.writeBigUInt64BE(0xfffffffffffffffen, 2);
      position(action, data, 10);
      data.writeUInt16BE(action.action === 1 || action.action === 3 ? 0 : 65535, 22);
      return data;
    case 'scroll':
      data = Buffer.alloc(21);
      data[0] = 3;
      position(action, data, 1);
      data.writeInt16BE(scroll(action.horizontal), 13);
      data.writeInt16BE(scroll(action.vertical), 15);
      return data;
    case 'text': {
      const text = utf8(action.text, 300);
      data = Buffer.alloc(5);
      data[0] = 1;
      data.writeUInt32BE(text.length, 1);
      return Buffer.concat([data, text]);
    }
    case 'clipboard': {
      const text = utf8(action.text, (1 << 18) - 14);
      data = Buffer.alloc(14);
      data[0] = 9;
      data[9] = 1;
      data.writeUInt32BE(text.length, 10);
      return Buffer.concat([data, text]);
    }
    case 'getClipboard':
      return Buffer.from([8, 0]);
    case 'rotate':
      return Buffer.from([11]);
    default:
      throw new Error('Unsupported input action.');
  }
}
