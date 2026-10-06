import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { pathsFor, sdkEnvironment } from '../src/core/platform.mjs';

// An explicit, isolated release check, never part of ordinary unit tests.
assert.equal(process.platform, 'linux');
assert.equal(process.env.GITHUB_ACTIONS, 'true', 'Run this check on a disposable CI runner.');
assert.equal(process.env.DROIDDOCK_ACCEPT_ANDROID_LICENSES, 'true', 'License acceptance required.');
const executable = process.env.DROIDDOCK_TEST_EXECUTABLE;
assert.ok(executable && path.isAbsolute(executable), 'Provide the installed application.');
const execute = promisify(execFile);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'droiddock-release-'));
const evidence = path.resolve('release-evidence');
await fs.mkdir(evidence, { recursive: true });
const env = {
  ...process.env,
  HOME: root,
  XDG_DATA_HOME: path.join(root, 'data'),
  XDG_CONFIG_HOME: path.join(root, 'config'),
  XDG_CACHE_HOME: path.join(root, 'cache'),
  EXPO_NO_TELEMETRY: '1',
  __UNSAFE_EXPO_HOME_DIRECTORY: path.join(root, 'expo-home'),
};
const paths = pathsFor({ home: root, env });
const report = { platform: os.release(), commit: process.env.GITHUB_SHA, checks: [] };
let app, metro, library, phone, phoneID, serial, wrapper;
let appLog = '',
  metroLog = '';
