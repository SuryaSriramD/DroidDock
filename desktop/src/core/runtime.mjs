import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { runProcess, requireSuccess, checkAbort, delay, shellArguments } from './process.mjs';
import { ScrcpyBridge } from './scrcpy.mjs';
import { GuestRotation } from './guest-rotation.mjs';
import { requirePhoneStopped, withPhoneOperation } from './phones.mjs';

const reservedPorts = new Set();
const alive = (entry) =>
  Boolean(
    entry.child && !entry.exited && entry.child.exitCode == null && entry.child.signalCode == null,
  );
const validID = (id) => typeof id === 'string' && /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/.test(id);
const canonical = async (value) => path.normalize(await realpath(value));

export function parseADBDevices(text) {
  return text.split(/\r?\n/).flatMap((line) => {
    const [serial, state] = line.trim().split(/\s+/);
    return serial &&
      ['device', 'offline', 'unauthorized', 'recovery', 'bootloader', 'sideload', 'no'].includes(
        state,
      )
      ? [{ serial, state }]
      : [];
  });
}

async function bind(port) {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once('error', reject);
    server.listen({ port, host: '127.0.0.1', exclusive: true }, () => {
      server.removeListener('error', reject);
      resolve(server);
    });
  });
}
const closeServer = (server) => new Promise((resolve) => server.close(resolve));
export async function reservePortPair() {
  for (let port = 5554; port <= 5682; port += 2) {
    if (reservedPorts.has(port)) continue;
    let first, second;
    try {
      first = await bind(port);
      second = await bind(port + 1);
    } catch {
      if (first) await closeServer(first);
      continue;
    }
    reservedPorts.add(port);
    let sockets = [first, second];
    const closeSockets = async () => {
      const current = sockets;
      sockets = [];
      await Promise.all(current.map(closeServer));
    };
    return {
      port,
      closeSockets,
      release: async () => {
        await closeSockets();
        reservedPorts.delete(port);
      },
    };
  }
  throw new Error('No emulator console/ADB port pair is available.');
}

