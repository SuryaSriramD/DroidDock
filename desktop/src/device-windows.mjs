import { randomUUID } from 'node:crypto';
import { FrameRelay } from './core/frame-relay.mjs';

const failure = (value) => (value instanceof Error ? value : new Error(String(value)));

/** Owns display windows and readiness; Android lifetime belongs to RuntimeManager. */
export class DeviceWindows {
  constructor({
    createWindow,
    url,
    runtime,
    onError = () => {},
    onClosed = () => {},
    readyTimeout = 35_000,
    recoveryTimeout = 5000,
    now = () => performance.now(),
  }) {
    Object.assign(this, {
      createWindow,
      url,
      runtime,
      onError,
      onClosed,
      readyTimeout,
      recoveryTimeout,
      now,
    });
    this.entries = new Map();
    this.detaching = new Map();
  }

  current(entry) {
    return this.entries.get(entry.id) === entry && !entry.window.isDestroyed();
  }
  send(entry, channel, value) {
    if (this.current(entry) && !entry.window.webContents.isDestroyed?.())
      entry.window.webContents.send(channel, value);
  }
  result(entry) {
    return {
      id: entry.id,
      sessionID: entry.sessionID,
      streamID: entry.streamID,
      displayReady: entry.displayReady,
    };
  }
  open(phone) {
    const previous = this.entries.get(phone.id);
    if (previous && this.current(previous)) {
      previous.phone = phone;
      previous.window.setTitle(phone.name);
      if (previous.window.isMinimized()) previous.window.restore();
      previous.window.show();
      previous.window.focus();
      return previous;
    }
    const window = this.createWindow(phone);
    const entry = {
      id: phone.id,
      phone,
      window,
      relay: new FrameRelay(),
      streamID: null,
      sessionID: this.runtime.status(phone.id).sessionID ?? null,
      displayReady: false,
      error: null,
      generation: 0,
      waiters: new Set(),
      attachTask: null,
      attached: false,
    };
    this.entries.set(phone.id, entry);
    entry.watchdog = setInterval(() => this.checkDisplay(entry.id), 1000);
    entry.watchdog.unref?.();
    window.once('ready-to-show', () => {
      if (this.current(entry)) {
        window.show();
        window.focus();
      }
    });
    window.once('closed', () => {
      if (this.entries.get(entry.id) !== entry) return;
      clearInterval(entry.watchdog);
      // Invoke detach now and retain its barrier across a same-ID window reopen.
      this.invalidate(entry, new Error('The phone window was closed.'));
      this.beginDetach(entry);
      this.entries.delete(entry.id);
      this.onClosed(entry.id);
    });
    window.webContents.on('render-process-gone', () => {
      if (!this.current(entry)) return;
      this.invalidate(
        entry,
        new Error('The phone display stopped responding. Close and reopen its window.'),
      );
      this.beginDetach(entry);
      this.reportError(
        entry.id,
        'The phone display stopped responding. Close and reopen its window.',
      );
    });
    try {
      Promise.resolve(window.loadURL(this.url)).catch((error) => {
        if (this.current(entry)) this.reportError(entry.id, error);
      });
    } catch (error) {
      this.reportError(entry.id, error);
    }
    return entry;
  }

