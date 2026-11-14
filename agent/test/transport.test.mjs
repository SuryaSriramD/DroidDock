import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import os from 'node:os';
import { AgentController } from '../controller.mjs';
import { desktopCall } from '../server.mjs';
import { startCommandServer, sendCommand } from '../../desktop/src/core/commands.mjs';

test('agent envelopes traverse the authenticated app transport and retain grant checks', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'droiddock-agent-transport-'));
  const agent = new AgentController({
    artifacts: path.join(directory, 'artifacts'),
    list: async () => [{ id: 'phone', state: 'idle' }],
    identity: () => ({}),
  });
  const close = await startCommandServer({
    directory: path.join(directory, 'commands'),
    dispatch: (command) => {
      assert.equal(command.command, 'agent-call');
      return agent.call(command.envelope);
    },
  });
  const connection = randomUUID();
  const transport = desktopCall(path.join(directory, 'commands'));
  const call = (tool, args = {}, version = 1) =>
    transport({ version, connection, request: randomUUID(), tool, args });
  try {
    assert.equal((await call('handshake')).version, 1);
    assert.deepEqual((await call('list_devices')).devices, [{ id: 'phone', state: 'idle' }]);
    await assert.rejects(
      call('android_shell', { device: 'phone', handle: randomUUID(), args: ['id'] }),
      /grant/,
    );
    await assert.rejects(call('list_devices', {}, 2));
  } finally {
    agent.close();
    const endpoint = path.join(directory, 'commands/endpoint.json');
    const staleEndpoint = await readFile(endpoint);
    await close();
    for (const tool of ['handshake', 'heartbeat', 'disconnect', 'list_devices']) {
      await assert.rejects(call(tool), /DroidDock is closed\. Open it and reconnect/);
    }
    await writeFile(endpoint, staleEndpoint, { mode: 0o600 });
    await assert.rejects(call('handshake'), /DroidDock is closed\. Open it and reconnect/);
    await rm(directory, { recursive: true, force: true });
  }
});
