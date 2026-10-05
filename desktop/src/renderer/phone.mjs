import { PhoneVideo } from './video.mjs';
import { phoneGeometry, guestPoint, androidKeys } from './phone-input.mjs';

const api = window.droiddock;
const $ = (selector) => document.querySelector(selector);
const canvas = $('#screen');
const stage = $('#phone-stage');
const bezel = $('#phone-bezel');
const menu = $('#controls-menu');
const retiredStreams = new Set();
const pressedKeys = new Set();
const unsubscribers = [];
let phone,
  status = { state: 'loading' },
  pendingStart = false,
  removed = false;
let displayState = 'waiting',
  displayError,
  activeStream,
  readyStream,
  accepting = false;
let generation = 0,
  connectionWork = Promise.resolve(),
  attemptedSession,
  closed = false;
let frameSize = { width: 1080, height: 2400 },
  pointer,
  frameTimer,
  latestLibraryState;
let stopPending = false,
  startPending = false,
  apkPending = false;

const errorText = (error) =>
  String(error?.message ?? error).replace(/^Error invoking remote method '[^']+': Error: /, '');
const sessionKey = () => status.sessionID ?? 'current-session';
const streamKey = (value) =>
  typeof value === 'string' || Number.isSafeInteger(value) ? String(value) : null;
const canControl = () =>
  !closed && status.state === 'running' && displayState === 'connected' && accepting;
const activeRuntime = () =>
  status.canStop || ['starting', 'running', 'stopping'].includes(status.state);

function notice(text) {
  $('#notice-text').textContent = text;
  $('#notice').hidden = false;
}
async function run(action) {
  try {
    return await action();
  } catch (error) {
    if (!closed) notice(errorText(error));
  }
}
function retire(stream) {
  if (stream === undefined || stream === null) return;
  retiredStreams.add(streamKey(stream));
  if (retiredStreams.size > 64) retiredStreams.delete(retiredStreams.values().next().value);
}
function clearFrameTimer() {
  clearTimeout(frameTimer);
  frameTimer = undefined;
}
function resetVideo() {
  releaseInputs();
  accepting = false;
  retire(activeStream);
  activeStream = undefined;
  readyStream = undefined;
  clearFrameTimer();
  video.close();
}

const video = new PhoneVideo(canvas, {
  onFrame(width, height) {
    if (closed || !accepting || !activeStream || status.state !== 'running') return;
    const changed = frameSize.width !== width || frameSize.height !== height;
    if (changed) releaseInputs();
    frameSize = { width, height };
    displayState = 'connected';
    displayError = undefined;
    clearFrameTimer();
    layout();
    render();
    const stream = activeStream;
    const currentGeneration = generation;
    if (readyStream !== stream) {
      readyStream = stream;
      Promise.resolve(
        api.displayReady({ streamID: stream, sessionID: status.sessionID, width, height }),
      )
        .then((accepted) => {
          if (accepted === false)
            throw new Error(
              'This display connection changed before its first frame was accepted. Reconnect the display.',
            );
        })
        .catch((error) => {
          if (!closed && generation === currentGeneration && activeStream === stream)
            failDisplay(error);
        });
    }
    if (changed)
      Promise.resolve(api.displaySize({ width, height })).catch((error) => {
        if (!closed && generation === currentGeneration) notice(errorText(error));
      });
  },
  onError: (error) => failDisplay(error),
});

function layout() {
  const size = phoneGeometry({ width: stage.clientWidth, height: stage.clientHeight }, frameSize);
  bezel.style.width = `${size.width}px`;
  bezel.style.height = `${size.height}px`;
  bezel.style.setProperty('--bezel', `${size.bezel}px`);
  bezel.style.setProperty('--radius', `${size.radius}px`);
  bezel.style.setProperty('--screen-radius', `${size.screenRadius}px`);
}

