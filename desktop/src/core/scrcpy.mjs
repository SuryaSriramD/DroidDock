import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { createConnection } from 'node:net';
import { readFile, stat } from 'node:fs/promises';
import { createHash, randomInt } from 'node:crypto';
import { runProcess, requireSuccess, checkAbort, delay, shellArguments } from './process.mjs';
import {
  SERVER_VERSION,
  SERVER_SHA256,
  ByteReader,
  parseVideoMetadata,
  parsePacketHeader,
  encodeControl,
} from './scrcpy-protocol.mjs';

/** Single-use bridge. It owns only its sockets, one ADB child, forward and JAR. */
export class ScrcpyBridge extends EventEmitter {
  constructor({
    adb,
    environment,
    serial,
    serverPath,
    run = runProcess,
    spawnProcess = spawn,
    connect = createConnection,
    handshakeTimeout = 20_000,
  }) {
    super();
    Object.assign(this, {
      adb,
      environment,
      serial,
      serverPath,
      run,
      spawnProcess,
      connect,
      handshakeTimeout,
    });
    this.scid = randomInt(1, 0x80000000).toString(16).padStart(8, '0');
    this.remotePath = `/data/local/tmp/android-simulator-${this.scid}.jar`;
    this.controller = new AbortController();
    this.stopped = false;
    this.started = false;
    this.connected = false;
    this.inputQueue = [];
    this.inputBytes = 0;
    this.sending = false;
    this.log = '';
    this.sockets = new Set();
  }
  command(args, options = {}) {
    return this.run(this.adb, ['-s', this.serial, ...args], { env: this.environment, ...options });
  }
  async start({ signal } = {}) {
    if (this.started || this.stopped) throw new Error('Create a new display bridge to reconnect.');
    this.started = true;
    this.signal = signal
      ? AbortSignal.any([signal, this.controller.signal])
      : this.controller.signal;
    try {
      checkAbort(this.signal);
      if ((await stat(this.serverPath)).size > 2 * 1024 * 1024)
        throw new Error('The bundled display server is too large.');
      const bytes = await readFile(this.serverPath);
      if (createHash('sha256').update(bytes).digest('hex') !== SERVER_SHA256)
        throw new Error('The bundled scrcpy server failed its integrity check.');
      checkAbort(this.signal);
      this.pushAttempted = true;
      requireSuccess(
        await this.command(['push', this.serverPath, this.remotePath], { signal: this.signal }),
        'Push display server',
      );
      checkAbort(this.signal);
      this.forwardAttempted = true;
      const result = requireSuccess(
        await this.command(['forward', 'tcp:0', `localabstract:scrcpy_${this.scid}`], {
          signal: this.signal,
        }),
        'Allocate display port',
      );
      const port = Number(result.stdout.trim());
      if (!Number.isInteger(port) || port < 1 || port > 65535)
        throw new Error('ADB returned an invalid display port.');
      this.port = port;
      checkAbort(this.signal);
      this.launchServer();
      const deadline = Date.now() + this.handshakeTimeout;
      let video, lastError;
      while (Date.now() < deadline) {
        checkAbort(this.signal);
        if (this.childExited) throw new Error(`Display server exited. ${this.log}`);
        const candidate = this.socket(port);
        try {
          const dummy = await candidate.reader.read(1, {
            signal: this.signal,
            timeout: Math.min(1000, Math.max(1, deadline - Date.now())),
          });
          if (dummy[0] !== 0) throw new Error('Invalid display handshake.');
          video = candidate;
          break;
        } catch (error) {
          lastError = error;
          candidate.socket.destroy();
          this.sockets.delete(candidate.socket);
          checkAbort(this.signal);
          await delay(100, this.signal);
        }
      }
      if (!video)
        throw new Error(
          `Display connection timed out. ${lastError?.message ?? ''} ${this.log.trim().slice(-4096)}`.trim(),
        );
      const control = this.socket(port);
      this.control = control.socket;
      // Accept control before awaiting codec metadata; otherwise the server waits forever.
      const metadata = parseVideoMetadata(
        await video.reader.read(12, { signal: this.signal, timeout: this.handshakeTimeout }),
      );
      this.connected = true;
      this.emit('video', metadata);
      this.controlTask = this.receiveControl(control.reader).catch((error) =>
        this.disconnected(error),
      );
      // Reading one complete encoded frame proves more than a successful handshake.
      let firstFrame = false;
      const frameDeadline = Date.now() + this.handshakeTimeout;
      while (!firstFrame) {
        if (Date.now() >= frameDeadline) throw new Error('The display produced no video frame.');
        const packet = await this.packet(video.reader, Math.max(1, frameDeadline - Date.now()));
        this.emit('video', packet);
        firstFrame = packet.kind === 'frame';
      }
      this.videoTask = this.receiveVideo(video.reader).catch((error) => this.disconnected(error));
      checkAbort(this.signal);
      return metadata;
    } catch (error) {
      await this.stop();
      throw error;
    }
  }
  socket(port) {
    const socket = this.connect({ port, host: '127.0.0.1' });
    socket.setNoDelay?.(true);
    this.sockets.add(socket);
    return { socket, reader: new ByteReader(socket) };
  }
  launchServer() {
    const args = [
      '-s',
      this.serial,
      'shell',
      `CLASSPATH=${this.remotePath}`,
      'app_process',
      '/',
      'com.genymobile.scrcpy.Server',
      SERVER_VERSION,
      `scid=${this.scid}`,
      'log_level=info',
      'audio=false',
      'video=true',
      'control=true',
      'video_codec=h264',
      'video_codec_options=i-frame-interval=1',
      'max_size=1920',
      'max_fps=60',
      'video_bit_rate=8000000',
      'tunnel_forward=true',
      'send_device_meta=false',
      'send_codec_meta=true',
      'send_frame_meta=true',
      'send_dummy_byte=true',
      'clipboard_autosync=false',
      'cleanup=true',
    ];
    const child = this.spawnProcess(this.adb, args, {
      env: this.environment,
      shell: false,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    this.child = child;
    for (const stream of [child.stdout, child.stderr])
      stream?.on('data', (bytes) => {
        this.log = (this.log + bytes.toString()).slice(-32768);
      });
    child.on('error', (error) => {
      this.childExited = true;
      this.disconnected(error);
    });
    child.once('exit', (code) => {
      this.childExited = true;
      this.disconnected(new Error(`Display server exited (${code}). ${this.log}`));
    });
  }
  async packet(reader, timeout = 0) {
    const header = parsePacketHeader(await reader.read(12, { signal: this.signal, timeout }));
    const data = await reader.read(header.size, { signal: this.signal, timeout });
    return { kind: header.kind, key: header.key, pts: header.pts, data };
  }
  async receiveVideo(reader) {
    while (!this.stopped) this.emit('video', await this.packet(reader));
  }
  async receiveControl(reader) {
    while (!this.stopped) {
      const type = (await reader.read(1, { signal: this.signal }))[0];
      if (type === 0) {
        const count = (await reader.read(4, { signal: this.signal })).readUInt32BE();
        if (count > 1 << 18) throw new Error('Oversized device clipboard message.');
        const bytes = await reader.read(count, { signal: this.signal });
        const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
        this.emit('clipboard', text);
      } else if (type === 1) await reader.read(8, { signal: this.signal });
      else if (type === 2) {
        const header = await reader.read(4, { signal: this.signal });
        await reader.read(header.readUInt16BE(2), { signal: this.signal });
      } else throw new Error(`Unknown device control message ${type}.`);
    }
  }
  input(action) {
    const data = encodeControl(action);
    if (!this.connected || this.stopped) throw new Error('The display is not connected.');
    const move = action.type === 'touch' && action.action === 2;
    const last = this.inputQueue.at(-1);
    if (move && last?.move) {
      this.inputBytes -= last.data.length;
      this.inputQueue.pop();
    }
    if (this.inputQueue.length >= 128 || this.inputBytes + data.length > 1024 * 1024) {
      const error = new Error('The Android input channel stopped responding.');
      this.disconnected(error);
      throw error;
    }
    this.inputQueue.push({ data, move });
    this.inputBytes += data.length;
    if (!this.sending) {
      this.sending = true;
      this.flushInput().catch((error) => this.disconnected(error));
    }
  }
  async flushInput() {
    try {
      while (!this.stopped && this.inputQueue.length) {
        const { data } = this.inputQueue.shift();
        this.inputBytes -= data.length;
        await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('Input channel timed out.')), 3000);
          this.control.write(data, (error) => {
            clearTimeout(timer);
            error ? reject(error) : resolve();
          });
        });
      }
    } finally {
      this.sending = false;
    }
  }
  disconnected(error) {
    if (this.stopped || this.disconnectReported) return;
    this.disconnectReported = true;
    if (this.connected) this.emit('disconnect', error);
    void this.stop();
  }
  stop() {
    if (this.stopTask) return this.stopTask;
    this.stopped = true;
    this.connected = false;
    this.controller.abort();
    this.inputQueue = [];
    this.inputBytes = 0;
    for (const socket of this.sockets) socket.destroy();
    this.sockets.clear();
    this.stopTask = (async () => {
      // Cleanup deliberately has no cancelled start signal.
      if (this.port) {
        await this.command(['forward', '--remove', `tcp:${this.port}`], { timeout: 3000 }).catch(
          () => {},
        );
        this.port = null;
      } else if (this.forwardAttempted) {
        // Cancellation can arrive after adb installs a forward but before its
        // allocated port reaches us. Recover only this serial + random SCID.
        const result = await this.command(['forward', '--list'], { timeout: 3000 }).catch(
          () => null,
        );
        for (const line of result?.stdout?.split(/\r?\n/) ?? []) {
          const [serial, local, remote] = line.trim().split(/\s+/);
          if (
            serial === this.serial &&
            /^tcp:\d+$/.test(local ?? '') &&
            remote === `localabstract:scrcpy_${this.scid}`
          )
            await this.command(['forward', '--remove', local], { timeout: 3000 }).catch(() => {});
        }
      }
      if (this.pushAttempted)
        await this.command(shellArguments(['rm', '-f', this.remotePath]), { timeout: 3000 }).catch(
          () => {},
        );
      const child = this.child;
      if (child && !this.childExited) {
        child.kill('SIGTERM');
        await delay(300);
        if (!this.childExited) child.kill('SIGKILL');
      }
      await Promise.allSettled([this.videoTask, this.controlTask]);
    })();
    return this.stopTask;
  }
}
