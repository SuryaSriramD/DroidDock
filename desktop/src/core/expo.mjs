import path from 'node:path';
import { readFile, access } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { sdkEnvironment } from './platform.mjs';

export function parseExpoArgs(args) {
  const [id, ...options] = args;
  if (!id || !/^[A-Za-z0-9_-]{1,120}$/.test(id))
    throw new Error('Use droiddock expo PHONE_ID [--port PORT] from your Expo project.');
  let port = 8081;
  if (options.length) {
    if (options.length !== 2 || options[0] !== '--port' || !/^\d+$/.test(options[1]))
      throw new Error('Use droiddock expo PHONE_ID [--port PORT].');
    port = Number(options[1]);
  }
  if (port < 1024 || port > 65535) throw new Error('Expo port must be between 1024 and 65535.');
  return { id, port };
}

export function expoEnvironment(paths, env = process.env) {
  return {
    ...sdkEnvironment(paths, env),
    // Use the Node runtime shipped with DroidDock, never a Windows npm.cmd
    // wrapper that can silently select a different node.exe beside itself.
    ELECTRON_RUN_AS_NODE: '1',
    // Match Expo's Android URL and adb reverse on IPv4, only in this child.
    NODE_OPTIONS: `${env.NODE_OPTIONS || ''} --dns-result-order=ipv4first`.trim(),
  };
}

export async function expoProject(cwd) {
  let manifest;
  try {
    manifest = JSON.parse(await readFile(path.join(cwd, 'package.json'), 'utf8'));
  } catch {
    throw new Error('Run droiddock expo from a project containing package.json.');
  }
  if (!manifest.dependencies?.expo && !manifest.devDependencies?.expo)
    throw new Error('This project does not declare Expo in package.json.');
  let packageFile;
  try {
    packageFile = createRequire(path.join(cwd, 'package.json')).resolve('expo/package.json');
  } catch {
    throw new Error('Install this Expo project’s dependencies first.');
  }
  const entry = path.join(path.dirname(packageFile), 'bin', 'cli');
  await access(entry);
  const metadata = JSON.parse(await readFile(packageFile, 'utf8'));
  return { entry, version: metadata.version };
}

export async function runExpo({
  paths,
  project,
  port,
  cwd = process.cwd(),
  executable = process.execPath,
  env = process.env,
  spawnProcess = spawn,
}) {
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (major < 22 || (major === 22 && minor < 13))
    throw new Error(
      'This DroidDock build needs Node 22.13 or newer to run current Expo projects. Update DroidDock.',
    );
  console.log(
    `Expo ${project.version} · bundled Node ${process.versions.node} · localhost:${port}`,
  );
  return new Promise((resolve, reject) => {
    const child = spawnProcess(
      executable,
      [project.entry, 'start', '--android', '--go', '--localhost', '--port', String(port)],
      {
        cwd,
        env: expoEnvironment(paths, env),
        shell: false,
        stdio: 'inherit',
        windowsHide: true,
      },
    );
    const interrupt = () => child.kill('SIGINT');
    const terminate = () => child.kill('SIGTERM');
    const cleanup = () => {
      process.removeListener('SIGINT', interrupt);
      process.removeListener('SIGTERM', terminate);
    };
    process.on('SIGINT', interrupt);
    process.on('SIGTERM', terminate);
    child.once('error', (error) => {
      cleanup();
      reject(error);
    });
    child.once('close', (code, signal) => {
      cleanup();
      resolve(code ?? (signal === 'SIGINT' ? 130 : 1));
    });
  });
}