  settle(entry, error) {
    for (const waiter of entry.waiters) {
      clearTimeout(waiter.timer);
      error ? waiter.reject(error) : waiter.resolve(this.result(entry));
    }
    entry.waiters.clear();
  }
  invalidate(entry, error) {
    entry.generation++;
    entry.streamID = null;
    entry.displayReady = false;
    entry.attached = false;
    entry.relay.clear();
    entry.lastEncodedAt = null;
    entry.lastDecodedAt = null;
    entry.recoveryAt = null;
    entry.recoveryAttempts = 0;
    if (error) this.settle(entry, error);
  }
  beginDetach(entry) {
    // No deferred cleanup may look up a newly reopened window and detach its stream.
    const previous = this.detaching.get(entry.id);
    if (previous) return previous;
    let cleanup;
    try {
      cleanup = Promise.resolve(this.runtime.detach(entry.id));
    } catch (error) {
      cleanup = Promise.reject(error);
    }
    this.detaching.set(entry.id, cleanup);
    cleanup.then(
      () => {
        if (this.detaching.get(entry.id) === cleanup) this.detaching.delete(entry.id);
      },
      (error) => {
        if (this.detaching.get(entry.id) === cleanup) this.detaching.delete(entry.id);
        if (this.current(entry)) this.reportError(entry.id, error);
        else this.onError(entry.id, failure(error));
      },
    );
    return cleanup;
  }
  attach(id) {
    const entry = this.entries.get(id);
    if (!entry || !this.current(entry))
      return Promise.reject(new Error('Open the phone window first.'));
    const status = this.runtime.status(id);
    if (status.state !== 'running' || !status.sessionID)
      return Promise.reject(
        new Error('Wait for Android to finish starting before connecting its display.'),
      );
    if (
      entry.attachTask &&
      entry.attachGeneration === entry.generation &&
      entry.sessionID === status.sessionID
    )
      return entry.attachTask;
    if (entry.attached && entry.streamID && entry.sessionID === status.sessionID)
      return Promise.resolve(this.result(entry));
    this.invalidate(entry);
    entry.error = null;
    entry.sessionID = status.sessionID;
    const generation = entry.generation;
    const sessionID = entry.sessionID;
    const task = (async () => {
      try {
        await this.detaching.get(id);
        this.requireAttempt(entry, generation, sessionID);
        // Old cleanup is finished; attach may emit codec packets synchronously.
        entry.streamID = randomUUID();
        await this.runtime.attach(id);
        this.requireAttempt(entry, generation, sessionID);
        entry.attached = true;
        if (entry.displayReady) this.settle(entry);
        return this.result(entry);
      } catch (error) {
        if (this.current(entry) && entry.generation === generation) this.reportError(id, error);
        throw error;
      }
    })();
    entry.attachTask = task;
    entry.attachGeneration = generation;
    const clear = () => {
      if (entry.attachTask === task) entry.attachTask = null;
    };
    task.then(clear, clear);
    return task;
  }
  requireAttempt(entry, generation, sessionID) {
    if (
      !this.current(entry) ||
      entry.generation !== generation ||
      this.runtime.status(entry.id).sessionID !== sessionID ||
      this.runtime.status(entry.id).state !== 'running'
    )
      throw new Error('The phone display or Android session changed. Reopen its display.');
  }
  video(packet) {
    const entry = this.entries.get(packet.id),
      status = this.runtime.status(packet.id);
    if (
      !entry ||
      !this.current(entry) ||
      !entry.streamID ||
      entry.sessionID !== status.sessionID ||
      status.state !== 'running'
    )
      return;
    try {
      if (packet.kind === 'frame') entry.lastEncodedAt = this.now();
      const payload = entry.relay.packet(packet);
      if (payload)
        this.send(entry, 'dock:video', {
          ...payload,
          streamID: entry.streamID,
          sessionID: entry.sessionID,
        });
    } catch (error) {
      this.reportError(entry.id, error);
      void this.detach(entry.id).catch(() => {});
    }
  }
  acknowledge(id, sequence) {
    const entry = this.entries.get(id);
    if (entry && this.current(entry)) {
      entry.relay.acknowledge(sequence);
      if (entry.relay.desynced.has(id) && entry.relay.pending.size < entry.relay.limit)
        this.recoverVideo(id);
    }
  }
  recoverVideo(id, streamID) {
    const entry = this.entries.get(id);
    if (
      !entry ||
      !this.current(entry) ||
      !entry.streamID ||
      entry.error ||
      (streamID && streamID !== entry.streamID) ||
      this.runtime.status(id).state !== 'running'
    )
      return;
    if (entry.recoveryAt !== null && this.now() - entry.recoveryAt < this.recoveryTimeout) return;
    if (entry.recoveryAttempts >= 2) {
      this.reportError(
        id,
        'The display stopped producing decoded frames. Reconnect Display to retry.',
      );
      void this.detach(id).catch(() => {});
      return;
    }
    entry.recoveryAt = this.now();
    entry.recoveryAttempts++;
    entry.displayReady = false;
    entry.relay.desynced.add(id);
    this.send(entry, 'dock:display-recovering', { streamID: entry.streamID });
    try {
      this.runtime.input(id, { type: 'resetVideo' });
    } catch (error) {
      this.reportError(id, error);
    }
  }
  checkDisplay(id) {
    const entry = this.entries.get(id);
    if (!entry || !this.current(entry) || !entry.streamID || entry.error) return;
    const pendingFrame =
      entry.lastEncodedAt !== null &&
      (entry.lastDecodedAt === null || entry.lastEncodedAt > entry.lastDecodedAt);
    // Quiet Android screens are healthy. Only unpresented packets or an active
    // recovery have a deadline; do not confuse silence with a frozen display.
    const since = entry.recoveryAt ?? entry.lastDecodedAt ?? entry.lastEncodedAt;
    if ((pendingFrame || entry.recoveryAt !== null) && this.now() - since >= this.recoveryTimeout)
      this.recoverVideo(id);
  }
  frameReady(id, { streamID, sessionID, width, height } = {}) {
    const entry = this.entries.get(id),
      status = this.runtime.status(id);
    if (
      !entry ||
      !this.current(entry) ||
      !entry.streamID ||
      streamID !== entry.streamID ||
      (sessionID !== undefined && sessionID !== entry.sessionID) ||
      entry.sessionID !== status.sessionID ||
      status.state !== 'running' ||
      !Number.isInteger(width) ||
      !Number.isInteger(height) ||
      width < 1 ||
      height < 1 ||
      width > 8192 ||
      height > 8192
    )
      return false;
    entry.lastDecodedAt = this.now();
    // Decoder callbacks already queued before backpressure may still arrive.
    // They cannot establish readiness until a replacement keyframe is relayed.
    if (entry.relay.desynced.has(id)) return true;
    entry.displayReady = true;
    entry.recoveryAt = null;
    entry.recoveryAttempts = 0;
    entry.error = null;
    entry.width = width;
    entry.height = height;
    if (entry.attached) this.settle(entry);
    return true;
  }
  waitForDisplay(id, sessionID) {
    const entry = this.entries.get(id),
      status = this.runtime.status(id);
    if (!entry || !this.current(entry))
      return Promise.reject(new Error('The phone window was closed.'));
    if (!sessionID || status.sessionID !== sessionID || entry.sessionID !== sessionID)
      return Promise.reject(new Error('The Android session changed while opening its display.'));
    if (['idle', 'error', 'stopping'].includes(status.state))
      return Promise.reject(
        new Error(status.error || 'Android stopped before its display was ready.'),
      );
    if (entry.error) return Promise.reject(new Error(entry.error));
    if (entry.displayReady && entry.attached) return Promise.resolve(this.result(entry));
    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject, timer: null };
      waiter.timer = setTimeout(() => {
        if (entry.waiters.has(waiter))
          this.reportError(
            id,
            'The phone display produced no decoded frame. Retry its display connection.',
          );
      }, this.readyTimeout);
      entry.waiters.add(waiter);
    });
  }
  statusChanged(status) {
    const entry = this.entries.get(status.id);
    if (!entry || !this.current(entry)) return;
    if (entry.sessionID !== (status.sessionID ?? null)) {
      this.invalidate(entry, new Error('The Android session changed while opening its display.'));
      entry.sessionID = status.sessionID ?? null;
      entry.error = null;
    }
    if (['idle', 'error', 'stopping'].includes(status.state)) {
      const error = new Error(status.error || 'Android stopped before its display was ready.');
      this.invalidate(entry, error);
      if (status.state === 'error') this.reportError(entry.id, error);
    }
  }
  reportError(id, error) {
    const entry = this.entries.get(id);
    if (!entry || !this.current(entry)) return;
    const reason = failure(error);
    entry.error = reason.message;
    entry.displayReady = false;
    this.settle(entry, reason);
    this.send(entry, 'dock:error', reason.message);
    this.onError(id, reason);
  }
  async detach(id) {
    const entry = this.entries.get(id);
    if (!entry || !this.current(entry)) return;
    this.invalidate(entry, new Error('The phone display was disconnected.'));
    await this.beginDetach(entry);
  }
  close(id) {
    this.entries.get(id)?.window.close();
  }
}
