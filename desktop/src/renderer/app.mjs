import { PhoneVideo } from './video.mjs';
const api = window.droiddock;
const $ = (selector) => document.querySelector(selector);
const create = (tag, text, cls) => {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = text;
  if (cls) element.className = cls;
  return element;
};
const button = (label, fn, cls) => {
  const el = create('button', label, cls);
  el.addEventListener('click', () => run(fn));
  return el;
};
let displayGeneration = 0,
  displayAttaching = false;
let state,
  selected,
  displayID,
  dialogBusy = false,
  refreshing = false,
  frameSize = { width: 1080, height: 2400 },
  pointer,
  pressedKeys = new Set();
const canvas = $('#screen');
const video = new PhoneVideo(canvas, {
  onFrame: (width, height) => {
    if (frameSize.width !== width || frameSize.height !== height) releaseInputs();
    frameSize = { width, height };
    $('#stream-state').textContent = 'Connected';
  },
  onError: (text) => {
    $('#stream-state').textContent = 'Display needs reconnecting';
    notice(`Display: ${text} Close and reopen the display to reconnect.`);
  },
});
const errorMessage = (error) =>
  String(error.message ?? error).replace(/^Error invoking remote method '[^']+': Error: /, '');
function notice(text) {
  $('#notice span').textContent = text;
  $('#notice').hidden = false;
}
async function run(fn) {
  try {
    return await fn();
  } catch (error) {
    notice(errorMessage(error));
  }
}
$('#notice button').onclick = () => ($('#notice').hidden = true);
function status(id) {
  return state?.statuses.find((s) => s.id === id) ?? { id, state: 'idle' };
}
function current() {
  return state?.phones.find((p) => p.id === selected);
}
function select(id) {
  if (displayID && displayID !== id) void closeDisplay();
  selected = id;
  render();
}
function render() {
  if (!state) return;
  if (!state.phones.some((p) => p.id === selected)) selected = state.phones[0]?.id;
  $('#host-label').textContent = state.host === 'windows' ? 'WINDOWS' : 'LINUX';
  $('#build-label').textContent = `v${state.version} · Development preview`;
  $('#versions-button span').textContent = state.phones.length
    ? 'Android Versions'
    : 'Set Up Android';
  $('#phone-list').replaceChildren(
    ...state.phones.map((p) => {
      const row = button(
        '',
        () => select(p.id),
        'phone-item' + (p.id === selected ? ' selected' : ''),
      );
      row.append(create('span', '▯'));
      const label = create('span', p.name);
      label.append(create('small', `API ${p.api} · ${p.abi}`));
      row.append(label);
      if (['running', 'starting'].includes(status(p.id).state))
        row.append(create('span', '', 'dot'));
      return row;
    }),
  );
  const p = current();
  $('#empty').hidden = !!p;
  $('#phone-card').hidden = !p;
  if (p) {
    const s = status(p.id),
      active = s.canStop || ['starting', 'running', 'stopping'].includes(s.state),
      busy = state.busyPhones.includes(p.id),
      running = s.state === 'running';
    $('#phone-name').textContent = p.name;
    $('#phone-version').textContent = `Android API ${p.api} · Google APIs`;
    $('#device-status').textContent =
      {
        idle: 'READY TO START',
        starting: 'STARTING ANDROID…',
        running: 'ANDROID IS RUNNING',
        stopping: 'STOPPING ANDROID…',
        error: 'NEEDS ATTENTION',
      }[s.state] ?? s.state.toUpperCase();
    $('#start').hidden = active;
    $('#start').disabled = busy || state.installing;
    $('#open').hidden = !running;
    $('#open').disabled = busy;
    $('#stop').hidden = !active;
    $('#stop').disabled = (busy && s.state !== 'starting') || s.state === 'stopping';
    $('#edit').disabled = active || busy;
    $('#delete').disabled = active || busy;
    $('#device-hint').textContent =
      s.error ??
      (active
        ? 'Stop the phone before editing its configuration or deleting it.'
        : 'Your apps and data are saved between sessions.');
    $('#spec-api').textContent = p.api;
    $('#spec-abi').textContent = p.abi;
    $('#spec-resolution').textContent = `${p.width} × ${p.height}`;
    $('#spec-memory').textContent = `${p.memory} MB`;
  }
  if (displayID && !['running', 'starting'].includes(status(displayID).state)) void closeDisplay();
  document.body.dataset.ready = 'true';
}
async function refresh() {
  if (refreshing) return;
  refreshing = true;
  try {
    state = await api.state();
    render();
  } finally {
    refreshing = false;
  }
}
function showDialog(title) {
  const content = create('section');
  $('#dialog-content').replaceChildren(content);
  const header = create('div', undefined, 'dialog-header');
  header.append(
    create('h2', title),
    button('×', () => {
      if (!dialogBusy) $('#dialog').close();
    }),
  );
  content.append(header);
  if (!$('#dialog').open) $('#dialog').showModal();
  return content;
}
$('#dialog').addEventListener('cancel', (event) => {
  if (dialogBusy) event.preventDefault();
});
async function versions() {
  const content = showDialog('Android Versions');
  content.append(
    create(
      'p',
      'Download an Android version to create its own phone. Existing phones and their data stay as they are.',
    ),
  );
  const list = create('div', undefined, 'version-list');
  list.append(create('div', 'Checking Google’s Android catalog…', 'loading'));
  content.append(list);
  try {
    const versions = await api.catalog();
    list.replaceChildren();
    if (!versions.length) {
      list.append(
        create('p', 'No compatible stable x86_64 images are available. Try again later.'),
      );
      return;
    }
    for (const version of versions) {
      const row = create('div', undefined, 'version-row'),
        label = create('div');
      label.append(
        create('strong', version.title ?? `Android API ${version.api}`),
        create('small', `API ${version.api} · x86_64 · Google APIs`),
      );
      const installed = state.phones.find((p) => p.imageId === version.id);
      row.append(
        label,
        installed
          ? button('In Library', () => {
              $('#dialog').close();
              select(installed.id);
            })
          : button('Download…', () => review(version), 'primary'),
      );
      list.append(row);
    }
  } catch (error) {
    list.replaceChildren(
      create('p', errorMessage(error), 'error-text'),
      button('Try Again', versions),
    );
  }
}
const bytes = (value) => `${(Number(value) / 1024 ** 3).toFixed(1)} GB`;
async function review(version) {
  const content = showDialog('Preparing download');
  content.append(create('p', 'Checking installed components and available disk space…'));
  try {
    const plan = await api.review(version.id);
    content.replaceChildren(create('h2', plan.title ?? version.title));
    content.append(
      create(
        'p',
        `${bytes(plan.downloadBytes)} to download · ${bytes(plan.requiredBytes)} free space needed. Components come directly from Google.`,
      ),
    );
    const checks = [];
    for (const license of plan.licenses) {
      const section = create('div', undefined, 'license'),
        label = create('label'),
        check = create('input');
      check.type = 'checkbox';
      label.append(check, create('span', `I accept ${license.id}`));
      section.append(create('pre', license.text), label);
      content.append(section);
      checks.push({ id: license.id, check });
    }
    const actions = create('div', undefined, 'dialog-actions');
    const go = button(
      plan.downloadBytes ? 'Agree & Download' : 'Create Phone',
      async () => {
        dialogBusy = true;
        const body = showDialog('Setting Up Android');
        const label = create('p', 'Preparing…');
        label.id = 'download-message';
        const progress = create('progress', undefined, 'progress');
        progress.id = 'download-progress';
        body.append(label, progress, create('p', 'You can cancel and try again later.', 'small'));
        const cancel = button('Cancel Download', () => {
          cancel.disabled = true;
          return api.cancelDownload();
        });
        body.append(cancel);
        try {
          const phone = await api.download(
            plan.token,
            checks.filter((c) => c.check.checked).map((c) => c.id),
          );
          selected = phone?.id;
          $('#dialog').close();
          notice('Your phone is ready. Start it from the library.');
          await refresh();
        } catch (error) {
          body.replaceChildren(
            create('h2', 'Setup paused'),
            create('p', errorMessage(error), 'error-text'),
            button('Back to Versions', versions),
          );
        } finally {
          dialogBusy = false;
        }
      },
      'primary',
    );
    const update = () => (go.disabled = checks.some((c) => !c.check.checked));
    checks.forEach(({ check }) => check.addEventListener('change', update));
    update();
    actions.append(button('Back', versions), go);
    content.append(actions);
  } catch (error) {
    content.replaceChildren(
      create('h2', 'Unable to prepare download'),
      create('p', errorMessage(error), 'error-text'),
      button('Back', versions),
    );
  }
}
async function terminal() {
  const content = showDialog('Set Up Terminal');
  content.append(
    create(
      'p',
      'Make DroidDock, adb, and emulator available to your development tools. You can choose Later and return here any time.',
    ),
  );
  const details = create('div');
  details.append(create('p', 'Reading your terminal configuration…'));
  content.append(details);
  try {
    const preview = await api.terminalPreview();
    details.replaceChildren(create('p', preview.summary));
    const paths = create('ul', undefined, 'path-list');
    for (const item of preview.paths) paths.append(create('li', item));
    details.append(paths);
    const files = create('p', `Settings to update: ${preview.files.join(', ')}`, 'small');
    details.append(files);
    if (!state.packaged)
      details.append(
        create(
          'p',
          'Install a packaged DroidDock app to enable terminal setup. Source builds leave your terminal configuration unchanged.',
          'small',
        ),
      );
    const actions = create('div', undefined, 'dialog-actions'),
      later = button('Later', async () => {
        await api.terminalLater();
        $('#dialog').close();
      });
    later.id = 'terminal-later';
    const setup = button(
      'Set Up Terminal',
      async () => {
        setup.disabled = true;
        try {
          const result = await api.terminalInstall();
          $('#dialog').close();
          notice(
            result.message ?? 'Terminal setup complete. Open a new terminal to use the commands.',
          );
        } catch (error) {
          setup.disabled = false;
          throw error;
        }
      },
      'primary',
    );
    setup.disabled = !state.packaged;
    actions.append(later, setup);
    content.append(actions);
    content.append(
      create(
        'p',
        'After setup, open a new terminal. Boot a phone with droiddock boot PHONE_ID, then run npx expo start and press A (or Shift+A to choose a device).',
        'small',
      ),
    );
  } catch (error) {
    details.replaceChildren(create('p', errorMessage(error), 'error-text'));
    const later = button('Later', () => $('#dialog').close());
    later.id = 'terminal-later';
    content.append(later);
  }
}
function edit() {
  const p = current();
  if (!p) return;
  const content = showDialog('Edit Phone');
  content.append(
    create(
      'p',
      'Changes apply the next time Android starts. Your installed apps and data are kept.',
    ),
  );
  const form = create('form'),
    grid = create('div', undefined, 'edit-grid'),
    fields = {};
  for (const [key, label, min, max] of [
    ['name', 'Phone name'],
    ['memory', 'Memory (MB)', 1536, 16384],
    ['cores', 'CPU cores', 1, 16],
    ['width', 'Width (pixels)', 320, 4096],
    ['height', 'Height (pixels)', 320, 4096],
    ['density', 'Display density', 120, 640],
  ]) {
    const wrapper = create('label', label, key === 'name' ? 'wide' : undefined),
      input = create('input');
    input.type = key === 'name' ? 'text' : 'number';
    input.value = p[key];
    input.required = true;
    if (key === 'name') input.maxLength = 120;
    else {
      input.min = min;
      input.max = max;
      input.step = ['width', 'height'].includes(key) ? 2 : 1;
    }
    wrapper.append(input);
    grid.append(wrapper);
    fields[key] = input;
  }
  const actions = create('div', undefined, 'dialog-actions'),
    cancel = button('Cancel', () => $('#dialog').close()),
    save = create('button', 'Save Changes', 'primary');
  cancel.type = 'button';
  save.type = 'submit';
  actions.append(cancel, save);
  form.append(grid, actions);
  content.append(form);
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    void run(async () => {
      save.disabled = true;
      try {
        const changes = Object.fromEntries(
          Object.entries(fields).map(([key, input]) => [
            key,
            key === 'name' ? input.value.trim() : Number(input.value),
          ]),
        );
        await api.edit(p.id, changes);
        $('#dialog').close();
        await refresh();
      } finally {
        save.disabled = false;
      }
    });
  });
}
async function openDisplay() {
  const id = selected;
  if (!id || (displayID === id && displayAttaching)) return;
  const generation = ++displayGeneration,
    previous = displayID;
  displayAttaching = true;
  releaseInputs();
  video.close();
  displayID = id;
  $('#display-panel').hidden = false;
  $('#display-title').textContent = current().name;
  $('#stream-state').textContent = 'Connecting display…';
  $('#display-panel').scrollIntoView({ behavior: 'smooth', block: 'start' });
  try {
    if (previous && previous !== id) await api.detach(previous);
    if (generation !== displayGeneration) return;
    await api.attach(id);
  } catch (error) {
    if (generation === displayGeneration) {
      await closeDisplay();
      throw error;
    }
  } finally {
    if (generation === displayGeneration) displayAttaching = false;
  }
}
async function closeDisplay() {
  const id = displayID;
  ++displayGeneration;
  displayAttaching = false;
  releaseInputs();
  displayID = null;
  video.close();
  $('#display-panel').hidden = true;
  if (id) await run(() => api.detach(id));
}
function input(action) {
  if (displayID) api.input(displayID, action);
}
function tapKey(keycode) {
  input({ type: 'key', keycode, action: 0 });
  input({ type: 'key', keycode, action: 1 });
}
function point(event, clamp = false) {
  const rect = canvas.getBoundingClientRect();
  const scale = Math.min(rect.width / frameSize.width, rect.height / frameSize.height),
    w = frameSize.width * scale,
    h = frameSize.height * scale,
    left = rect.left + (rect.width - w) / 2,
    top = rect.top + (rect.height - h) / 2;
  let x = (event.clientX - left) / scale,
    y = (event.clientY - top) / scale;
  if (!clamp && (x < 0 || y < 0 || x >= frameSize.width || y >= frameSize.height)) return null;
  return {
    x: Math.max(0, Math.min(frameSize.width - 1, Math.floor(x))),
    y: Math.max(0, Math.min(frameSize.height - 1, Math.floor(y))),
    ...frameSize,
  };
}
function releaseInputs() {
  if (pointer) {
    input({ type: 'touch', action: 3, ...pointer.point });
    pointer = null;
  }
  for (const keycode of pressedKeys) input({ type: 'key', keycode, action: 1 });
  pressedKeys.clear();
}
canvas.addEventListener('pointerdown', (event) => {
  if (event.button !== 0 || pointer) return;
  const p = point(event);
  if (!p) return;
  canvas.focus();
  canvas.setPointerCapture(event.pointerId);
  pointer = { id: event.pointerId, point: p };
  input({ type: 'touch', action: 0, ...p });
  event.preventDefault();
});
canvas.addEventListener('pointermove', (event) => {
  if (pointer?.id !== event.pointerId) return;
  const p = point(event, true);
  pointer.point = p;
  input({ type: 'touch', action: 2, ...p });
});
canvas.addEventListener('pointerup', (event) => {
  if (pointer?.id !== event.pointerId) return;
  input({ type: 'touch', action: 1, ...point(event, true) });
  pointer = null;
});
canvas.addEventListener('pointercancel', releaseInputs);
canvas.addEventListener('lostpointercapture', releaseInputs);
canvas.addEventListener(
  'wheel',
  (event) => {
    const p = point(event);
    if (p) {
      event.preventDefault();
      input({
        type: 'scroll',
        ...p,
        horizontal: -event.deltaX / 100,
        vertical: -event.deltaY / 100,
      });
    }
  },
  { passive: false },
);
const keycodes = {
  Enter: 66,
  Backspace: 67,
  Tab: 61,
  Escape: 4,
  ArrowUp: 19,
  ArrowDown: 20,
  ArrowLeft: 21,
  ArrowRight: 22,
  Delete: 112,
  Home: 3,
  PageUp: 92,
  PageDown: 93,
};
canvas.addEventListener('keydown', (event) => {
  if (event.ctrlKey || event.metaKey || event.altKey) return;
  const keycode = keycodes[event.key];
  if (keycode) {
    event.preventDefault();
    if (!pressedKeys.has(keycode)) {
      pressedKeys.add(keycode);
      input({ type: 'key', keycode, action: 0 });
    }
  } else if (event.key.length === 1) {
    event.preventDefault();
    input({ type: 'text', text: event.key });
  }
});
canvas.addEventListener('keyup', (event) => {
  const keycode = keycodes[event.key];
  if (pressedKeys.delete(keycode)) {
    event.preventDefault();
    input({ type: 'key', keycode, action: 1 });
  }
});
canvas.addEventListener('blur', releaseInputs);
window.addEventListener('blur', releaseInputs);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) releaseInputs();
});
for (const id of ['versions-button', 'add-phone', 'empty-setup'])
  $('#' + id).onclick = () => run(versions);
