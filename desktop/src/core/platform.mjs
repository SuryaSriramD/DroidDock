import os from 'node:os';
import path from 'node:path';

export function hostInfo(platform = process.platform, arch = process.arch) {
  if (!['win32', 'linux'].includes(platform) || arch !== 'x64') {
    throw new Error(
      'This preview supports Windows x64 and Linux x64. Use the native DroidDock app on macOS.',
    );
  }
  return { os: platform === 'win32' ? 'windows' : 'linux', arch: 'x64', abi: 'x86_64' };
}

function absolute(value, paths, label) {
  if (typeof value !== 'string' || !paths.isAbsolute(value) || /[\0\r\n]/.test(value)) {
    throw new Error(`${label} must be an absolute path.`);
  }
  if (paths === path.win32 && (!/^[a-z]:\\/i.test(value) || /[<>"|?*]/.test(value))) {
    throw new Error(`${label} must be a local Windows drive path.`);
  }
  return paths.normalize(value);
}

export function pathsFor({
  platform = process.platform,
  env = process.env,
  home = os.homedir(),
} = {}) {
  hostInfo(platform, 'x64');
  const p = platform === 'win32' ? path.win32 : path.posix;
  const user = absolute(home, p, 'Home');
  const base =
    platform === 'win32'
      ? absolute(env.LOCALAPPDATA || p.join(user, 'AppData', 'Local'), p, 'LOCALAPPDATA')
      : absolute(env.XDG_DATA_HOME || p.join(user, '.local', 'share'), p, 'XDG_DATA_HOME');
  const root = p.join(base, 'DroidDock', 'Android');
  return {
    platform,
    root,
    sdk: p.join(root, 'sdk'),
    avd: p.join(root, 'avd'),
    userHome: p.join(root, 'user-home'),
    terminal: p.join(root, 'terminal'),
  };
}

export function sdkExecutables(paths, platform = paths.platform ?? process.platform) {
  hostInfo(platform, 'x64');
  const p = platform === 'win32' ? path.win32 : path.posix;
  const suffix = platform === 'win32' ? '.exe' : '';
  return {
    adb: p.join(paths.sdk, 'platform-tools', `adb${suffix}`),
    emulator: p.join(paths.sdk, 'emulator', `emulator${suffix}`),
  };
}

// An explicit environment makes tests and callers independent of the current shell.
export function sdkEnvironment(paths, env = process.env) {
  const platform = paths.platform ?? process.platform;
  hostInfo(platform, 'x64');
  const p = platform === 'win32' ? path.win32 : path.posix;
  const result = { ...env };
  const pathKeys = Object.keys(result).filter((key) =>
    platform === 'win32' ? key.toLowerCase() === 'path' : key === 'PATH',
  );
  const oldPath = pathKeys
    .map((key) => result[key])
    .filter(Boolean)
    .join(p.delimiter);
  for (const key of pathKeys) delete result[key];
  if (platform === 'win32') {
    const androidKeys = new Set([
      'android_home',
      'android_sdk_root',
      'android_sdk_home',
      'android_avd_home',
      'android_user_home',
      'android_emulator_home',
    ]);
    for (const key of Object.keys(result))
      if (androidKeys.has(key.toLowerCase())) delete result[key];
  }
  const prefixes = [p.join(paths.sdk, 'platform-tools'), p.join(paths.sdk, 'emulator')];
  const seen = new Set();
  const entries = [...prefixes, ...oldPath.split(p.delimiter)].filter((entry) => {
    if (!entry) return false;
    const key = platform === 'win32' ? entry.toLowerCase().replace(/[\\/]+$/, '') : entry;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  return {
    ...result,
    ANDROID_HOME: paths.sdk,
    ANDROID_SDK_ROOT: paths.sdk,
    ANDROID_SDK_HOME: paths.root,
    ANDROID_AVD_HOME: paths.avd,
    ANDROID_USER_HOME: paths.userHome,
    ANDROID_EMULATOR_HOME: paths.userHome,
    PATH: entries.join(p.delimiter),
  };
}
