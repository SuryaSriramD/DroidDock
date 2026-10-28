const { runServer } = await import(process.env.DROIDDOCK_TEST_SERVER_MODULE || '../../server.mjs');
import os from 'node:os';
await runServer(async (request) => {
  if (request.tool === 'handshake') return { version: 1, artifacts: os.tmpdir() };
  if (request.tool === 'list_devices') return { devices: [{ id: 'fixture-phone' }] };
  if (request.tool === 'inspect_device') return { image: 'iVBORw0KGgo=', width: 1, height: 1 };
  return { success: true };
});
