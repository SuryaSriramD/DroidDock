import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { sendCommand } from '../src/core/commands.mjs';

/** Source-only Electron exercise. All phones, preferences and command endpoints are fixtures. */
export async function runSmoke({ win, devices, runtime, dispatch, paths }) {
  const deadline = Date.now() + 50_000;
  const stage = (name) => console.log(`Smoke: ${name}`);
  const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const wait = async (predicate, label, timeout = 8000) => {
    const until = Math.min(deadline, Date.now() + timeout);
    while (Date.now() < until) {
      if (await predicate()) return;
      await pause(30);
    }
    throw new Error(`Smoke timed out: ${label}`);
  };
  const evaluate = (window, code) => window.webContents.executeJavaScript(code);
  const ready = (entry) =>
    !entry.window.isDestroyed() &&
    evaluate(entry.window, `document.body.dataset.displayState === 'connected'`);

  stage('library and isolated edit/terminal flows');
  await wait(() => evaluate(win, `document.body.dataset.ready === 'true'`), 'library ready');
  const library = await evaluate(
    win,
    `({title:document.title, node:typeof window.require, name:document.querySelector('#phone-name').textContent, hasInlineScreen:!!document.querySelector('#screen')})`,
  );
  assert.equal(library.title, 'DroidDock');
  assert.equal(library.node, 'undefined');
  assert.equal(library.name, 'Android 16 · API 36 Phone');
  assert.equal(library.hasInlineScreen, false);
  await evaluate(
    win,
    `document.querySelector('#device-menu-trigger').click();document.querySelector('#edit').click();`,
  );
  await wait(
    () => evaluate(win, `!!document.querySelector('dialog[open] input[type=number]')`),
    'configuration editor',
  );
  await evaluate(
    win,
    `document.querySelector('#dialog').close();document.querySelector('#terminal-button').click();`,
  );
  await wait(
    () => evaluate(win, `!!document.querySelector('dialog[open] #terminal-later')`),
    'terminal preview',
  );
  await evaluate(win, `document.querySelector('#terminal-later').click();`);
  await wait(() => evaluate(win, `!document.querySelector('dialog[open]')`), 'terminal Later');

  stage('separate phone window appears while Android startup is gated');
  await evaluate(win, `document.querySelector('#start').click();`);
  await wait(() => devices.entries.size === 1, 'device window creation');
  const [id] = devices.entries.keys();
  let entry = devices.entries.get(id);
  await wait(
    () =>
      entry.window.isVisible() &&
      evaluate(entry.window, `document.body.dataset.deviceState === 'starting'`),
    'visible starting phone',
  );
  assert.equal(runtime.status(id).state, 'starting');
  assert.equal(entry.displayReady, false);
  const decoder = await evaluate(
    entry.window,
    `({node:typeof window.require, decoder:typeof VideoDecoder})`,
  );
  assert.equal(decoder.node, 'undefined');
  assert.equal(decoder.decoder, 'function');
  runtime.releaseBoot(id);
  await wait(async () => entry.displayReady && (await ready(entry)), 'decoded H.264 phone frame');
  assert.equal(runtime.startCount, 1);
  const canvas = await evaluate(
    entry.window,
    `(()=>{const c=document.querySelector('#screen');return {width:c.width,height:c.height,pixel:[...c.getContext('2d').getImageData(30,30,1,1).data]};})()`,
  );
  assert.equal(canvas.width, 180);
  assert.equal(canvas.height, 320);
  assert.ok(
    canvas.pixel.slice(0, 3).some((value) => value > 20),
    'The decoder must paint the generated color pattern',
  );

  stage('closing/reopening display preserves Android and restores minimized window');
  const firstWindow = entry.window;
  await evaluate(firstWindow, `document.querySelector('#close-window').click();`);
  await wait(() => !devices.entries.has(id), 'closed phone display');
  assert.equal(runtime.status(id).state, 'running');
  await evaluate(win, `document.querySelector('#open').click();`);
  await wait(() => devices.entries.has(id), 'reopened phone window');
  entry = devices.entries.get(id);
  assert.notEqual(entry.window, firstWindow);
  await wait(async () => entry.displayReady && (await ready(entry)), 'reopened decoded display');
  assert.equal(runtime.startCount, 1);
  entry.window.minimize();
  await pause(80);
  await evaluate(win, `document.querySelector('#open').click();`);
  await wait(
    () => !entry.window.isMinimized() && entry.window.isVisible(),
    'restored phone window',
  );

  stage('attach failure stays visible and Reconnect Display recovers');
  const attachBefore = runtime.attachCount;
  runtime.failNextAttachment(id, 'Fixture display connection failed');
  await evaluate(entry.window, `document.querySelector('#reconnect').click();`);
  await wait(
    () =>
      evaluate(
        entry.window,
        `document.body.dataset.displayState === 'error' && !document.querySelector('#state-overlay').hidden && document.querySelector('#overlay-detail').textContent.includes('Fixture display connection failed')`,
      ),
    'persistent display error',
  );
  assert.equal(entry.window.isDestroyed(), false);
  assert.equal(runtime.status(id).state, 'running');
  assert.equal(runtime.attachCount, attachBefore + 1);
  await wait(
    () =>
      evaluate(
        win,
        `!document.querySelector('#notice').hidden && document.querySelector('#notice span').textContent.includes('Fixture display connection failed')`,
      ),
    'scoped library connection error',
  );
  await evaluate(entry.window, `document.querySelector('#overlay-action').click();`);
  await wait(async () => entry.displayReady && (await ready(entry)), 'retry decoded display');
  await wait(
    () => evaluate(win, `document.querySelector('#notice').hidden`),
    'recovered connection notice cleared',
  );
  assert.equal(runtime.startCount, 1);

  stage('decoder failure reason survives detach and clears after a decoded retry');
  const reported = await evaluate(
    entry.window,
    `(async()=>{
    const context=await window.droiddock.deviceState();
    return window.droiddock.displayFailed({streamID:context.streamID,sessionID:context.status.sessionID,message:'Fixture decoder unavailable'});
  })()`,
  );
  assert.equal(reported, true);
  await wait(
    () =>
      evaluate(
        entry.window,
        `document.body.dataset.displayState === 'error' && !document.querySelector('#state-overlay').hidden && document.querySelector('#overlay-detail').textContent === 'Fixture decoder unavailable'`,
      ),
    'persistent decoder error overlay',
  );
  await pause(100);
  assert.equal(
    entry.error,
    'Fixture decoder unavailable',
    'Display detach must preserve the original decoder failure',
  );
  assert.equal(runtime.status(id).state, 'running');
  await wait(
    () =>
      evaluate(
        win,
        `!document.querySelector('#notice').hidden && document.querySelector('#notice span').textContent === 'Fixture decoder unavailable'`,
      ),
    'scoped library decoder error',
  );
  await evaluate(entry.window, `document.querySelector('#overlay-action').click();`);
  await wait(async () => entry.displayReady && (await ready(entry)), 'decoder failure retry');
  await wait(
    () => evaluate(win, `document.querySelector('#notice').hidden`),
    'recovered decoder notice cleared',
  );
  assert.equal(runtime.startCount, 1);

  stage('phone IPC cannot start another device or access terminal setup');
  const denied = await evaluate(
    entry.window,
    `(async()=>{
    const reject=operation=>operation.then(()=>({accepted:true}),error=>({accepted:false,message:String(error.message)}));
    return Promise.all([reject(window.droiddock.start('Different_Phone')),reject(window.droiddock.terminalPreview())]);
  })()`,
  );
  assert.ok(
    denied.every((result) => result.accepted === false),
    'Device-only IPC permissions must reject both actions',
  );
  assert.match(denied[0].message, /different phone/i);
  assert.match(denied[1].message, /cannot perform that action/i);
  assert.equal(devices.entries.size, 1);
  assert.equal(runtime.startCount, 1);
  assert.equal(runtime.status('Different_Phone').state, 'idle');

  stage('authenticated CLI boot waits for a decoded frame');
  await dispatch({ command: 'stop', id });
  await wait(() => runtime.status(id).state === 'idle', 'fixture stopped');
  runtime.pauseVideo();
  let completed = false;
  const command = sendCommand(path.join(paths.root, 'commands'), ['boot', id, '--json']);
  // Register both continuations immediately; a failed CLI must not become an
  // unhandled rejection while the UI gate is being inspected.
  const result = command
    .then(
      (value) => ({ value }),
      (error) => ({ error }),
    )
    .then((value) => {
      completed = true;
      return value;
    });
  await wait(() => runtime.status(id).state === 'starting', 'CLI boot dispatch');
  assert.equal(entry.window.isVisible(), true);
  runtime.releaseBoot(id);
  await wait(
    () => runtime.status(id).state === 'running' && runtime.pendingVideo.length > 0,
    'CLI pending display',
  );
  await pause(60);
  assert.equal(completed, false, 'CLI must not report boot success before decoding');
  assert.equal(entry.displayReady, false);
  runtime.releaseVideo();
  await wait(() => completed, 'CLI first-frame response');
  const response = await result;
  if (response.error) throw response.error;
  assert.equal(response.value.displayReady, true);
  await wait(() => ready(entry), 'CLI phone display connected');
  assert.equal(runtime.startCount, 2);

  const screenshot = process.env.DROIDDOCK_SMOKE_SCREENSHOT;
  if (screenshot) {
    const parsed = path.parse(screenshot);
    const phoneScreenshot = path.join(parsed.dir, `${parsed.name}.phone${parsed.ext || '.png'}`);
    await writeFile(screenshot, (await win.webContents.capturePage()).toPNG());
    await writeFile(phoneScreenshot, (await entry.window.webContents.capturePage()).toPNG());
    stage(`screenshots saved: ${screenshot} and ${phoneScreenshot}`);
  }
  stage('separate phone, real decode, reconnect, and CLI readiness passed');
  return {
    phoneID: id,
    startCount: runtime.startCount,
    attachCount: runtime.attachCount,
    decoded: true,
  };
}
