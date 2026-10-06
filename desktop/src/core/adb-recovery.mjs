import path from 'node:path';
import { readFile, readdir, readlink, realpath, stat } from 'node:fs/promises';
import { runProcess, requireSuccess, delay } from './process.mjs';

export function adbServerPort(env) {
  let port = env.ANDROID_ADB_SERVER_PORT || '5037';
  if (
    env.ANDROID_ADB_SERVER_ADDRESS &&
    !['127.0.0.1', 'localhost', '::1'].includes(env.ANDROID_ADB_SERVER_ADDRESS)
  )
    throw new Error('ADB repair supports local servers only.');
  if (env.ADB_SERVER_SOCKET) {
    const match = /^tcp:(?:127\.0\.0\.1:|localhost:|\[::1\]:)?(\d+)$/.exec(env.ADB_SERVER_SOCKET);
    if (!match) throw new Error('ADB repair supports a local TCP server only.');
    port = match[1];
  }
  if (!/^\d+$/.test(String(port)) || Number(port) < 1024 || Number(port) > 65535)
    throw new Error('Invalid local ADB server port.');
  return Number(port);
}

export async function stopOwnedAdbServer({
  adb,
  port,
  env,
  platform = process.platform,
  run = runProcess,
}) {
  const expected = await realpath(adb);
  if (platform === 'win32') {
    const config = Buffer.from(JSON.stringify({ expected, port })).toString('base64');
    const source = `$ErrorActionPreference='Stop'; $cfg=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${config}'))|ConvertFrom-Json; $owners=@(Get-NetTCPConnection -LocalPort $cfg.port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique); foreach($owner in $owners) { $before=Get-CimInstance Win32_Process -Filter "ProcessId = $owner"; if (!$before -or $before.ExecutablePath -ine $cfg.expected -or $before.CommandLine -notmatch 'fork-server server') { throw 'The unresponsive ADB server belongs to other Android tools. Restart it there; DroidDock did not terminate it.' }; $again=Get-CimInstance Win32_Process -Filter "ProcessId = $owner"; if (!$again -or $again.CreationDate -ne $before.CreationDate -or $again.ExecutablePath -ine $cfg.expected) { throw 'ADB server identity changed; retry repair.' }; Stop-Process -Id $owner -Force -ErrorAction Stop }`;
    requireSuccess(
      await run(
        path.win32.join(
          env.SystemRoot || env.SYSTEMROOT || 'C:\\Windows',
          'System32/WindowsPowerShell/v1.0/powershell.exe',
        ),
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          Buffer.from(source, 'utf16le').toString('base64'),
        ],
        { env, timeout: 15000 },
      ),
      'Recover the owned ADB server',
    );
    return;
  }
  if (platform !== 'linux') throw new Error('ADB repair is supported on Windows and Linux.');
  const inodes = new Set();
  for (const table of ['/proc/net/tcp', '/proc/net/tcp6']) {
    const content = await readFile(table, 'utf8').catch(() => '');
    for (const line of content.split('\n').slice(1)) {
      const fields = line.trim().split(/\s+/);
      if (fields[3] === '0A' && Number.parseInt(fields[1]?.split(':').at(-1), 16) === port)
        inodes.add(fields[9]);
    }
  }
  if (!inodes.size) return;
  const identity = async (pid) => {
    const root = `/proc/${pid}`;
    const executable = await readlink(`${root}/exe`);
    const info = await stat(root);
    const processStat = await readFile(`${root}/stat`, 'utf8');
    const started = processStat.slice(processStat.lastIndexOf(')') + 2).split(' ')[19];
    const command = (await readFile(`${root}/cmdline`, 'utf8')).replaceAll('\0', ' ');
    return { root, executable, uid: info.uid, started, command };
  };
  let found = false;
  for (const pid of (await readdir('/proc')).filter((name) => /^\d+$/.test(name))) {
    const before = await identity(pid).catch(() => null);
    if (
      !before ||
      before.executable !== expected ||
      before.uid !== process.getuid() ||
      !before.command.includes('fork-server server')
    )
      continue;
    const fds = await readdir(`${before.root}/fd`).catch(() => []);
    let ownsSocket = false;
    for (const fd of fds) {
      const link = await readlink(`${before.root}/fd/${fd}`).catch(() => '');
      if (inodes.has(/^socket:\[(\d+)\]$/.exec(link)?.[1])) ownsSocket = true;
    }
    if (!ownsSocket) continue;
    const after = await identity(pid);
    if (
      after.started !== before.started ||
      after.executable !== expected ||
      after.uid !== before.uid
    )
      throw new Error('ADB server identity changed; retry repair.');
    process.kill(Number(pid), 'SIGKILL');
    found = true;
  }
  if (!found)
    throw new Error(
      'The unresponsive ADB server belongs to other Android tools. Restart it there; DroidDock did not terminate it.',
    );
}

/** Explicit user repair only: never restart a shared server during routine commands. */
export async function repairAdb({
  adb,
  env = process.env,
  platform = process.platform,
  run = runProcess,
  forceStop = stopOwnedAdbServer,
  wait = delay,
}) {
  const port = adbServerPort(env);
  try {
    requireSuccess(
      await run(adb, ['kill-server'], { env, timeout: 3000 }),
      'Restart Android connection',
    );
  } catch {
    await forceStop({ adb, port, env, platform, run });
  }
  requireSuccess(
    await run(adb, ['start-server'], { env, timeout: 10000 }),
    'Start Android connection',
  );
  let lastError;
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const result = requireSuccess(
        await run(adb, ['devices', '-l'], { env, timeout: 3000 }),
        'Verify Android connection',
      );
      if (!/\toffline\b/.test(result.stdout))
        return {
          message: 'Android connection repaired. Reconnect any phone displays that were open.',
        };
      lastError = new Error(
        'Android is still reconnecting. Retry opening the phone in a few seconds.',
      );
    } catch (error) {
      lastError = error;
    }
    await wait(500);
  }
  throw lastError;
}
