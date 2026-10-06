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
let state,
  selected,
  noticePhoneID,
  dialogBusy = false,
  refreshing = false;
const errorMessage = (error) =>
  String(error.message ?? error).replace(/^Error invoking remote method '[^']+': Error: /, '');
function notice(value) {
  noticePhoneID = typeof value?.id === 'string' ? value.id : undefined;
  $('#notice span').textContent = errorMessage(value);
  $('#notice').hidden = false;
}
async function run(fn, phoneID) {
  try {
    return await fn();
  } catch (error) {
    const message = errorMessage(error);
    notice(phoneID ? { id: phoneID, message } : message);
  }
}
$('#notice button').onclick = () => {
  noticePhoneID = undefined;
  $('#notice').hidden = true;
};
function status(id) {
  return state?.statuses.find((s) => s.id === id) ?? { id, state: 'idle' };
}
function current() {
  return state?.phones.find((p) => p.id === selected);
}
function androidTitle(apiLevel) {
  const releases = {
    30: '11',
    31: '12',
    32: '12L',
    33: '13',
    34: '14',
    35: '15',
    36: '16',
    37: '17',
  };
  const release = releases[String(apiLevel).split('.')[0]];
  return release ? `Android ${release} · API ${apiLevel}` : `Android API ${apiLevel}`;
}
function closeMenu(restoreFocus = false) {
  $('#device-menu').hidden = true;
  $('#device-menu-trigger').setAttribute('aria-expanded', 'false');
  if (restoreFocus) $('#device-menu-trigger').focus();
}
function openMenu() {
  if (!current()) return;
  $('#device-menu').hidden = false;
  $('#device-menu-trigger').setAttribute('aria-expanded', 'true');
  $('#device-menu button:not(:disabled)')?.focus();
}
$('#device-menu-trigger').onclick = () => {
  if ($('#device-menu').hidden) openMenu();
  else closeMenu(true);
};
document.addEventListener('pointerdown', (event) => {
  if (!event.target.closest('.device-menu-anchor')) closeMenu();
});
document.addEventListener('keydown', (event) => {
  if ($('#device-menu').hidden) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    closeMenu(true);
  } else if (event.key === 'Tab') closeMenu();
  else if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
    event.preventDefault();
    const items = [...document.querySelectorAll('#device-menu button:not(:disabled)')];
    const currentIndex = items.indexOf(document.activeElement);
    const next =
      event.key === 'Home'
        ? 0
        : event.key === 'End'
          ? items.length - 1
          : (currentIndex + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    items[next]?.focus();
  }
});
function select(id) {
  closeMenu();
  selected = id;
  render();
}
function render() {
  if (!state) return;
  if (!state.phones.some((p) => p.id === selected)) {
    closeMenu();
    selected = state.phones[0]?.id;
  }
  const hostName = state.host === 'windows' ? 'Windows' : 'Linux';
  $('#host-label').textContent = hostName;
  $('#native-feature-title').textContent = `Made for ${hostName}`;
  $('#build-label').textContent = `v${state.version} · Development preview`;
  $('#runtime-label').textContent = state.phones.length
    ? 'Android by DroidDock'
    : 'Android setup required';
  $('#runtime-dot').classList.toggle('pending', !state.phones.length);
  $('#add-phone').hidden = !state.phones.length;
  $('#add-phone').disabled = !!state.installing;
  $('#versions-button').disabled = !!state.installing;
  $('#device-count').textContent =
    `${state.phones.length} ${state.phones.length === 1 ? 'device' : 'devices'} available`;
  $('#loading').hidden = true;
  $('#versions-button span').textContent = state.phones.length
    ? 'Android Versions…'
    : 'Set Up Android';
  $('#phone-list').replaceChildren(
    ...state.phones.map((p) => {
      const row = button(
        '',
        () => select(p.id),
        'phone-item' + (p.id === selected ? ' selected' : ''),
      );
      const symbol = create('span', '', 'phone-symbol');
      symbol.setAttribute('aria-hidden', 'true');
      row.append(symbol);
      row.setAttribute('aria-current', p.id === selected ? 'true' : 'false');
      const label = create('span', p.name, 'phone-item-label');
      label.append(create('small', androidTitle(p.api)));
      row.append(label);
      if (status(p.id).canStop || ['running', 'starting'].includes(status(p.id).state))
        row.append(create('span', '', 'dot'));
      row.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        select(p.id);
        openMenu();
      });
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
      openable = active && s.state !== 'stopping';
    $('#phone-name').textContent = p.name;
    $('#phone-version').replaceChildren(
      document.createTextNode('Your Android device.'),
      document.createElement('br'),
      document.createTextNode(`Right at home on ${hostName}.`),
    );
    $('#device-status').textContent =
      {
        idle: 'READY FOR DEVELOPMENT',
        starting: 'STARTING',
        running: 'RUNNING',
        stopping: 'STOPPING',
        error: active ? 'RUNNING · NEEDS ATTENTION' : 'NEEDS ATTENTION',
      }[s.state] ?? s.state.toUpperCase();
    $('#device-status').classList.toggle('attention', ['error', 'stopping'].includes(s.state));
    $('#start').hidden = active;
    $('#start').disabled = busy || state.installing;
    $('#open').hidden = !openable;
    $('#open').disabled = false;
    $('#stop').hidden = !active;
    $('#stop').disabled =
      (busy && !(state.startingPhones ?? []).includes(p.id)) || s.state === 'stopping';
    $('#stop span').textContent = s.state === 'stopping' ? 'Stopping…' : 'Stop Device';
    $('#edit').disabled = active || busy;
    $('#delete').disabled = active || busy;
    const hint =
      s.error ||
      (s.state === 'starting'
        ? 'Starting Android in its own device window…'
        : s.state === 'stopping'
          ? 'Stopping the phone…'
          : active
            ? 'Stop the phone before editing its configuration or deleting it.'
            : '');
    $('#device-hint').textContent = hint;
    $('#device-hint').hidden = !hint;
    $('#device-hint').classList.toggle('error-text', !!s.error);
    $('#spec-api').textContent = p.api;
    $('#spec-abi').textContent = p.abi;
    $('#spec-resolution').textContent = `${p.width} × ${p.height}`;
    $('#spec-memory').textContent = `${p.memory} MB`;
  }
  document.body.dataset.ready = 'true';
}
async function refresh() {
  if (refreshing) return;
  refreshing = true;
  try {
    state = await api.state();
    render();
  } catch (error) {
    if (!state) {
      $('#loading').replaceChildren(
        create('p', 'Devices could not be loaded. Use Refresh to try again.'),
      );
      $('#runtime-label').textContent = 'Android unavailable';
      $('#device-count').textContent = 'Library unavailable';
    }
    throw error;
  } finally {
    refreshing = false;
  }
}
function showDialog(title) {
  closeMenu();
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
        'After setup, open a new terminal. In an Expo project with dependencies installed, run droiddock expo PHONE_ID. It boots the phone and uses bundled Node with a compatible localhost connection. For other tools, use droiddock boot PHONE_ID. If ADB stops responding, run droiddock repair-adb.',
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
  const content = showDialog('Edit AVD Configuration');
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
for (const id of ['versions-button', 'add-phone', 'empty-setup'])
  $('#' + id).onclick = () => run(versions);
$('#terminal-button').onclick = () => run(terminal);
$('#refresh').onclick = () => run(refresh);
$('#help-button').onclick = () => run(() => api.help('acceleration'));
$('#updates-button').onclick = () => run(() => api.help('releases'));
$('#start').onclick = () => {
  const id = selected;
  return run(async () => {
    await api.start(id);
    await refresh();
  }, id);
};
$('#stop').onclick = () =>
  run(async () => {
    await api.stop(selected);
    await refresh();
  });
$('#open').onclick = () => {
  const id = selected;
  return run(() => api.openDevice(id), id);
};
$('#edit').onclick = () => {
  closeMenu();
  void run(edit);
};
$('#delete').onclick = () =>
  run(async () => {
    closeMenu();
    await api.delete(selected);
    await refresh();
  });
api.onState((next) => {
  state = next;
  render();
});
api.onError(notice);
api.onDisplayRecovered((id) => {
  if (noticePhoneID !== id) return;
  noticePhoneID = undefined;
  $('#notice').hidden = true;
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
