import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { parseCommand, startCommandServer, sendCommand } from '../src/core/commands.mjs';
test('CLI accepts typed device commands and rejects shell-like or extra arguments', () => {
  assert.equal(parseCommand(['list', '--json']).json, true);
  assert.equal(parseCommand(['boot', 'DroidDock_API_36']).id, 'DroidDock_API_36');
  for (const args of [
    ['boot', '../../x'],
    ['list', 'x'],
    ['exec', 'whoami'],
    ['stop', 'x', 'y'],
    ['open-url', 'x', 'file:///etc/passwd'],
    ['install', 'x', 'relative.apk'],
  ])
    assert.throws(() => parseCommand(args));
});
test('command server binds locally, authenticates, and cleans up its endpoint', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'droiddock-command-'));
  let close;
  try {
    close = await startCommandServer({
      directory,
      dispatch: async (command) => ({ id: command.id ?? 'list' }),
    });
    assert.deepEqual(await sendCommand(directory, ['boot', 'phone']), { id: 'phone' });
    const { port } = JSON.parse(await readFile(path.join(directory, 'endpoint.json'), 'utf8'));
    const code = await new Promise((resolve, reject) => {
      const req = http.request(
        { host: '127.0.0.1', port, path: '/command', method: 'POST' },
        (res) => {
          res.resume();
          resolve(res.statusCode);
        },
      );
      req.on('error', reject);
      req.end('{}');
    });
    assert.equal(code, 403);
    await close();
    close = null;
    await assert.rejects(readFile(path.join(directory, 'endpoint.json')));
  } finally {
    if (close) await close();
    await rm(directory, { recursive: true, force: true });
  }
});
