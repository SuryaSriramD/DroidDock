import { mkdir, realpath, lstat, chmod, unlink, readdir, open } from 'node:fs/promises';
import path from 'node:path';
import { constants } from 'node:fs';
import { runProcess, requireSuccess } from '../desktop/src/core/process.mjs';
export async function privateDirectory(directory) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await lstat(directory);
  if (
    !info.isDirectory() ||
    info.isSymbolicLink() ||
    (process.getuid && info.uid !== process.getuid())
  )
    throw new Error('Unsafe agent directory.');
  if (process.platform === 'win32') {
    // Remove old explicit grants before replacing inherited permissions.
    const who = requireSuccess(
      await runProcess('whoami.exe', ['/user', '/fo', 'csv', '/nh']),
      'Identify current user',
    ).stdout;
    const sid = who.match(/S-1-5-[0-9-]+/i)?.[0];
    if (!sid) throw new Error('Could not identify Windows user for agent ACL.');
    requireSuccess(
      await runProcess('icacls.exe', [directory, '/reset']),
      'Reset agent directory ACL',
    );
    requireSuccess(
      await runProcess('icacls.exe', [
        directory,
        '/inheritance:r',
        '/grant:r',
        `*${sid}:(OI)(CI)F`,
      ]),
      'Protect agent directory',
    );
  } else await chmod(directory, 0o700);
}
export async function approvedPath(filename, roots, { destination = false } = {}) {
  if (typeof filename !== 'string' || !path.isAbsolute(filename) || filename.includes('\0'))
    throw new Error('An absolute host file path is required.');
  const canonicalRoots = await Promise.all(roots.map((root) => realpath(root)));
  const canonical = destination
    ? path.join(await realpath(path.dirname(filename)), path.basename(filename))
    : await realpath(filename);
  if (
    !canonicalRoots.some((root) => {
      const relative = path.relative(root, canonical);
      return (
        relative &&
        !relative.startsWith(`..${path.sep}`) &&
        relative !== '..' &&
        !path.isAbsolute(relative)
      );
    })
  )
    throw new Error('Host file is outside the folders approved in DroidDock.');
  if (!destination && !(await lstat(canonical)).isFile())
    throw new Error('Choose one regular file.');
  return canonical;
}
export async function consumeArtifact(directory, id) {
  if (!/^[0-9a-f-]{36}\.json$/.test(id)) throw new Error('Invalid artifact ID.');
  const filename = path.join(directory, id);
  const file = await open(filename, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  try {
    const info = await file.stat();
    const linkInfo = await lstat(filename);
    if (
      !info.isFile() ||
      linkInfo.isSymbolicLink() ||
      info.size > 24 * 1024 * 1024 ||
      (process.getuid && (info.uid !== process.getuid() || info.mode & 0o077))
    )
      throw new Error('Unsafe or oversized artifact.');
    return JSON.parse(await file.readFile('utf8'));
  } finally {
    await file.close();
    await unlink(filename);
  }
}
export async function cleanArtifacts(directory) {
  for (const name of await readdir(directory)) {
    if (!/^[0-9a-f-]{36}\.json$/.test(name)) continue;
    const filename = path.join(directory, name);
    const info = await lstat(filename);
    if (Date.now() - info.mtimeMs > 10 * 60_000) await unlink(filename);
  }
}