function render() {
  if (closed) return;
  const running = status.state === 'running';
  const starting = status.state === 'starting' || pendingStart || (startPending && !running);
  const stopping = status.state === 'stopping';
  const error = displayError || status.error;
  const connected = running && displayState === 'connected' && !error;
  document.body.dataset.deviceState = starting ? 'starting' : status.state;
  document.body.dataset.displayState = displayState;
  if (phone) {
    $('#device-name').textContent = phone.name;
    document.title = `${phone.name} — DroidDock`;
  }
  $('#device-state').textContent = connected
    ? `Android · API ${phone?.api ?? ''}`
    : stopping
      ? 'Stopping Android…'
      : starting
        ? 'Starting Android…'
        : error
          ? 'Needs attention'
          : running
            ? 'Connecting display…'
            : status.state === 'loading'
              ? 'Preparing device…'
              : 'Device stopped';
  for (const button of document.querySelectorAll('[data-control="touch"]'))
    button.disabled = !canControl();
  for (const button of document.querySelectorAll('[data-control="adb"]'))
    button.disabled = !running || apkPending;
  $('#reconnect').disabled = !running || displayState === 'connecting';
  $('#stop').disabled = !activeRuntime() || stopping || stopPending;
  $('#state-overlay').hidden = connected;
  if (connected) return;

  const busy = starting || stopping || status.state === 'loading' || (running && !error);
  $('#overlay-spinner').hidden = !busy;
  $('#overlay-icon').hidden = busy;
  $('#overlay-icon use').setAttribute('href', error ? '#i-alert' : '#i-phone');
  $('#overlay-action').hidden = busy || removed;
  $('#overlay-action').disabled = startPending || stopPending;
  $('#overlay-library').hidden = busy;
  let title, detail, action;
  if (removed) {
    title = 'Phone no longer available';
    detail = 'Open the library to choose another device.';
  } else if (stopping) {
    title = 'Stopping Android…';
    detail = 'Your apps and data will be kept.';
  } else if (starting) {
    title = 'Starting Android…';
    detail = 'The first start can take a little longer.';
  } else if (error) {
    title = running ? 'Display needs reconnecting' : 'Device needs attention';
    detail = errorText(error);
    action = running ? 'Reconnect Display' : activeRuntime() ? 'Stop Device' : 'Start Device';
  } else if (running) {
    title = 'Connecting display…';
    detail = 'Waiting for the first Android video frame.';
  } else if (status.state === 'loading') {
    title = 'Preparing device…';
    detail = 'Connecting to DroidDock.';
  } else {
    title = 'Device stopped';
    detail = 'Your apps and data are saved. Start the phone when you’re ready.';
    action = 'Start Device';
  }
  $('#overlay-title').textContent = title;
  $('#overlay-detail').textContent = detail;
  if (action) $('#overlay-action').textContent = action;
}

function failDisplay(error, notifyMain = true) {
  if (closed) return;
  const failedStream = activeStream;
  ++generation;
  resetVideo();
  displayError = errorText(error);
  displayState = 'error';
  render();
  // Keep the phone window and runtime alive; the user can reconnect explicitly.
  if (phone && status.state === 'running') {
    const id = phone.id;
    const failedGeneration = generation;
    const report = notifyMain
      ? api.displayFailed({
          streamID: failedStream,
          sessionID: status.sessionID,
          message: displayError.slice(0, 4096),
        })
      : Promise.resolve();
    void report
      .catch(() => {})
      .then(() => {
        if (!closed && generation === failedGeneration) return api.detach(id);
      })
      .catch(() => {});
  }
}

function requestConnection() {
  if (closed || !phone || status.state !== 'running' || displayState === 'connecting') return;
  const reconnect = attemptedSession !== undefined || activeStream !== undefined;
  const currentGeneration = ++generation;
  const id = phone.id;
  attemptedSession = sessionKey();
  resetVideo();
  displayError = undefined;
  displayState = 'connecting';
  render();
  const previous = connectionWork;
  const current = () =>
    !closed && currentGeneration === generation && status.state === 'running' && phone?.id === id;
  connectionWork = (async () => {
    await previous.catch(() => {});
    if (!current()) return;
    // The first attach must preserve the main process's Start/first-frame waiter.
    // A deliberate retry replaces a previous stream before opening the next one.
    if (reconnect) await api.detach(id);
    if (!current()) return;
    accepting = true;
    frameTimer = setTimeout(() => {
      if (current() && displayState !== 'connected')
        failDisplay('No Android video frame arrived. Reconnect the display to try again.');
    }, 25000);
    const attached = await api.attach(id);
    if (!current()) return;
    if (attached?.sessionID && status.sessionID && attached.sessionID !== status.sessionID) return;
    // Metadata and even a decoded frame can precede this response. Never reset
    // a decoder merely because the matching attach promise finished later.
    if (!activeStream && attached?.streamID && !retiredStreams.has(streamKey(attached.streamID)))
      activeStream = attached.streamID;
  })().catch((error) => {
    if (current()) failDisplay(error);
  });
}