$('#terminal-button').onclick = () => run(terminal);
$('#refresh').onclick = () => run(refresh);
$('#help-button').onclick = () => run(() => api.help('acceleration'));
$('#updates-button').onclick = () => run(() => api.help('releases'));
$('#start').onclick = () =>
  run(async () => {
    const id = selected;
    await api.start(id);
    await refresh();
    if (selected === id) await openDisplay();
  });
$('#stop').onclick = () =>
  run(async () => {
    await api.stop(selected);
    await refresh();
  });
$('#open').onclick = () => run(openDisplay);
$('#edit').onclick = () => run(edit);
$('#delete').onclick = () =>
  run(async () => {
    await api.delete(selected);
    await refresh();
  });
$('#close-display').onclick = () => run(closeDisplay);
$('#back').onclick = () => tapKey(4);
$('#home').onclick = () => tapKey(3);
$('#overview').onclick = () => tapKey(187);
$('#rotate').onclick = () => {
  releaseInputs();
  input({ type: 'rotate' });
};
$('#apk').onclick = () =>
  run(async () => {
    const result = await api.installAPK(displayID);
    if (result?.message) notice(result.message);
  });
api.onState((next) => {
  state = next;
  render();
});
api.onError(notice);
api.onShowPhone(
  (id) =>
    void run(async () => {
      await refresh();
      select(id);
      await openDisplay();
    }),
);
api.onVideo((packet) => {
  try {
    if (packet.id === displayID) video.handle(packet);
  } finally {
    api.videoAck(packet.sequence);
  }
});
api.onProgress((progress) => {
  const label = $('#download-message'),
    bar = $('#download-progress');
  if (label) label.textContent = progress.message;
  if (bar) {
    if (progress.total > 0) {
      bar.max = progress.total;
      bar.value = progress.completed ?? 0;
    } else bar.removeAttribute('value');
  }
});
await run(async () => {
  await refresh();
  if (state.terminalPrompt && state.packaged) await terminal();
});
setInterval(() => void run(refresh), 5000);