/** All mutation authority comes from the exact child this manager spawned. */
export class RuntimeManager extends EventEmitter {
  constructor({
    paths,
    executables,
    environment,
    serverPath,
    platform = process.platform,
    run = runProcess,
    spawnProcess = spawn,
    reservePorts = reservePortPair,
    requireStopped = requirePhoneStopped,
    withOperation = withPhoneOperation,
    bridgeFactory = (options) => new ScrcpyBridge(options),
    timings = {},
  }) {
    super();
    Object.assign(this, {
      paths,
      executables,
      environment,
      serverPath,
      platform,
      run,
      spawnProcess,
      reservePorts,
      requireStopped,
      withOperation,
      bridgeFactory,
    });
    this.timings = {
      boot: 180_000,
      poll: 1000,
      graceful: 8000,
      terminate: 8000,
      force: 2000,
      ...timings,
    };
    this.entries = new Map();
    this.closed = false;
  }
  status(id) {
    const entry = this.entries.get(id);
    return entry
      ? {
          id,
          sessionID: entry.token,
          state: entry.state,
          canStop: Boolean(
            entry.child || entry.bridge || entry.state === 'starting' || entry.state === 'stopping',
          ),
          ...(entry.serial && { serial: entry.serial }),
          ...(entry.error && { error: entry.error }),
        }
      : { id, state: 'idle', canStop: false };
  }
  statuses() {
    return [...this.entries.keys()].map((id) => this.status(id));
  }
  publish(entry, state, error) {
    if (this.entries.get(entry.id) !== entry) return;
    entry.state = state;
    entry.error = error;
    this.emit('state', this.status(entry.id));
    if (error) this.emit('error-message', { id: entry.id, message: error });
  }
  async identity(phone) {
    if (!phone || !validID(phone.id) || typeof phone.configPath !== 'string')
      throw new Error('Invalid phone identity.');
    const root = await canonical(this.paths.avd),
      config = await canonical(phone.configPath);
    const expected = path.join(root, `${phone.id}.avd`, 'config.ini');
    if (config !== expected || !(await stat(config)).isFile())
      throw new Error('The phone configuration is outside its managed device folder.');
    if (phone.abi !== 'x86_64') throw new Error('DroidDock requires an x86_64 Android phone.');
    return { config, sdk: await canonical(this.paths.sdk) };
  }
  async start(phone) {
    if (this.closed) throw new Error('DroidDock is shutting down.');
    if (!phone || !validID(phone.id)) throw new Error('Invalid phone ID.');
    // Reserve the identity in memory before filesystem or ADB awaits.
    const existing = this.entries.get(phone.id);
    if (
      existing &&
      (alive(existing) || existing.state === 'starting' || existing.state === 'stopping')
    ) {
      const identity = await this.identity(phone);
      if (
        !existing.identity ||
        existing.identity.config !== identity.config ||
        existing.identity.sdk !== identity.sdk
      )
        throw new Error('A different SDK or phone configuration already owns this session.');
      if (existing.state === 'running' && alive(existing)) return this.status(phone.id);
      throw new Error('This phone is already starting or stopping.');
    }
    const entry = {
      id: phone.id,
      phone: { ...phone },
      token: randomUUID(),
      state: 'starting',
      controller: new AbortController(),
      log: '',
      booted: false,
    };
    this.entries.set(phone.id, entry);
    this.publish(entry, 'starting');
    entry.startTask = this.startEntry(entry);
    try {
      await entry.startTask;
      return this.status(phone.id);
    } finally {
      entry.startTask = null;
    }
  }
  async startEntry(entry) {
    const signal = entry.controller.signal;
    try {
      entry.identity = await this.identity(entry.phone);
      checkAbort(signal);
      await this.withOperation(this.paths, entry.id, async () => {
        checkAbort(signal);
        // Both this helper and every process use this manager's selected SDK.
        await this.requireStopped({
          paths: this.paths,
          phone: entry.phone,
          platform: this.platform,
          run: (executable, args, options = {}) =>
            this.run(executable, args, { ...options, env: this.environment, signal }),
        });
        checkAbort(signal);
        const acceleration = await this.run(this.executables.emulator, ['-accel-check'], {
          env: this.environment,
          signal,
          timeout: 20_000,
        });
        if (acceleration.code !== 0)
          throw new Error(
            `Android acceleration is unavailable. Enable WHPX on Windows or KVM access on Linux. ${(acceleration.stderr || acceleration.stdout || '').trim().slice(-3000)}`,
          );
        checkAbort(signal);
        const reservation = await this.reservePorts();
        entry.reservation = reservation;
        entry.serial = `emulator-${reservation.port}`;
        checkAbort(signal);
        await reservation.closeSockets();
        checkAbort(signal);
        const child = this.spawnProcess(
          this.executables.emulator,
          ['-avd', entry.id, '-no-window', '-port', String(reservation.port), '-gpu', 'host'],
          {
            env: this.environment,
            shell: false,
            windowsHide: true,
            stdio: ['ignore', 'pipe', 'pipe'],
          },
        );
        entry.child = child;
        for (const stream of [child.stdout, child.stderr])
          stream?.on('data', (data) => {
            entry.log = (entry.log + data.toString()).slice(-32768);
          });
        child.on('error', (error) => {
          entry.spawnError = error;
          entry.exited = true;
        });
        child.once('exit', (code, exitSignal) => {
          entry.exited = true;
          entry.exitCode = code;
          entry.exitSignal = exitSignal;
          void reservation.release();
          if (entry.state === 'running') {
            void this.detach(entry.id);
            this.publish(
              entry,
              'error',
              `The emulator exited (${code ?? exitSignal}). ${entry.log.trim().slice(-4096)}`,
            );
          }
        });
        await new Promise((resolve, reject) => {
          child.once('spawn', resolve);
          child.once('error', reject);
        });
        checkAbort(signal);
      });
      const deadline = Date.now() + this.timings.boot;
      while (Date.now() < deadline) {
        checkAbort(signal);
        this.requireAlive(entry);
        try {
          const result = await this.adb(entry, shellArguments(['getprop', 'sys.boot_completed']), {
            signal,
            timeout: Math.min(5000, Math.max(1, deadline - Date.now())),
          });
          checkAbort(signal);
          this.requireAlive(entry);
          if (result.code === 0 && result.stdout.trim() === '1') {
            // A serial alone is not an identity, even after a successful boot probe.
            await this.verifySerial(entry, signal);
            entry.booted = true;
            this.publish(entry, 'running');
            return;
          }
        } catch (error) {
          checkAbort(signal);
          this.requireAlive(entry);
          if (error.code === 'identity_mismatch') throw error;
          // ADB may be temporarily offline during boot; keep the bounded deadline.
        }
        await delay(this.timings.poll, signal);
      }
      throw new Error('Android did not finish booting within the startup deadline.');
    } catch (error) {
      if (signal.aborted) throw error; // Stop joins startup and owns its cleanup.
      let cleanupError;
      try {
        await this.terminate(entry);
        entry.child = null;
        entry.serial = null;
      } catch (failure) {
        cleanupError = failure;
      }
      this.publish(
        entry,
        'error',
        `${error.message}${cleanupError ? ` Cleanup: ${cleanupError.message}` : ''}`,
      );
      throw error;
    } finally {
      if (!entry.child) await entry.reservation?.release();
    }
  }
  requireAlive(entry) {
    if (this.entries.get(entry.id) !== entry || !alive(entry))
      throw new Error(
        entry.spawnError?.message ||
          `The owned emulator is no longer running. ${entry.log.trim().slice(-4096)}`,
      );
  }
  adb(entry, args, options = {}) {
    return this.run(this.executables.adb, ['-s', entry.serial, ...args], {
      env: this.environment,
      ...options,
    });
  }
  async verifySerial(entry, signal) {
    checkAbort(signal);
    this.requireAlive(entry);
    const devices = requireSuccess(
      await this.run(this.executables.adb, ['devices', '-l'], {
        env: this.environment,
        signal,
        timeout: 5000,
      }),
      'Inspect Android devices',
    );
    if (
      !parseADBDevices(devices.stdout).some(
        (device) => device.serial === entry.serial && device.state === 'device',
      )
    )
      throw new Error('The owned Android device is not connected to ADB.');
    const result = requireSuccess(
      await this.adb(entry, ['emu', 'avd', 'name'], { signal, timeout: 3000 }),
      'Verify phone identity',
    );
    const names = result.stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && line !== 'OK');
    if (names.length !== 1 || names[0] !== entry.id)
      throw Object.assign(
        new Error('ADB serial identity changed. The device was not controlled.'),
        { code: 'identity_mismatch' },
      );
    checkAbort(signal);
    this.requireAlive(entry);
  }
  attach(id) {
    const entry = this.owned(id);
    if (entry.attachTask) return entry.attachTask;
    const generation = (entry.displayGeneration ?? 0) + 1;
    entry.displayGeneration = generation;
    const task = (async () => {
      await this.closeBridge(entry);
      this.requireAlive(entry);
      checkAbort(entry.controller.signal);
      if (entry.displayGeneration !== generation)
        throw new DOMException('Display closed', 'AbortError');
      entry.displayController = new AbortController();
      const signal = AbortSignal.any([entry.controller.signal, entry.displayController.signal]);
      await this.verifySerial(entry, signal);
      checkAbort(signal);
      const bridge = this.bridgeFactory({
        adb: this.executables.adb,
        environment: this.environment,
        serial: entry.serial,
        serverPath: this.serverPath,
        run: this.run,
        spawnProcess: this.spawnProcess,
      });
      entry.bridge = bridge;
      bridge.on('video', (packet) => {
        if (entry.bridge === bridge && !entry.controller.signal.aborted)
          this.emit('video', { id, ...packet });
      });
      bridge.on('disconnect', (error) => {
        if (entry.bridge === bridge && entry.state === 'running')
          this.emit('error-message', {
            id,
            message: `Display disconnected: ${error.message}. Reopen the phone to reconnect.`,
          });
      });
      try {
        await bridge.start({ signal });
      } catch (error) {
        if (entry.bridge === bridge) entry.bridge = null;
        await bridge.stop();
        throw error;
      }
      this.requireAlive(entry);
      checkAbort(signal);
      return this.status(id);
    })();
    entry.attachTask = task;
    return task.finally(() => {
      if (entry.attachTask === task) entry.attachTask = null;
    });
  }
  async detach(id) {
    const entry = this.entries.get(id);
    if (!entry) return;
    entry.displayGeneration = (entry.displayGeneration ?? 0) + 1;
    await this.closeBridge(entry);
    await entry.attachTask?.catch(() => {});
    if (entry.rotation) {
      try {
        await entry.rotation.restore();
        entry.rotation = null;
      } catch (error) {
        this.emit('error-message', {
          id,
          message: `Android rotation settings could not be restored: ${error.message}`,
        });
      }
    }
  }
  async closeBridge(entry) {
    entry.displayController?.abort();
    entry.displayController = null;
    const bridge = entry.bridge;
    entry.bridge = null;
    await bridge?.stop();
  }
  input(id, action) {
    const entry = this.owned(id);
    if (!entry.bridge) throw new Error('Open the phone display before sending input.');
    entry.bridge.input(action);
  }
  async rotate(id, angle) {
    const entry = this.owned(id);
    entry.rotation ??= new GuestRotation(async (args) => {
      await this.verifySerial(entry);
      return requireSuccess(
        await this.adb(entry, shellArguments(args), { timeout: 5000 }),
        'Change Android rotation',
      ).stdout.trim();
    });
    await entry.rotation.rotate(angle);
  }
  owned(id) {
    const entry = this.entries.get(id);
    if (
      !entry ||
      entry.state !== 'running' ||
      !entry.booted ||
      !alive(entry) ||
      entry.controller.signal.aborted
    )
      throw new Error('This phone is not running in DroidDock.');
    return entry;
  }
  async installAPK(id, filename) {
    const entry = this.owned(id);
    if (
      typeof filename !== 'string' ||
      !path.isAbsolute(filename) ||
      path.extname(filename).toLowerCase() !== '.apk'
    )
      throw new Error('Choose an absolute APK file path.');
    const file = await canonical(filename),
      info = await stat(file);
    if (!info.isFile() || info.size === 0)
      throw new Error('The APK must be a nonempty regular file.');
    await this.verifySerial(entry, entry.controller.signal);
    const result = requireSuccess(
      await this.adb(entry, ['install', '-r', file], {
        signal: entry.controller.signal,
        timeout: 180_000,
      }),
      'Install APK',
    );
    if (!result.stdout.split(/\r?\n/).some((line) => line.trim() === 'Success'))
      throw new Error(`Android did not confirm APK installation. ${result.stdout.slice(-4096)}`);
    return { message: `Installed ${path.basename(file)}` };
  }
  async openURL(id, value) {
    const entry = this.owned(id);
    if (typeof value !== 'string' || value.length > 8192 || /[\x00-\x1f\x7f]/.test(value))
      throw new Error('Invalid Android app URL.');
    let url;
    try {
      url = new URL(value);
    } catch {
      throw new Error('Provide a URL with a valid scheme.');
    }
    if (['file:', 'content:', 'javascript:', 'data:', 'droiddock:'].includes(url.protocol))
      throw new Error('Unsupported Android app URL scheme.');
    await this.verifySerial(entry, entry.controller.signal);
    const result = requireSuccess(
      await this.adb(
        entry,
        shellArguments(['am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', value]),
        { signal: entry.controller.signal, timeout: 30_000 },
      ),
      'Open Android URL',
    );
    if (/Error:/i.test(result.stdout + result.stderr))
      throw new Error((result.stdout + result.stderr).slice(-4096));
    return { message: `Opened URL on ${id}` };
  }
  stop(id) {
    const entry = this.entries.get(id);
    if (!entry) return Promise.resolve(this.status(id));
    if (entry.stopTask) return entry.stopTask;
    this.publish(entry, 'stopping');
    entry.controller.abort();
    const task = (async () => {
      await entry.startTask?.catch(() => {});
      await this.detach(id);
      await entry.attachTask?.catch(() => {});
      try {
        await this.terminate(entry);
        entry.child = null;
        entry.serial = null;
        entry.booted = false;
        this.publish(entry, 'idle');
        return this.status(id);
      } catch (error) {
        this.publish(entry, 'error', error.message);
        throw error;
      }
    })();
    entry.stopTask = task;
    return task.finally(() => {
      if (entry.stopTask === task) entry.stopTask = null;
    });
  }
  async waitExit(entry, timeout) {
    const deadline = Date.now() + timeout;
    while (alive(entry) && Date.now() < deadline)
      await delay(Math.min(50, Math.max(1, deadline - Date.now())));
    return !alive(entry);
  }
  async terminate(entry) {
    if (!entry.child) return;
    if (alive(entry)) {
      let graceful = false;
      try {
        await this.verifySerial(entry); // Cleanup deliberately ignores the cancelled launch signal.
        // No await between the final owned-child check and starting this command.
        this.requireAlive(entry);
        requireSuccess(
          await this.adb(entry, ['emu', 'kill'], { timeout: 3000 }),
          'Shut down Android',
        );
        graceful = true;
      } catch {
        /* An unverified/offline serial never receives a kill command. */
      }
      if (graceful) await this.waitExit(entry, this.timings.graceful);
      if (alive(entry)) {
        this.requireAlive(entry);
        entry.child.kill('SIGTERM');
        await this.waitExit(entry, this.timings.terminate);
      }
      if (alive(entry)) {
        this.requireAlive(entry);
        entry.child.kill('SIGKILL');
        await this.waitExit(entry, this.timings.force);
      }
      if (alive(entry))
        throw new Error(
          'The owned emulator did not exit. Its session is retained; try Stop again.',
        );
    }
    // Windows launcher processes may supervise QEMU. Never claim success or
    // adopt/kill a different process if the original launcher has exited first.
    if (entry.serial && this.platform === 'win32') {
      // ADB may retain an offline transport briefly after QEMU exits. Wait for
      // it to disappear without sending any commands to an unowned serial.
      const deadline = Date.now() + this.timings.graceful;
      while (true) {
        const result = requireSuccess(
          await this.run(this.executables.adb, ['devices', '-l'], {
            env: this.environment,
            timeout: 5000,
          }),
          'Verify emulator shutdown',
        );
        if (!parseADBDevices(result.stdout).some((device) => device.serial === entry.serial)) break;
        if (Date.now() >= deadline)
          throw new Error(
            'The emulator launcher exited, but its ADB serial is still present. Stop that runtime with Android tooling; DroidDock will not take over an unowned process.',
          );
        await delay(Math.min(100, Math.max(1, deadline - Date.now())));
      }
    }
    await entry.reservation?.release();
  }
  async stopAll() {
    this.closed = true;
    const results = await Promise.allSettled([...this.entries.keys()].map((id) => this.stop(id)));
    const failures = results.filter((result) => result.status === 'rejected');
    if (failures.length) {
      this.closed = false; // The app may cancel Quit so the user can retry cleanup.
      throw new AggregateError(
        failures.map((result) => result.reason),
        'Some emulator sessions could not be stopped.',
      );
    }
  }
}
