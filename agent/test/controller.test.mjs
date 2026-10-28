import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { AgentController } from '../controller.mjs';
const connection = randomUUID();
const envelope = (tool, args = {}, client = connection) => ({
  version: 1,
  connection: client,
  request: randomUUID(),
  tool,
  args,
});
async function fixture(t) {
  const artifacts = await mkdtemp(path.join(os.tmpdir(), 'droiddock-agent-'));
  let identity = {};
  const controller = new AgentController({
    artifacts,
    identity: () => identity,
    list: async () => [{ id: 'phone' }],
    boot: async () => ({ state: 'running' }),
    status: async () => ({}),
    changed() {},
    stop() {},
  });
  t.after(async () => {
    controller.close();
    await rm(artifacts, { recursive: true, force: true });
  });
  await controller.call(envelope('handshake'));
  return {
    controller,
    restart: () => {
      identity = {};
    },
  };
}
test('grant requires in-app approval and is scoped to connection, device and runtime', async (t) => {
  const { controller, restart } = await fixture(t);
  const request = envelope('request_control', { device: 'phone', client: 'Codex' });
  assert.equal((await controller.call(request)).error, 'confirmation_required');
  await controller.call(request);
  assert.equal(controller.pending.size, 1);
  controller.approve([...controller.pending.keys()][0], []);
  const { handle } = await controller.call(request);
  assert.match(handle, /^[0-9a-f-]{36}$/);
  const second = randomUUID();
  await controller.call(envelope('handshake', {}, second));
  await assert.rejects(
    controller.call(envelope('request_control', { device: 'phone', client: 'Claude' }, second)),
    /device_busy/,
  );
  await assert.rejects(
    controller.call(envelope('release_control', { device: 'phone', handle: randomUUID() })),
    /grant/,
  );
  restart();
  await assert.rejects(
    controller.call(envelope('release_control', { device: 'phone', handle })),
    /grant/,
  );
  assert.equal(controller.grants.size, 0);
});
test('initialization, heartbeat expiry and disconnect have separate state', async (t) => {
  const { controller } = await fixture(t);
  assert.equal(controller.status().connected, 0);
  await controller.call(envelope('client_initialized'));
  assert.equal(controller.status().connected, 1);
  await controller.call(envelope('request_control', { device: 'phone', client: 'Agent' }));
  controller.connections.get(connection).seen = Date.now() - 46000;
  controller.expire();
  assert.equal(controller.pending.size, 0);
  assert.equal(controller.status().connected, 0);
  await assert.rejects(controller.call(envelope('heartbeat')), /expired/);
});
test('different phones may have independent controllers; revoke cancels only its operations', async (t) => {
  const { controller } = await fixture(t);
  for (const device of ['one', 'two']) {
    await controller.call(envelope('request_control', { device, client: 'Agent' }));
    controller.approve([...controller.pending.keys()][0], []);
  }
  const abortOne = new AbortController(),
    abortTwo = new AbortController();
  controller.active.set('one', { device: 'one', connection, abort: abortOne });
  controller.active.set('two', { device: 'two', connection, abort: abortTwo });
  controller.revoke('one');
  assert.equal(abortOne.signal.aborted, true);
  assert.equal(abortTwo.signal.aborted, false);
  assert.equal(controller.grants.size, 1);
  await controller.call(envelope('disconnect'));
  assert.equal(abortTwo.signal.aborted, true);
});
test('unsupported versions, unknown tools and malformed arguments fail closed', async (t) => {
  const { controller } = await fixture(t);
  await assert.rejects(controller.call({ ...envelope('list_devices'), version: 2 }));
  await assert.rejects(controller.call(envelope('host_shell')), /Unsupported/);
  await assert.rejects(controller.call(envelope('boot_device', {})), /device/);
  await assert.rejects(
    controller.call(envelope('list_devices', { serial: 'emulator-5554' })),
    /Unrecognized/,
  );
});
test('releasing a grant cancels the tracked operation and rejects its result', async (t) => {
  const { controller } = await fixture(t);
  await controller.call(envelope('request_control', { device: 'phone', client: 'Agent' }));
  controller.approve([...controller.pending.keys()][0], []);
  const handle = (
    await controller.call(envelope('request_control', { device: 'phone', client: 'Agent' }))
  ).handle;
  let entered;
  const started = new Promise((resolve) => {
    entered = resolve;
  });
  controller.backend.verify = async () => {};
  controller.backend.config = () => ({
    adb: 'fixture',
    serial: 'emulator-1',
    run: async (_exe, _argv, { signal }) => {
      entered();
      await new Promise((_resolve, reject) =>
        signal.addEventListener('abort', () => reject(new Error('cancelled')), { once: true }),
      );
    },
  });
  const operation = controller.call(
    envelope('android_shell', { device: 'phone', handle, args: ['sleep', '60'] }),
  );
  const rejection = assert.rejects(operation, /cancelled/);
  await started;
  await controller.call(envelope('release_control', { device: 'phone', handle }));
  await rejection;
  assert.equal(controller.active.size, 0);
});
test('shared cross-platform envelopes validate every public tool', async () => {
  const { readFile } = await import('node:fs/promises');
  const { validate, validateEnvelope } = await import('../contract.mjs');
  const fixtures = JSON.parse(
    await readFile(new URL('../fixtures/contract.json', import.meta.url), 'utf8'),
  );
  for (const request of fixtures.valid) {
    assert.doesNotThrow(() => validateEnvelope(request));
    assert.doesNotThrow(() => validate(request.tool, request.args));
  }
  for (const request of fixtures.invalid) assert.throws(() => validateEnvelope(request));
});
