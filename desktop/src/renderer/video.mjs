export function annexBNALs(bytes) {
  const starts = [];
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] === 0 && bytes[i + 1] === 0 && bytes[i + 2] === 1) {
      starts.push([i, i + 3]);
      i += 2;
    } else if (bytes[i] === 0 && bytes[i + 1] === 0 && bytes[i + 2] === 0 && bytes[i + 3] === 1) {
      starts.push([i, i + 4]);
      i += 3;
    }
  }
  return starts.map((start, index) =>
    bytes.slice(start[1], starts[index + 1]?.[0] ?? bytes.length),
  );
}
const concat = (chunks) => {
  const result = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let offset = 0;
  for (const c of chunks) {
    result.set(c, offset);
    offset += c.length;
  }
  return result;
};
const same = (a, b) => a?.length === b?.length && a.every((v, i) => v === b[i]);
export class PhoneVideo {
  constructor(canvas, { onFrame, onError, onRecovery = () => {} }) {
    this.canvas = canvas;
    this.onFrame = onFrame;
    this.onError = onError;
    this.onRecovery = onRecovery;
    this.context = canvas.getContext('2d', { alpha: false });
    this.generation = 0;
    this.waitKey = true;
    this.sps = null;
    this.pps = null;
    this.pending = [];
    this.configuring = false;
  }
  close() {
    this.generation++;
    const old = this.decoder;
    this.decoder = null;
    if (old && old.state !== 'closed') old.close();
    this.sps = null;
    this.pps = null;
    this.config = null;
    this.waitKey = true;
    this.pending = [];
    this.configuring = false;
    this.context.clearRect(0, 0, this.canvas.width, this.canvas.height);
  }
  async configure() {
    if (!this.sps || !this.pps || this.sps.length < 4) return;
    const generation = ++this.generation;
    this.pending = [];
    this.configuring = true;
    const old = this.decoder;
    this.decoder = null;
    if (old && old.state !== 'closed') old.close();
    this.waitKey = true;
    const codec =
      'avc1.' + [...this.sps.slice(1, 4)].map((v) => v.toString(16).padStart(2, '0')).join('');
    const config = { codec, optimizeForLatency: true, hardwareAcceleration: 'no-preference' };
    try {
      if (
        typeof VideoDecoder === 'undefined' ||
        !(await VideoDecoder.isConfigSupported(config)).supported
      )
        throw new Error('H.264 video is unavailable in this build.');
      if (generation !== this.generation) return;
      this.config = config;
      this.decoder = new VideoDecoder({
        output: (frame) => {
          try {
            if (generation !== this.generation) return;
            const width = frame.displayWidth,
              height = frame.displayHeight;
            if (this.canvas.width !== width || this.canvas.height !== height) {
              this.canvas.width = width;
              this.canvas.height = height;
            }
            this.context.drawImage(frame, 0, 0, width, height);
            this.onFrame(width, height);
          } finally {
            frame.close();
          }
        },
        error: (error) => {
          if (generation === this.generation) {
            this.waitKey = true;
            this.onError(error.message);
          }
        },
      });
      this.decoder.configure(config);
      this.configuring = false;
      const pending = this.pending;
      this.pending = [];
      for (const packet of pending) this.handle(packet);
    } catch (error) {
      if (generation === this.generation) {
        this.configuring = false;
        this.pending = [];
        this.onError(error.message);
      }
    }
  }
  handle(packet) {
    const data = packet.data && new Uint8Array(packet.data);
    if (packet.kind === 'config' && data) {
      let changed = false;
      for (const nal of annexBNALs(data)) {
        const type = nal[0] & 31;
        if (type === 7 && !same(this.sps, nal)) {
          this.sps = nal;
          changed = true;
        }
        if (type === 8 && !same(this.pps, nal)) {
          this.pps = nal;
          changed = true;
        }
      }
      if (changed) void this.configure();
      return;
    }
    if (packet.kind === 'frame' && this.configuring) {
      if (this.pending.length >= 8) {
        this.pending = [];
        this.waitKey = true;
      }
      this.pending.push(packet);
      return;
    }
    if (packet.kind !== 'frame' || !data || !this.decoder || this.decoder.state !== 'configured')
      return;
    if (packet.reset || this.decoder.decodeQueueSize > 6) {
      this.decoder.reset();
      this.decoder.configure(this.config);
      this.waitKey = true;
      // A static Android surface may never produce another IDR on its own.
      if (!packet.key) this.onRecovery();
    }
    if (this.waitKey && !packet.key) return;
    try {
      const bytes = packet.key
        ? concat([
            new Uint8Array([0, 0, 0, 1]),
            this.sps,
            new Uint8Array([0, 0, 0, 1]),
            this.pps,
            data,
          ])
        : data;
      this.decoder.decode(
        new EncodedVideoChunk({
          type: packet.key ? 'key' : 'delta',
          timestamp: Number(packet.pts),
          data: bytes,
        }),
      );
      this.waitKey = false;
    } catch (error) {
      this.waitKey = true;
      this.onError(error.message);
    }
  }
}
