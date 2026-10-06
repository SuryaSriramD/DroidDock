import { app, BrowserWindow, dialog, ipcMain, shell, screen, nativeTheme } from 'electron';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import { mkdir, readFile, writeFile, rename, mkdtemp, realpath } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { parseExpoArgs, expoProject, runExpo } from './core/expo.mjs';
import { repairAdb } from './core/adb-recovery.mjs';
import { hostInfo, pathsFor, sdkEnvironment, sdkExecutables } from './core/platform.mjs';
import { terminalPreview, installTerminal } from './core/terminal.mjs';
import { fetchCatalog } from './core/catalog.mjs';
import { reviewInstall, installVersion } from './core/installer.mjs';
import { listPhones, updatePhone, deletePhone } from './core/phones.mjs';
import { RuntimeManager } from './core/runtime.mjs';
import { DeviceWindows } from './device-windows.mjs';
import { deviceWindowBounds } from './window-geometry.mjs';
import { HELP, parseCommand, sendCommand, startCommandServer } from './core/commands.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const rendererURL = pathToFileURL(path.join(here, 'renderer/index.html')).href;
const phoneURL = pathToFileURL(path.join(here, 'renderer/phone.html')).href;
const smoke = !app.isPackaged && process.argv.includes('--smoke');
const cliIndex = process.argv.indexOf('--cli');
// Electron CLI processes must never share the GUI's Chromium cache, including
// while waiting for boot or running Expo. Configure before the first await.
let cliProfile;
if (cliIndex !== -1) {
  cliProfile = mkdtempSync(path.join(os.tmpdir(), 'droiddock-cli-'));
  app.setPath('userData', cliProfile);
  app.setPath('sessionData', cliProfile);
  app.disableHardwareAcceleration();
  app.commandLine.appendSwitch('disable-gpu-shader-disk-cache');
  process.on('exit', () => {
    try {
      rmSync(cliProfile, { recursive: true, force: true });
    } catch {}
  });
}
let win,
  runtime,
  devices,
  paths,
  host,
  closeCommands,
  quitting = false,
  quitInProgress = false;
let reviewGeneration = 0;
let catalog = [],
  plan,
  installation,
  installationWork,
  preferences = {};
const busyPhones = new Set();
const startingPhones = new Set();
let smokeHome;
let adbRepair;