function applyDevice(nextPhone, nextStatus, context = {}) {
  if (closed || !nextPhone || (phone && phone.id !== nextPhone.id)) return;
  const oldSession = status.sessionID;
  const wasRunning = status.state === 'running';
  const changedSession = oldSession !== nextStatus?.sessionID;
  if (changedSession || (nextStatus?.state !== 'running' && wasRunning)) {
    ++generation;
    resetVideo();
    attemptedSession = undefined;
    displayState = 'waiting';
    displayError = undefined;
  }
  phone = nextPhone;
  status = nextStatus ?? { id: phone.id, state: 'idle' };
  pendingStart = Boolean(context.pendingStart);
  if (!wasRunning && status.state !== 'running') {
    frameSize = { width: phone.width || 1080, height: phone.height || 2400 };
  }
  if (context.error) displayError = errorText(context.error);
  removed = false;
  layout();
  render();
  document.body.dataset.ready = 'true';
  if (status.state === 'running' && attemptedSession !== sessionKey()) requestConnection();
}

function applyLibraryState(next) {
  latestLibraryState = next;
  if (!phone || closed || !Array.isArray(next?.phones)) return;
  const selected = next.phones.find((candidate) => candidate.id === phone.id);
  if (!selected) {
    ++generation;
    resetVideo();
    removed = true;
    status = { id: phone.id, state: 'idle' };
    displayState = 'waiting';
    render();
    return;
  }
  applyDevice(
    selected,
    next.statuses?.find((candidate) => candidate.id === phone.id) ?? {
      id: phone.id,
      state: 'idle',
    },
  );
}

function receiveVideo(packet) {
  try {
    if (closed || !accepting || packet.id !== phone?.id || status.state !== 'running') return;
    if (status.sessionID && packet.sessionID !== status.sessionID) return;
    const key = streamKey(packet.streamID);
    if (key === null || retiredStreams.has(key)) return;
    if (key !== streamKey(activeStream)) {
      // Only a new stream's metadata establishes its identity. Late packets from
      // an old attachment cannot replace the current decoder.
      if (packet.kind !== 'metadata') return;
      retire(activeStream);
      releaseInputs();
      video.close();
      activeStream = packet.streamID;
      readyStream = undefined;
      displayState = 'connecting';
      render();
    }
    video.handle(packet);
  } catch (error) {
    failDisplay(error);
  } finally {
    if (Number.isSafeInteger(packet.sequence)) api.videoAck(packet.sequence);
  }
}

function input(action) {
  if (canControl()) api.input(phone.id, action);
}
function tapKey(keycode) {
  input({ type: 'key', keycode, action: 0 });
  input({ type: 'key', keycode, action: 1 });
}
function releaseInputs() {
  if (pointer) {
    const captured = pointer;
    pointer = undefined;
    input({ type: 'touch', action: 3, ...captured.point });
    if (canvas.hasPointerCapture(captured.id)) canvas.releasePointerCapture(captured.id);
  }
  for (const keycode of pressedKeys) input({ type: 'key', keycode, action: 1 });
  pressedKeys.clear();
}
function point(event, clamp = false) {
  return guestPoint(
    { x: event.clientX, y: event.clientY },
    canvas.getBoundingClientRect(),
    frameSize,
    clamp,
  );
}
canvas.addEventListener('pointerdown', (event) => {
  if (!canControl() || event.button !== 0 || pointer) return;
  const position = point(event);
  if (!position) return;
  canvas.focus();
  canvas.setPointerCapture(event.pointerId);
  pointer = { id: event.pointerId, point: position };
  input({ type: 'touch', action: 0, ...position });
  event.preventDefault();
});
canvas.addEventListener('pointermove', (event) => {
  if (pointer?.id !== event.pointerId) return;
  const position = point(event, true);
  if (!position) return;
  pointer.point = position;
  input({ type: 'touch', action: 2, ...position });
});
canvas.addEventListener('pointerup', (event) => {
  if (pointer?.id !== event.pointerId) return;
  const position = point(event, true) ?? pointer.point;
  pointer = undefined;
  input({ type: 'touch', action: 1, ...position });
  if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId);
});
canvas.addEventListener('pointercancel', releaseInputs);
canvas.addEventListener('lostpointercapture', releaseInputs);
canvas.addEventListener(
  'wheel',
  (event) => {
    if (!canControl()) return;
    const position = point(event);
    if (!position) return;
    event.preventDefault();
    const scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? frameSize.height : 1;
    input({
      type: 'scroll',
      ...position,
      horizontal: (-event.deltaX * scale) / 100,
      vertical: (-event.deltaY * scale) / 100,
    });
  },
  { passive: false },
);
canvas.addEventListener('keydown', (event) => {
  if (!canControl() || event.ctrlKey || event.metaKey || event.altKey || event.isComposing) return;
  const keycode = androidKeys[event.key];
  if (keycode) {
    event.preventDefault();
    if (!pressedKeys.has(keycode)) {
      pressedKeys.add(keycode);
      input({ type: 'key', keycode, action: 0 });
    }
  } else if ([...event.key].length === 1) {
    event.preventDefault();
    input({ type: 'text', text: event.key });
  }
});
canvas.addEventListener('keyup', (event) => {
  const keycode = androidKeys[event.key];
  if (pressedKeys.delete(keycode)) {
    event.preventDefault();
    input({ type: 'key', keycode, action: 1 });
  }
});
canvas.addEventListener('compositionend', (event) => {
  if (event.data) input({ type: 'text', text: event.data });
});
canvas.addEventListener('blur', releaseInputs);
window.addEventListener('blur', releaseInputs);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) releaseInputs();
});

