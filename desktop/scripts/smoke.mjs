import { spawn } from 'node:child_process';
import { mkdtemp, rm, mkdir, writeFile, realpath } from 'node:fs/promises';
import { pathsFor } from '../src/core/platform.mjs';
import { runtimeVersion } from '../src/core/catalog.mjs';
import { createPhone } from '../src/core/phones.mjs';
import os from 'node:os';
import path from 'node:path';
import electron from 'electron';
const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'droiddock-smoke-')));
let output = '';
try {
  const platform = process.platform === 'win32' ? 'win32' : 'linux';
  const paths = pathsFor({
    platform,
    home: root,
    env: { LOCALAPPDATA: root, XDG_DATA_HOME: root },
  });
  const version = runtimeVersion('system-images;android-36;google_apis;x86_64');
  await mkdir(path.join(paths.sdk, version.imagePath), { recursive: true });
  await writeFile(path.join(paths.sdk, '.droiddock-managed'), 'fixture only');
  await writeFile(path.join(paths.sdk, version.imagePath, '.droiddock-package.json'), '{}');
  await createPhone({ paths, version });
  const child = spawn(electron, ['.', '--smoke'], {
    cwd: path.resolve(import.meta.dirname, '..'),
    env: { ...process.env, DROIDDOCK_SMOKE_ROOT: root },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', (chunk) => {
    output += chunk;
    process.stdout.write(chunk);
  });
  child.stderr.on('data', (chunk) => process.stderr.write(chunk));
  const timer = setTimeout(() => child.kill(), 90_000);
  const code = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', resolve);
  });
  clearTimeout(timer);
  if (code !== 0 || !output.includes('DROIDDOCK_SMOKE_OK'))
    throw new Error(`Desktop smoke failed (exit ${code}).`);
} finally {
  await rm(root, { recursive: true, force: true });
}
