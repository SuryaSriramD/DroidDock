import { app, BrowserWindow, dialog, ipcMain, shell } from 'electron';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import { mkdir, readFile, writeFile, rename, mkdtemp, realpath } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { hostInfo, pathsFor, sdkEnvironment, sdkExecutables } from './core/platform.mjs';
import { terminalPreview, installTerminal } from './core/terminal.mjs';
import { fetchCatalog } from './core/catalog.mjs';
import { reviewInstall, installVersion } from './core/installer.mjs';
import { listPhones, updatePhone, deletePhone } from './core/phones.mjs';
import { RuntimeManager } from './core/runtime.mjs';
import { HELP, parseCommand, sendCommand, startCommandServer } from './core/commands.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const rendererURL = pathToFileURL(path.join(here, 'renderer/index.html')).href;
const smoke = !app.isPackaged && process.argv.includes('--smoke');
const cliIndex = process.argv.indexOf('--cli');
let win,
  runtime,
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
  preferences = {},
  streamSequence = 0;
const pendingFrames = new Set(),
  desynced = new Set(),
  busyPhones = new Set();
let smokeFailure, smokeHome;

function message(error) {
  return error instanceof Error ? error.message : String(error);
}
function phoneID(id) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,120}$/.test(id))
    throw new Error('Invalid phone ID.');
  return id;
}
function trusted(event) {
  return (
    win &&
    event.sender === win.webContents &&
    event.senderFrame === win.webContents.mainFrame &&
    event.senderFrame.url === rendererURL
  );
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
    installing: !!installation,
    terminalPrompt: !preferences.terminalReviewed,
  };
}
async function publish() {
  try {
    send('dock:state-changed', await state());
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
    await runtime.start(selected);
    win?.show();
    return runtime.status(id);
  });
}
async function stop(id) {
  phoneID(id);
  if (busyPhones.has(id) && runtime.status(id).state === 'starting') {
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
  if (command.command === 'list')
    return (await listPhones(paths)).map((p) => ({
      id: p.id,
      name: p.name,
      api: p.api,
      ...runtime.status(p.id),
    }));
  await phone(command.id);
  switch (command.command) {
    case 'boot': {
      const result = await start(command.id);
      if (win?.webContents.isLoading())
        win.webContents.once('did-finish-load', () => send('dock:show-phone', command.id));
      else send('dock:show-phone', command.id);
      return result;
    }
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
  const handle = (name, fn) =>
    ipcMain.handle(`dock:${name}`, async (event, value) => {
      if (!trusted(event)) throw new Error('Untrusted window.');
      return fn(value);
    });
  handle('state', state);
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
  handle('start', start);
  handle('stop', async (id) => {
    await phone(id);
    const sessionID = runtime.status(id).sessionID;
    const result = await dialog.showMessageBox(win, {
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
  });
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
      return deletePhone({ paths, id, trash: (target) => shell.trashItem(target) });
    }),
  );
  handle('attach', async (id) => {
    await phone(id);
    return runtime.attach(id);
  });
  handle('detach', async (id) => {
    phoneID(id);
    return runtime.detach(id);
  });
  handle('terminal-preview', () => terminalPreview(setupOptions()));
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
  handle('install-apk', async (id) => {
    await phone(id);
    const result = await dialog.showOpenDialog(win, {
      title: 'Install an Android app',
      properties: ['openFile'],
      filters: [{ name: 'Android package', extensions: ['apk'] }],
    });
    if (!result.canceled) {
      await runtime.installAPK(id, result.filePaths[0]);
      return { message: 'APK installed.' };
    }
  });
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
    if (!trusted(event)) return;
    try {
      phoneID(value?.id);
      runtime.input(value.id, value.action);
    } catch (error) {
      send('dock:error', message(error));
    }
  });
  ipcMain.on('dock:video-ack', (event, sequence) => {
    if (trusted(event) && Number.isSafeInteger(sequence)) pendingFrames.delete(sequence);
  });
}
function createWindow() {
  win = new BrowserWindow({
    width: 1240,
    height: 860,
    minWidth: 850,
    minHeight: 640,
    title: 'DroidDock',
    backgroundColor: '#f5f4f1',
    show: false,
    webPreferences: {
      preload: path.join(here, 'preload.cjs'),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
    },
  });
  win.removeMenu();
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (event) => event.preventDefault());
  win.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) =>
    callback(false),
  );
  win.webContents.on('render-process-gone', () => {
    pendingFrames.clear();
    for (const s of runtime.statuses()) void runtime.detach(s.id).catch(() => {});
  });
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => {
    win = null;
  });
  if (smoke) {
    win.webContents.on('console-message', (details) => {
      if (details.level === 'error') smokeFailure = new Error(details.message);
    });
    win.webContents.once('did-finish-load', async () => {
      try {
        console.log('Smoke: renderer loaded');
        await win.webContents.executeJavaScript(
          `new Promise((resolve,reject)=>{const start=Date.now(); const timer=setInterval(()=>{if(document.querySelector('[data-ready="true"]')){clearInterval(timer);resolve(true);} else if(Date.now()-start>10000){clearInterval(timer);reject(new Error('Library failed to initialize'));}},50);})`,
        );
        const checks = await win.webContents.executeJavaScript(
          `(async()=>({title:document.title, bridge:typeof window.droiddock?.state, node:typeof window.require, codec:typeof VideoDecoder, h264:(await VideoDecoder.isConfigSupported({codec:'avc1.42e01f'})).supported}))()`,
        );
        if (
          checks.title !== 'DroidDock' ||
          checks.bridge !== 'function' ||
          checks.node !== 'undefined' ||
          checks.codec !== 'function' ||
          !checks.h264
        )
          throw new Error(`Smoke checks failed: ${JSON.stringify(checks)}`);
        await win.webContents.executeJavaScript(
          `(()=>{if(document.querySelector('#phone-name').textContent!=='Android 16 · API 36 Phone')throw new Error('Fixture phone was not rendered');document.querySelector('#edit').click();if(!document.querySelector('dialog[open] input[type=number]'))throw new Error('Edit form did not open');document.querySelector('#dialog').close();document.querySelector('#terminal-button').click();})()`,
        );
        await win.webContents.executeJavaScript(
          `new Promise((resolve,reject)=>{const start=Date.now();const timer=setInterval(()=>{if(document.querySelector('dialog[open] #terminal-later')){clearInterval(timer);resolve(true);}else if(Date.now()-start>10000){clearInterval(timer);reject(new Error('Terminal dialog failed'));}},50);})`,
        );
        const screenshot = process.env.DROIDDOCK_SMOKE_SCREENSHOT;
        if (screenshot) await writeFile(screenshot, (await win.webContents.capturePage()).toPNG());
        if (smokeFailure) throw smokeFailure;
        console.log('DROIDDOCK_SMOKE_OK');
        app.exit(0);
      } catch (error) {
        console.error(error);
        app.exit(1);
      }
    });
  }
  void win.loadURL(rendererURL);
}
async function cli(args) {
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
        app.exit(0);
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
      runtime = new RuntimeManager({
        paths,
        executables: sdkExecutables(paths),
        environment: sdkEnvironment(paths),
        serverPath: app.isPackaged
          ? path.join(process.resourcesPath, 'scrcpy-server')
          : path.resolve(here, '../../Resources/scrcpy-server'),
      });
      runtime.on('state', () => {
        void publish();
      });
      runtime.on('error-message', (event) => send('dock:error', event.message));
      runtime.on('video', (packet) => {
        if (!win || win.isDestroyed()) return;
        if (packet.kind === 'frame') {
          if (pendingFrames.size >= 8) {
            desynced.add(packet.id);
            return;
          }
          if (desynced.has(packet.id) && !packet.key) return;
        }
        const reset = desynced.delete(packet.id);
        const sequence = ++streamSequence;
        pendingFrames.add(sequence);
        send('dock:video', {
          ...packet,
          data: packet.data ? new Uint8Array(packet.data) : undefined,
          sequence,
          reset,
        });
      });
      registerIPC();
      if (smoke) console.log('Smoke: opening library');
      if (!smoke)
        closeCommands = await startCommandServer({
          directory: path.join(paths.root, 'commands'),
          dispatch,
        });
      createWindow();
      app.on('second-instance', () => {
        if (!win) createWindow();
        win.show();
        win.focus();
      });
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