function bind(id, action) {
  $('#' + id).addEventListener('click', () => {
    if (menu.matches(':popover-open')) menu.hidePopover();
    void run(action);
  });
}
async function startDevice() {
  if (!phone || startPending || activeRuntime()) return;
  startPending = true;
  displayError = undefined;
  render();
  try {
    await api.start(phone.id);
  } catch (error) {
    if (!closed) {
      displayError = errorText(error);
      displayState = 'error';
    }
  } finally {
    startPending = false;
    render();
  }
}
async function stopDevice() {
  if (!phone || stopPending || !activeRuntime()) return;
  stopPending = true;
  render();
  try {
    await api.stop(phone.id);
  } finally {
    stopPending = false;
    render();
  }
}
bind('back', () => tapKey(4));
bind('home', () => tapKey(3));
bind('recents', () => tapKey(187));
bind('rotate', () => {
  releaseInputs();
  input({ type: 'rotate' });
});
for (const [name, keycode] of [
  ['power', 26],
  ['volume-up', 24],
  ['volume-down', 25],
]) {
  bind(name, () => tapKey(keycode));
  bind('menu-' + name, () => tapKey(keycode));
}
bind('reconnect', requestConnection);
bind('stop', stopDevice);
bind('install-apk', async () => {
  apkPending = true;
  render();
  try {
    const result = await api.installAPK(phone.id);
    if (result?.message) notice(result.message);
  } finally {
    apkPending = false;
    render();
  }
});
bind('overlay-action', () =>
  status.state === 'running' ? requestConnection() : activeRuntime() ? stopDevice() : startDevice(),
);
bind('library', () => api.windowAction('library'));
bind('overlay-library', () => api.windowAction('library'));
bind('minimize', () => api.windowAction('minimize'));
bind('maximize', () => api.windowAction('maximize'));
bind('close-window', () => {
  dispose();
  return api.windowAction('close');
});
bind('dismiss-notice', () => {
  $('#notice').hidden = true;
});

function dispose() {
  if (closed) return;
  ++generation;
  resetVideo();
  closed = true;
  resizeObserver.disconnect();
  for (const unsubscribe of unsubscribers) unsubscribe();
  if (phone) void api.detach(phone.id).catch(() => {});
}
const resizeObserver = new ResizeObserver(layout);
resizeObserver.observe(stage);
window.addEventListener('beforeunload', dispose);
unsubscribers.push(
  api.onState(applyLibraryState),
  api.onVideo(receiveVideo),
  api.onError((error) => {
    if (error?.id && error.id !== phone?.id) return;
    failDisplay(error, false);
  }),
);
layout();
render();
try {
  const context = await api.deviceState();
  if (!context?.phone)
    throw new Error('This device window no longer has a phone. Open the library to choose one.');
  if (context.streamID) retire(context.streamID);
  applyDevice(context.phone, context.status, context);
  if (latestLibraryState) applyLibraryState(latestLibraryState);
} catch (error) {
  status = { state: 'error' };
  removed = true;
  displayError = errorText(error);
  displayState = 'error';
  render();
  document.body.dataset.ready = 'true';
}