function message(error) {
  return error instanceof Error ? error.message : String(error);
}
function phoneID(id) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,120}$/.test(id))
    throw new Error('Invalid phone ID.');
  return id;
}
function windowContext(event) {
  if (
    win &&
    !win.isDestroyed() &&
    event.sender === win.webContents &&
    event.senderFrame === win.webContents.mainFrame &&
    event.senderFrame.url === rendererURL
  )
    return { kind: 'library', window: win };
  for (const entry of devices?.entries.values() ?? []) {
    if (
      !entry.window.isDestroyed() &&
      event.sender === entry.window.webContents &&
      event.senderFrame === entry.window.webContents.mainFrame &&
      event.senderFrame.url === phoneURL
    )
      return { kind: 'device', id: entry.id, entry, window: entry.window };
  }
  return null;
}
function scopedPhone(context, id) {
  phoneID(id);
  if (context.kind === 'device' && context.id !== id)
    throw new Error('This window belongs to a different phone.');
  return id;
}
function send(channel, value) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, value);
}
async function preferenceWrite() {
  const destination = path.join(paths.root, 'desktop-preferences.json');
  await writeFile(`${destination}.tmp`, JSON.stringify(preferences), { mode: 0o600 });
  await rename(`${destination}.tmp`, destination);
}
async function state() {
  return {
    version: app.getVersion(),
    host: host.os,
    packaged: app.isPackaged,
    paths: { sdk: paths.sdk, avd: paths.avd },
    phones: await listPhones(paths),
    statuses: runtime.statuses(),
    busyPhones: [...busyPhones],
    startingPhones: [...startingPhones],
    installing: !!installation,
    terminalPrompt: !preferences.terminalReviewed,
  };
}
async function publish() {
  try {
    const next = await state();
    send('dock:state-changed', next);
    for (const entry of devices?.entries.values() ?? [])
      if (!entry.window.isDestroyed()) entry.window.webContents.send('dock:state-changed', next);
  } catch (error) {
    send('dock:error', message(error));
  }
}
async function phone(id) {
  phoneID(id);
  const found = (await listPhones(paths)).find((p) => p.id === id);
  if (!found) throw new Error('This phone no longer exists. Refresh the library.');
  return found;
}
async function exclusive(id, action) {
  if (adbRepair) throw new Error('Wait for the Android connection repair to finish.');
  phoneID(id);
  if (busyPhones.has(id)) throw new Error('A phone operation is already in progress.');
  busyPhones.add(id);
  void publish();
  try {
    return await action();
  } finally {
    busyPhones.delete(id);
    await publish();
  }
}
function stopped(id) {
  if (runtime.status(id).canStop || !['idle', 'error'].includes(runtime.status(id).state))
    throw new Error('Stop the phone before editing or deleting it.');
}
async function start(id) {
  return exclusive(id, async () => {
    const selected = await phone(id);
    startingPhones.add(id);
    try {
      devices.open(selected);
      await runtime.start(selected);
      const status = runtime.status(id);
      const display = await devices.waitForDisplay(id, status.sessionID);
      return { ...runtime.status(id), displayReady: display.displayReady };
    } finally {
      startingPhones.delete(id);
    }
  });
}
async function openDevice(id) {
  const selected = await phone(id);
  devices.open(selected);
  const status = runtime.status(id);
  if (status.state === 'running') return devices.waitForDisplay(id, status.sessionID);
  return status;
}
async function stop(id) {
  phoneID(id);
  if (startingPhones.has(id)) {
    await runtime.stop(id);
    await publish();
    return runtime.status(id);
  }
  return exclusive(id, async () => {
    await runtime.stop(id);
    return runtime.status(id);
  });
}
function setupOptions() {
  return {
    paths,
    executable: process.env.APPIMAGE || process.execPath,
    ...(smoke ? { home: smokeHome } : {}),
  };
}
async function dispatch(command) {
  if (command.command === 'help') return HELP;
  if (command.command === 'repair-adb') {
    if (adbRepair) return adbRepair;
    if (busyPhones.size || startingPhones.size)
      throw new Error('Wait for phone operations to finish before repairing ADB.');
    const ids = [...devices.entries.keys()];
    adbRepair = (async () => {
      await Promise.all(ids.map((id) => devices.detach(id)));
      const result = await repairAdb({
        adb: sdkExecutables(paths).adb,
        env: sdkEnvironment(paths),
      });
      for (const id of ids) {
        const entry = devices.entries.get(id);
        if (entry) devices.send(entry, 'dock:adb-repaired', null);
      }
      return result;
    })();
    try {
      return await adbRepair;
    } catch (error) {
      for (const id of ids)
        devices.reportError(id, `Android connection repair failed: ${message(error)}`);
      throw error;
    } finally {
      adbRepair = null;
    }
  }
  if (command.command === 'list')
    return (await listPhones(paths)).map((p) => ({
      id: p.id,
      name: p.name,
      api: p.api,
      ...runtime.status(p.id),
    }));
  await phone(command.id);
  switch (command.command) {
    case 'boot':
      return start(command.id);
    case 'stop':
      return stop(command.id);
    case 'status':
      return runtime.status(command.id);
    case 'install':
      await runtime.installAPK(command.id, command.value);
      return { message: 'APK installed.' };
    case 'open-url':
      await runtime.openURL(command.id, command.value);
      return { message: 'URL opened.' };
  }
}
function registerIPC() {
  ipcMain.on('dock:display-frame', (event, frame) => {
    const context = windowContext(event);
    if (context?.kind === 'device') devices.frameReady(context.id, frame);
  });
  ipcMain.on('dock:recover-video', (event, streamID) => {
    const context = windowContext(event);
    if (context?.kind === 'device' && typeof streamID === 'string')
      devices.recoverVideo(context.id, streamID);
  });
  const handle = (name, fn, { device = false, onlyDevice = false } = {}) =>
    ipcMain.handle(`dock:${name}`, async (event, value) => {
      const context = windowContext(event);
      if (
        !context ||
        (onlyDevice && context.kind !== 'device') ||
        (context.kind === 'device' && !device && !onlyDevice)
      )
        throw new Error('This window cannot perform that action.');
      return fn(value, context);
    });
  handle('state', state, { device: true });
  handle(
    'device-state',
    (_value, context) => ({
      phone: context.entry.phone,
      status: runtime.status(context.id),
      pendingStart: startingPhones.has(context.id),
      streamID: context.entry.streamID,
      displayReady: context.entry.displayReady,
      error: context.entry.error?.message ?? context.entry.error ?? null,
    }),
    { onlyDevice: true },
  );
  handle('open-device', (id, context) => openDevice(scopedPhone(context, id)));
  handle(
    'display-ready',
    (frame, context) => {
      const result = devices.frameReady(context.id, frame);
      if (result) {
        resizeDevice(context.entry, frame);
        send('dock:display-recovered', context.id);
      }
      return result;
    },
    { onlyDevice: true },
  );
  handle(
    'display-failed',
    (failure, context) => {
      if (
        failure?.sessionID !== runtime.status(context.id).sessionID ||
        (failure.streamID && failure.streamID !== context.entry.streamID)
      )
        return false;
      if (typeof failure.message !== 'string' || !failure.message || failure.message.length > 4096)
        throw new Error('Invalid display error.');
      devices.reportError(context.id, failure.message);
      return true;
    },
    { onlyDevice: true },
  );
  handle(
    'window-action',
    (action, context) => {
      if (action === 'minimize') context.window.minimize();
      else if (action === 'maximize') {
        if (context.window.isMaximized()) context.window.unmaximize();
        else context.window.maximize();
      } else if (action === 'close') context.window.close();
      else if (action === 'library') showLibrary();
      else throw new Error('Unknown window action.');
    },
    { onlyDevice: true },
  );
  handle('catalog', async () => {
    catalog = await fetchCatalog({ host });
    return catalog.map((v) => ({
      id: v.id,
      title: v.title,
      api: v.api,
      abi: v.abi,
      revision: v.revision,
    }));
  });
  handle('review', async (id) => {
    if (installation) throw new Error('A download is already in progress.');
    const version = catalog.find((v) => v.id === id);
    if (!version) throw new Error('Refresh Android versions and select one.');
    const generation = ++reviewGeneration;
    const reviewed = await reviewInstall({ paths, version });
    if (generation !== reviewGeneration) throw new Error('A newer download review is open.');
    plan = reviewed;
    return {
      token: plan.token,
      title: version.title,
      downloadBytes: plan.downloadBytes,
      requiredBytes: plan.requiredBytes,
      licenses: plan.licenses,
    };
  });
  handle('download', async (value) => {
    if (
      installation ||
      !plan ||
      value?.token !== plan.token ||
      !Array.isArray(value.licenses) ||
      !value.licenses.every((v) => typeof v === 'string')
    )
      throw new Error('Review the selected download before continuing.');
    const selectedPlan = plan;
    plan = null;
    installation = new AbortController();
    void publish();
    try {
      installationWork = installVersion({
        paths,
        plan: selectedPlan,
        acceptedLicenses: value.licenses,
        signal: installation.signal,
        onProgress: (progress) => send('dock:progress', progress),
      });
      const installed = await installationWork;
      if (preferences.terminalEnabled) {
        try {
          await installTerminal(setupOptions());
        } catch (error) {
          send(
            'dock:error',
            'Android is installed. Reopen Terminal Setup to finish updating your environment: ' +
              message(error),
          );
        }
      }
      return installed;
    } finally {
      installation = null;
      installationWork = null;
      await publish();
    }
  });
  handle('cancel-download', () => installation?.abort());
  handle('start', (id, context) => start(scopedPhone(context, id)), { device: true });
  handle(
    'stop',
    async (id, context) => {
      scopedPhone(context, id);
      await phone(id);
      const sessionID = runtime.status(id).sessionID;
      const result = await dialog.showMessageBox(context.window, {
        type: 'question',
        buttons: ['Keep Running', 'Stop Device'],
        defaultId: 0,
        cancelId: 0,
        message: 'Stop this phone?',
        detail: 'Android will shut down. Its apps and data will be kept.',
      });
      if (result.response === 1) {
        if (runtime.status(id).sessionID !== sessionID)
          throw new Error(
            'This phone restarted while the confirmation was open. Review its current state and try again.',
          );
        return stop(id);
      }
      return { cancelled: true };
    },
    { device: true },
  );
  handle('edit', async ({ id, changes } = {}) =>
    exclusive(id, async () => {
      stopped(id);
      await phone(id);
      const keys = ['name', 'memory', 'cores', 'width', 'height', 'density'];
      if (
        !changes ||
        typeof changes !== 'object' ||
        Object.keys(changes).some((key) => !keys.includes(key))
      )
        throw new Error('Invalid phone configuration.');
      return updatePhone({ paths, id, changes });
    }),
  );
  handle('delete', async (id) =>
    exclusive(id, async () => {
      stopped(id);
      const selected = await phone(id);
      const result = await dialog.showMessageBox(win, {
        type: 'warning',
        buttons: ['Keep Phone', 'Delete Phone'],
        defaultId: 0,
        cancelId: 0,
        message: `Delete ${selected.name}?`,
        detail:
          'The phone and its apps and data will move to the Recycle Bin or Trash. The downloaded Android version will be kept so you can create another phone.',
      });
      if (result.response !== 1) return { cancelled: true };
      stopped(id);
      const deleted = await deletePhone({ paths, id, trash: (target) => shell.trashItem(target) });
      devices.close(id);
      return deleted;
    }),
  );
  handle(
    'attach',
    async (id, context) => {
      scopedPhone(context, id);
      return devices.attach(id);
    },
    { onlyDevice: true },
  );
  handle('detach', (id, context) => devices.detach(scopedPhone(context, id)), { onlyDevice: true });
  handle('terminal-preview', () => terminalPreview(setupOptions()));
  handle('open-sdk', async () => {
    await mkdir(paths.sdk, { recursive: true });
    const error = await shell.openPath(paths.sdk);
    if (error) throw new Error(error);
  });
  handle(
    'screenshot',
    async (_value, context) => {
      if (!context.entry.displayReady || runtime.status(context.id).state !== 'running')
        throw new Error('Wait for the phone display before taking a screenshot.');
      const png = await context.window.webContents.executeJavaScript(
        "document.querySelector('#screen').toDataURL('image/png')",
      );
      if (
        typeof png !== 'string' ||
        !png.startsWith('data:image/png;base64,') ||
        png.length > 48 * 1024 * 1024
      )
        throw new Error('The phone screenshot could not be captured.');
      const result = await dialog.showSaveDialog(context.window, {
        title: 'Save Screenshot',
        defaultPath: path.join(app.getPath('pictures'), `${context.id}-${Date.now()}.png`),
        filters: [{ name: 'PNG image', extensions: ['png'] }],
      });
      if (!result.canceled && result.filePath) {
        await writeFile(
          result.filePath,
          Buffer.from(png.slice('data:image/png;base64,'.length), 'base64'),
        );
        return { message: 'Screenshot saved.' };
      }
    },
    { onlyDevice: true },
  );
  handle('terminal-later', async () => {
    preferences.terminalReviewed = true;
    await preferenceWrite();
  });
  handle('terminal-install', async () => {
    if (!app.isPackaged)
      throw new Error('Install the packaged app before setting up terminal commands.');
    const result = await installTerminal(setupOptions());
    preferences.terminalReviewed = true;
    preferences.terminalEnabled = true;
    await preferenceWrite();
    return result;
  });
  handle(
    'install-apk',
    async (id, context) => {
      scopedPhone(context, id);
      await phone(id);
      const result = await dialog.showOpenDialog(context.window, {
        title: 'Install an Android app',
        properties: ['openFile'],
        filters: [{ name: 'Android package', extensions: ['apk'] }],
      });
      if (!result.canceled) {
        await runtime.installAPK(id, result.filePaths[0]);
        return { message: 'APK installed.' };
      }
    },
    { device: true },
  );
  const helpLinks = {
    acceleration: 'https://developer.android.com/studio/run/emulator-acceleration',
    releases: 'https://github.com/SuryaSriramD/DroidDock/releases',
    project: 'https://github.com/SuryaSriramD/DroidDock',
  };
  handle('help', (topic) => {
    if (!Object.hasOwn(helpLinks, topic)) throw new Error('Unknown help topic.');
    return shell.openExternal(helpLinks[topic]);
  });
  ipcMain.on('dock:input', (event, value) => {
    const context = windowContext(event);
    if (context?.kind !== 'device') return;
    try {
      runtime.input(scopedPhone(context, value?.id), value.action);
    } catch (error) {
      devices.reportError(context.id, error);
    }
  });
  ipcMain.on('dock:video-ack', (event, sequence) => {
    const context = windowContext(event);
    if (context?.kind === 'device') devices.acknowledge(context.id, sequence);
  });
  ipcMain.on('dock:display-size', (event, size) => {
    const context = windowContext(event);
    if (context?.kind === 'device') {
      try {
        resizeDevice(context.entry, size);
      } catch (error) {
        devices.reportError(context.id, error);
      }
    }
  });
}
function secureWindow(window) {
  window.removeMenu();
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event) => event.preventDefault());
  window.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) =>
    callback(false),
  );
}
function showLibrary() {
  if (!win || win.isDestroyed()) createWindow();
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}
function makeDeviceWindow(phone) {
  const area = screen.getDisplayMatching(
    win && !win.isDestroyed() ? win.getBounds() : screen.getPrimaryDisplay().workArea,
  ).workArea;
  const bounds = deviceWindowBounds({ width: phone.width, height: phone.height, workArea: area });
  const device = new BrowserWindow({
    ...bounds,
    minWidth: Math.min(360, bounds.width),
    minHeight: Math.min(480, bounds.height),
    title: phone.name,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      backgroundThrottling: false,
      preload: path.join(here, 'preload.cjs'),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
    },
  });
  secureWindow(device);
  device.on('unmaximize', () => {
    const entry = devices.entries.get(phone.id);
    if (entry?.lastSize) resizeDevice(entry, entry.lastSize);
  });
  return device;
}
function resizeDevice(entry, size) {
  if (!size || ![size.width, size.height].every((v) => Number.isInteger(v) && v > 0 && v <= 8192))
    throw new Error('Invalid decoded display size.');
  const orientation = size.width > size.height ? 'landscape' : 'portrait';
  const previous =
    entry.orientation ?? (entry.phone.width > entry.phone.height ? 'landscape' : 'portrait');
  entry.lastSize = { width: size.width, height: size.height };
  if (entry.window.isMaximized() || entry.window.isFullScreen()) return;
  if (previous === orientation) return;
  entry.orientation = orientation;
  const current = entry.window.getBounds(),
    area = screen.getDisplayMatching(current).workArea;
  const bounds = deviceWindowBounds({
    ...size,
    workArea: area,
    current,
  });
  entry.window.setMinimumSize(
    Math.min(360, area.width),
    Math.min(orientation === 'portrait' ? 480 : 260, area.height),
  );
  entry.window.setBounds(bounds);
}

