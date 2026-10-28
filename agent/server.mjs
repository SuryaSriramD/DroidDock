import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { tools, VERSION } from './contract.mjs';
import { consumeArtifact } from './security.mjs';
import { sendCommand } from '../desktop/src/core/commands.mjs';
import { delay } from '../desktop/src/core/process.mjs';
export async function runServer(call, { selfTest = false, onClose = () => {} } = {}) {
  const connection = randomUUID();
  const envelope = (tool, args = {}) => ({
    version: VERSION,
    connection,
    request: randomUUID(),
    tool,
    args,
  });
  const hello = await call(envelope('handshake', { selfTest })).catch((error) => {
    throw new Error(
      'DroidDock agent connection failed. Update the app and reconnect through Agent Setup. ' +
        error.message,
    );
  });
  if (hello.version !== VERSION || !hello.artifacts)
    throw new Error('DroidDock agent protocol is unavailable. Update the app and reconnect.');
  const server = new McpServer({ name: 'droiddock', version: '1.0.0' });
  server.server.oninitialized = () => {
    void call(envelope('client_initialized')).catch(() => {});
  };
  let closing;
  const finish = () =>
    (closing ??= (async () => {
      clearInterval(heartbeat);
      await call(envelope('disconnect')).catch(() => {});
      try {
        await server.close();
      } finally {
        onClose();
      }
    })());
  for (const [name, tool] of Object.entries(tools)) {
    server.registerTool(
      name,
      { description: tool.description, inputSchema: tool.shape },
      async (args, extra) => {
        const request = envelope(name, args);
        const cancel = () => {
          void call(envelope('cancel', { request: request.request })).catch(() => {});
        };
        extra.signal.addEventListener('abort', cancel, { once: true });
        try {
          let result = await call(request);
          if (result.artifact) result = await consumeArtifact(hello.artifacts, result.artifact);
          const { image, ...metadata } = result;
          return {
            content: [
              ...(image ? [{ type: 'image', mimeType: 'image/png', data: image }] : []),
              { type: 'text', text: JSON.stringify(metadata) },
            ],
            isError: Boolean(result.error),
          };
        } catch (error) {
          return {
            content: [
              {
                type: 'text',
                text: JSON.stringify({
                  error: error.message,
                  completionUncertain: ![
                    'list_devices',
                    'device_status',
                    'inspect_device',
                    'read_logs',
                    'wait_for_element',
                    'request_control',
                  ].includes(name),
                }),
              },
            ],
            isError: true,
          };
        } finally {
          extra.signal.removeEventListener('abort', cancel);
        }
      },
    );
  }
  const heartbeat = setInterval(() => {
    void call(envelope('heartbeat')).catch((error) => {
      process.stderr.write(`DroidDock heartbeat: ${error.message}\n`);
    });
  }, 15000);
  heartbeat.unref();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  server.server.onclose = () => {
    void finish();
  };
  process.stdin.once('end', () => {
    void finish();
  });
  process.once('SIGINT', () => {
    void finish().finally(() => process.exit(0));
  });
  process.once('SIGTERM', () => {
    void finish().finally(() => process.exit(0));
  });
  return server;
}
export function desktopCall(directory, executable, launchArgs = []) {
  return async (request) => {
    const args = ['agent-call', JSON.stringify(request)];
    try {
      return await sendCommand(directory, args);
    } catch (error) {
      if (request.tool !== 'handshake' || !['ENOENT', 'ECONNREFUSED'].includes(error.code))
        throw error;
    }
    const env = { ...process.env };
    delete env.ELECTRON_RUN_AS_NODE;
    const child = spawn(executable, launchArgs, {
      detached: true,
      stdio: 'ignore',
      env,
      windowsHide: true,
    });
    child.on('error', (error) => process.stderr.write(error.message + '\n'));
    child.unref();
    for (let attempt = 0; attempt < 100; attempt++) {
      await delay(200);
      try {
        return await sendCommand(directory, args);
      } catch (error) {
        if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) throw error;
      }
    }
    throw new Error('DroidDock did not open. Open the app and reconnect.');
  };
}
export function nativeCall(executable, application) {
  return async (request) =>
    new Promise((resolve, reject) => {
      const child = spawn(executable, ['agent-call', '--json', '--app', application], {
        shell: false,
        windowsHide: true,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      let output = '',
        stderr = '',
        bytes = 0;
      const timer = setTimeout(() => {
        child.kill();
        reject(new Error('Agent transport timed out; mutation completion may be uncertain.'));
      }, 240000);
      child.stdout.on('data', (data) => {
        bytes += data.length;
        if (bytes > 128 * 1024) child.kill();
        else output += data;
      });
      child.stderr.on('data', (data) => {
        stderr = (stderr + data).slice(-4096);
      });
      child.stdin.on('error', reject);
      child.on('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.on('close', (code) => {
        clearTimeout(timer);
        try {
          const response = JSON.parse(output);
          if (!response.success)
            throw new Error(response.message || stderr || 'Agent request failed.');
          resolve(JSON.parse(response.message));
        } catch (error) {
          reject(new Error(code ? stderr || error.message : error.message));
        }
      });
      child.stdin.end(JSON.stringify(request));
    });
}
if (process.argv[2] === '--native') {
  await runServer(nativeCall(process.argv[3], process.argv[4]), {
    selfTest: process.argv.includes('--self-test'),
  }).catch((error) => {
    process.stderr.write(error.message + '\n');
    process.exitCode = 1;
  });
}

if (process.argv[2] === '--desktop') {
  await runServer(desktopCall(process.argv[3], process.argv[4], JSON.parse(process.argv[5])), {
    selfTest: process.argv.includes('--self-test'),
  }).catch((error) => {
    process.stderr.write(error.message + '\n');
    process.exitCode = 1;
  });
}
