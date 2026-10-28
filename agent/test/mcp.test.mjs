import test from 'node:test';
import assert from 'node:assert/strict';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { testServer } from '../self-test.mjs';
const fixture = fileURLToPath(new URL('./fixtures/server.mjs', import.meta.url));
test('real SDK stdio initialization, tools, image content, validation and EOF shutdown', async () => {
  const client = new Client({ name: 'test', version: '1' });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fixture],
    stderr: 'pipe',
  });
  try {
    await client.connect(transport);
    assert.equal((await client.listTools()).tools.length, 16);
    const devices = await client.callTool({ name: 'list_devices', arguments: {} });
    assert.equal(JSON.parse(devices.content[0].text).devices[0].id, 'fixture-phone');
    const image = await client.callTool({
      name: 'inspect_device',
      arguments: { device: 'phone', handle: randomUUID() },
    });
    assert.equal(image.content[0].type, 'image');
    const invalid = await client.callTool({ name: 'tap', arguments: { device: 'phone' } });
    assert.equal(invalid.isError, true);
  } finally {
    await client.close();
  }
});
test('packaged-compatible self-test exercises actual stdio discovery and listing', async () => {
  assert.equal((await testServer(process.execPath, [fixture])).success, true);
});
test('closing stdin exits cleanly without polluting stdout', async () => {
  const { spawn } = await import('node:child_process');
  const child = spawn(process.execPath, [fixture], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '',
    stderr = '';
  child.stderr.on('data', (data) => {
    stderr += data;
  });
  child.stdout.on('data', (data) => {
    output += data;
    if (output.includes('\n')) child.stdin.end();
  });
  const exit = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', (code) => resolve(code));
  });
  child.stdin.write(
    JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2025-03-26',
        capabilities: {},
        clientInfo: { name: 'eof-test', version: '1' },
      },
    }) + '\n',
  );
  const timer = setTimeout(() => child.kill('SIGKILL'), 3000);
  try {
    assert.equal(await exit, 0, stderr);
    const response = JSON.parse(output.trim());
    assert.equal(response.jsonrpc, '2.0');
    assert.equal(response.result.serverInfo.name, 'droiddock');
  } finally {
    clearTimeout(timer);
    child.kill();
  }
});