function createWindow() {
  win = new BrowserWindow({
    width: 1080,
    height: 740,
    useContentSize: true,
    minWidth: 900,
    minHeight: 620,
    title: 'DroidDock',
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#242424' : '#f0f0f0',
    show: false,
    webPreferences: {
      preload: path.join(here, 'preload.cjs'),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
    },
  });
  secureWindow(win);
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => {
    win = null;
  });
  if (smoke) {
    const library = win;
    library.webContents.once('did-finish-load', async () => {
      try {
        const { runSmoke } = await import('../scripts/smoke-ui.mjs');
        await runSmoke({ win: library, devices, runtime, dispatch, paths });
        await runtime.stopAll();
        await closeCommands?.();
        quitting = true;
        console.log('DROIDDOCK_SMOKE_OK');
        app.exit(0);
      } catch (error) {
        quitting = true;
        console.error(error);
        app.exit(1);
      }
    });
  }
  void win.loadURL(rendererURL);
}
async function cli(args) {
  if (args[0] === 'expo') {
    const { id, port } = parseExpoArgs(args.slice(1));
    const project = await expoProject(process.cwd());
    await cli(['boot', id]);
    process.exitCode = await runExpo({ paths, project, port });
    return;
  }
  const command = parseCommand(args);
  if (command.command === 'help') {
    await new Promise((resolve) => process.stdout.write(HELP, resolve));
    return;
  }
  try {
    return await sendCommand(path.join(paths.root, 'commands'), args);
  } catch (error) {
    if (!['ENOENT', 'ECONNREFUSED', 'ECONNRESET'].includes(error.code)) throw error;
  }
  const launchArgs = app.isPackaged ? [] : [path.resolve(here, '..')];
  const child = spawn(process.env.APPIMAGE || process.execPath, launchArgs, {
    detached: true,
    stdio: 'ignore',
    env: process.env,
  });
  child.unref();
  for (let attempt = 0; attempt < 100; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    try {
      return await sendCommand(path.join(paths.root, 'commands'), args);
    } catch (error) {
      if (!['ENOENT', 'ECONNREFUSED', 'ECONNRESET'].includes(error.code)) throw error;
    }
  }
  throw new Error('DroidDock did not open. Launch the app and try again.');
}
async function launch() {
  try {
    if (smoke) console.log('Smoke: initializing isolated desktop');
    app.setName('DroidDock');
    if (smoke) {
      const temporary = await realpath(
        process.env.DROIDDOCK_SMOKE_ROOT ||
          (await mkdtemp(path.join(os.tmpdir(), 'droiddock-ui-'))),
      );
      smokeHome = temporary;
      app.setPath('userData', path.join(temporary, 'electron'));
      app.setPath('sessionData', path.join(temporary, 'electron'));
      const fixturePlatform = process.platform === 'win32' ? 'win32' : 'linux';
      host = hostInfo(fixturePlatform, 'x64');
      paths = pathsFor({
        platform: fixturePlatform,
        home: temporary,
        env: { XDG_DATA_HOME: temporary, LOCALAPPDATA: temporary },
      });
    } else {
      host = hostInfo();
      paths = pathsFor();
    }
    if (cliIndex !== -1) {
      try {
        const result = await cli(process.argv.slice(cliIndex + 1));
        if (result !== undefined)
          await new Promise((resolve) =>
            process.stdout.write(
              typeof result === 'string' ? result + '\n' : JSON.stringify(result, null, 2) + '\n',
              resolve,
            ),
          );
        app.exit(process.exitCode || 0);
      } catch (error) {
        await new Promise((resolve) => process.stderr.write(message(error) + '\n', resolve));
        app.exit(1);
      }
    } else if (!app.requestSingleInstanceLock()) {
      app.quit();
    } else {
      await app.whenReady();
      if (smoke) console.log('Smoke: Electron ready');
      await mkdir(paths.root, { recursive: true, mode: 0o700 });
      try {
        preferences = JSON.parse(
          await readFile(path.join(paths.root, 'desktop-preferences.json'), 'utf8'),
        );
      } catch {}
      if (!smoke && app.isPackaged && preferences.terminalEnabled) {
        try {
          await installTerminal(setupOptions());
        } catch (error) {
          dialog.showErrorBox('Terminal Setup needs attention', message(error));
        }
      }
      runtime = smoke
        ? new (await import('../scripts/smoke-runtime.mjs')).SmokeRuntime()
        : new RuntimeManager({
            paths,
            executables: sdkExecutables(paths),
            environment: sdkEnvironment(paths),
            serverPath: app.isPackaged
              ? path.join(process.resourcesPath, 'scrcpy-server')
              : path.resolve(here, '../../Resources/scrcpy-server'),
          });
      devices = new DeviceWindows({
        createWindow: makeDeviceWindow,
        url: phoneURL,
        runtime,
        onError: (id, error) => send('dock:error', { id, message: message(error) }),
        onClosed: () => {
          if (!quitting && !quitInProgress && !win) showLibrary();
        },
      });
      runtime.on('state', (status) => {
        devices.statusChanged(status);
        void publish();
      });
      runtime.on('error-message', (event) => {
        devices.reportError(event.id, event.message);
      });
      runtime.on('video', (packet) => devices.video(packet));
      registerIPC();
      if (smoke) console.log('Smoke: opening library');
      closeCommands = await startCommandServer({
        directory: path.join(paths.root, 'commands'),
        dispatch,
      });
      createWindow();
      app.on('second-instance', showLibrary);
      app.on('window-all-closed', () => app.quit());
      app.on('before-quit', (event) => {
        if (quitting) return;
        event.preventDefault();
        if (quitInProgress) return;
        quitInProgress = true;
        installation?.abort();
        void (async () => {
          try {
            await installationWork?.catch(() => {});
            await runtime.stopAll();
            await closeCommands?.();
            quitting = true;
            app.quit();
          } catch (error) {
            quitInProgress = false;
            if (!win) createWindow();
            dialog.showErrorBox(
              'DroidDock could not stop a phone',
              message(error) + '\nStop the phone before quitting.',
            );
          }
        })();
      });
    }
  } catch (error) {
    console.error(error);
    if (cliIndex !== -1 || smoke) app.exit(1);
    else {
      await app.whenReady();
      dialog.showErrorBox('DroidDock cannot start', message(error));
      app.exit(1);
    }
  }
}
void launch();