const connections = [];
const record = (check, details = {}) => {
  report.checks.push({ check, ...details });
  console.log('ANDROID_RELEASE_CHECK', check, JSON.stringify(details));
};
async function until(check, timeout = 60000) {
  const deadline = Date.now() + timeout;
  let error;
  do {
    try {
      const value = await check();
      if (value) return value;
    } catch (reason) {
      error = reason;
    }
    await sleep(1000);
  } while (Date.now() < deadline);
  throw new Error(`Timed out waiting for release check: ${error?.message || 'condition not met'}`);
}
class CDP {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.sequence = 0;
    this.pending = new Map();
    this.ready = new Promise((resolve, reject) => {
      this.socket.addEventListener('open', resolve, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const data = JSON.parse(event.data);
      const request = this.pending.get(data.id);
      if (!request) return;
      this.pending.delete(data.id);
      clearTimeout(request.timer);
      data.error ? request.reject(new Error(data.error.message)) : request.resolve(data.result);
    });
    connections.push(this);
  }
  async send(method, params = {}, timeout = 60000) {
    await this.ready;
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP timeout: ${method}`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression, timeout) {
    const result = await this.send(
      'Runtime.evaluate',
      { expression, awaitPromise: true, returnByValue: true },
      timeout,
    );
    if (result.exceptionDetails)
      throw new Error(
        result.exceptionDetails.exception?.description || result.exceptionDetails.text,
      );
    return result.result.value;
  }
  async screenshot(name) {
    const result = await this.send('Page.captureScreenshot');
    await fs.writeFile(path.join(evidence, name), Buffer.from(result.data, 'base64'));
  }
}
async function page(suffix) {
  const target = await until(async () => {
    const targets = await (await fetch('http://127.0.0.1:9229/json/list')).json();
    return targets.find((value) => value.url.endsWith(suffix));
  });
  return new CDP(target.webSocketDebuggerUrl);
}
async function cli(args, timeout = 240000) {
  const result = await execute(wrapper, args, { env, timeout, maxBuffer: 2 * 1024 * 1024 });
  assert.doesNotMatch(result.stderr, /Gpu Cache Creation failed|Unable to create cache/);
  return JSON.parse(result.stdout);
}
async function adb(args) {
  const result = await execute(
    path.join(paths.sdk, 'platform-tools/adb'),
    ['-s', serial, ...args],
    {
      env: sdkEnvironment(paths, env),
      timeout: 20000,
      maxBuffer: 4 * 1024 * 1024,
    },
  );
  return result.stdout;
}
const ui = () => adb(['exec-out', 'uiautomator', 'dump', '/dev/tty']);
function bounds(xml, label) {
  const node = xml.match(new RegExp(`<node[^>]*(?:text|content-desc)="${label}"[^>]*>`))?.[0];
  const match = node?.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
  return match && { x: (+match[1] + +match[3]) / 2, y: (+match[2] + +match[4]) / 2 };
}
async function pixels() {
  return phone.evaluate("document.querySelector('#screen').toDataURL()");
}
async function stopChild(child) {
  if (!child || child.exitCode !== null || child.signalCode) return;
  const stopped = new Promise((resolve) => child.once('exit', resolve));
  child.kill('SIGINT');
  const forced = setTimeout(() => child.kill('SIGKILL'), 10000);
  await stopped;
  clearTimeout(forced);
}
try {
  app = spawn(executable, ['--remote-debugging-port=9229'], {
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  app.stdout.on('data', (chunk) => {
    appLog = (appLog + chunk).slice(-250000);
  });
  app.stderr.on('data', (chunk) => {
    appLog = (appLog + chunk).slice(-250000);
  });
  app.on('error', (error) => {
    appLog += error.stack;
  });
  library = await page('/renderer/index.html');
  await until(() => library.evaluate('Boolean(window.droiddock && document.body.dataset.ready)'));
  const initial = await library.evaluate('window.droiddock.state()');
  assert.equal(initial.packaged, true);
  assert.equal(initial.phones.length, 0);
  record('installed app opens with an empty private profile', { version: initial.version });
  const review = await library.evaluate(
    `(async () => {
    const versions = await window.droiddock.catalog();
    const version = versions.find(v => v.api === '36' && v.abi === 'x86_64');
    if (!version) throw new Error('Android 16 x86_64 is absent from the catalog');
    window.releasePlan = await window.droiddock.review(version.id);
    return {bytes: window.releasePlan.downloadBytes, licenses: window.releasePlan.licenses.map(l => l.id)};
  })()`,
    120000,
  );
  record('official Android package review', review);
  await library.evaluate(
    'window.droiddock.download(window.releasePlan.token, window.releasePlan.licenses.map(l => l.id))',
    900000,
  );
  const installed = await library.evaluate('window.droiddock.state()');
  assert.equal(installed.phones.length, 1);
  phoneID = installed.phones[0].id;
  const acceleration = await execute(path.join(paths.sdk, 'emulator/emulator'), ['-accel-check'], {
    env: sdkEnvironment(paths, env),
    timeout: 20000,
  });
  assert.match(acceleration.stdout + acceleration.stderr, /KVM.*(installed|usable)/i);
  record('managed download and KVM acceleration', {
    phoneID,
    acceleration: acceleration.stdout.trim(),
  });
  await library.evaluate('window.droiddock.terminalInstall()');
  wrapper = path.join(paths.terminal, 'bin/droiddock');
  const boot = await cli(['boot', phoneID]);
  assert.equal(boot.state, 'running');
  assert.equal(boot.displayReady, true);
  serial = boot.serial;
  phone = await page('/renderer/phone.html');
  await until(() => phone.evaluate("document.body.dataset.displayState === 'connected'"));
  await phone.screenshot('android-home.png');
  record('terminal boot produces a decoded Android display', { serial });
  const project = path.join(root, 'expo-project');
  await fs.mkdir(project);
  await fs.writeFile(
    path.join(project, 'package.json'),
    JSON.stringify({
      name: 'droiddock-release-test',
      version: '1.0.0',
      private: true,
      main: 'index.js',
      dependencies: { expo: '57.0.26', react: '19.2.3', 'react-native': '0.86.3' },
    }),
  );
  let source = `import React, {useState,useEffect} from 'react';
import {registerRootComponent} from 'expo';
import {View,Text,Pressable} from 'react-native';
const ANIMATE = false;
const LABEL = 'before';
function App(){const [count,setCount]=useState(0);const [tick,setTick]=useState(0);
useEffect(()=>{if(!ANIMATE)return;const timer=setInterval(()=>setTick(t=>t+1),100);return()=>clearInterval(timer)},[ANIMATE]);
return <View style={{flex:1,backgroundColor:'#102c42',alignItems:'center',justifyContent:'center',gap:24}}>
<Text style={{fontSize:26,color:'white'}}>DroidDock release {LABEL}</Text>
<Text style={{fontSize:22,color:'white'}}>Frames {tick}</Text>
<Pressable accessibilityRole="button" accessibilityLabel={'Counter '+count} onPress={()=>setCount(c=>c+1)} style={{padding:28,backgroundColor:'#fbb64b'}}><Text style={{fontSize:24}}>{'Counter '+count}</Text></Pressable></View>}
registerRootComponent(App);`;
  const entry = path.join(project, 'index.js');
  await fs.writeFile(entry, source);
  assert.ok(process.env.npm_execpath, 'Invoke through npm run verify:android');
  await execute(
    process.execPath,
    [process.env.npm_execpath, 'install', '--no-audit', '--no-fund'],
    { cwd: project, env, timeout: 240000, maxBuffer: 4 * 1024 * 1024 },
  );
  metro = spawn(wrapper, ['expo', phoneID], {
    cwd: project,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  metro.stdout.on('data', (chunk) => {
    metroLog = (metroLog + chunk).slice(-250000);
  });
  metro.stderr.on('data', (chunk) => {
    metroLog = (metroLog + chunk).slice(-250000);
  });
  metro.on('error', (error) => {
    metroLog += error.stack;
  });
  const loaded = await until(async () => {
    const xml = await ui();
    const welcome = bounds(xml, 'Continue');
    if (welcome) {
      await adb(['shell', 'input', 'tap', String(welcome.x), String(welcome.y)]);
      return false;
    }
    return xml.includes('DroidDock release before') && bounds(xml, 'Counter 0') && xml;
  }, 300000);
  const button = bounds(loaded, 'Counter 0');
  const screen = await phone.evaluate(
    "(() => {const r=document.querySelector('#screen').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})()",
  );
  const point = {
    x: screen.x + (screen.width * button.x) / 1080,
    y: screen.y + (screen.height * button.y) / 2400,
  };
  await phone.send('Input.dispatchMouseEvent', {
    type: 'mousePressed',
    button: 'left',
    clickCount: 1,
    ...point,
  });
  await phone.send('Input.dispatchMouseEvent', {
    type: 'mouseReleased',
    button: 'left',
    clickCount: 1,
    ...point,
  });
  await until(async () => (await ui()).includes('Counter 1'));
  source = source.replace("LABEL = 'before'", "LABEL = 'after'");
  await fs.writeFile(entry, source);
  await until(async () => (await ui()).includes('DroidDock release after'));
  await phone.screenshot('expo-fast-refresh.png');
  assert.match(metroLog, /bundled Node/);
  record('Expo Go, canvas tap, and Fast Refresh');
  await phone.evaluate(
    'window.releaseRecoveries=0; window.droiddock.onDisplayRecovering(()=>window.releaseRecoveries++)',
  );
  await fs.writeFile(entry, source.replace('ANIMATE = false', 'ANIMATE = true'));
  const initialPixels = await pixels();
  await until(async () => (await pixels()) !== initialPixels);
  for (let attempt = 0; attempt < 3; attempt++) {
    await phone.evaluate(
      '(()=>{const end=performance.now()+2400;while(performance.now()<end){}})()',
    );
    await until(() => phone.evaluate("document.body.dataset.displayState === 'connected'"));
    const before = await pixels();
    await sleep(1200);
    assert.notEqual(await pixels(), before, 'Pixels must advance after a renderer stall');
  }
  const recoveries = await phone.evaluate('window.releaseRecoveries');
  assert.ok(recoveries > 0);
  record('automatic display recovery after three renderer stalls', { recoveries });
  await fs.writeFile(entry, source);
  await sleep(3000);
  const staticRecoveries = await phone.evaluate('window.releaseRecoveries');
  await sleep(15000);
  assert.equal(await phone.evaluate('window.releaseRecoveries'), staticRecoveries);
  record('static screen does not trigger recovery');
  await cli(['repair-adb']);
  await until(() => phone.evaluate("document.body.dataset.displayState === 'connected'"));
  const repaired = await cli(['status', phoneID]);
  assert.equal(repaired.sessionID, boot.sessionID);
  record('ADB repair preserves Android and reconnects its display');
  await stopChild(metro);
  assert.equal((await cli(['status', phoneID])).state, 'running');
  await cli(['stop', phoneID]);
  assert.equal((await cli(['status', phoneID])).state, 'idle');
  record('Metro shutdown and Android stop');
  report.success = true;
  console.log('DROIDDOCK_ANDROID_RELEASE_OK');
} catch (error) {
  report.success = false;
  report.error = error.stack;
  await phone?.screenshot('failure-phone.png').catch(() => {});
  await library?.screenshot('failure-library.png').catch(() => {});
  throw error;
} finally {
  await stopChild(metro);
  if (wrapper && phoneID) await cli(['stop', phoneID], 30000).catch(() => {});
  for (const connection of connections) connection.socket.close();
  await stopChild(app);
  await execute(path.join(paths.sdk, 'platform-tools/adb'), ['kill-server'], {
    env: sdkEnvironment(paths, env),
    timeout: 5000,
  }).catch(() => {});
  await fs.writeFile(path.join(evidence, 'report.json'), JSON.stringify(report, null, 2));
  await fs.writeFile(path.join(evidence, 'app.log'), appLog);
  await fs.writeFile(path.join(evidence, 'expo.log'), metroLog);
  await fs.writeFile(
    path.join(evidence, 'source.sha256'),
    createHash('sha256')
      .update(await fs.readFile(new URL(import.meta.url)))
      .digest('hex'),
  );
  await fs.rm(root, { recursive: true, force: true });
}
