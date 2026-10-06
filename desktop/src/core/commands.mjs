import http from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, writeFile, rename, unlink } from 'node:fs/promises';
import path from 'node:path';

const MAX_BODY = 64 * 1024;
const equal = (a, b) =>
  typeof a === 'string' &&
  Buffer.byteLength(a) === Buffer.byteLength(b) &&
  timingSafeEqual(Buffer.from(a), Buffer.from(b));
export function parseCommand(args) {
  const json = args.includes('--json');
  args = args.filter((value) => value !== '--json');
  const [command, id, value, ...extra] = args;
  if (!command || ['--help', '-h', 'help'].includes(command)) return { command: 'help', json };
  if (!['list', 'boot', 'stop', 'status', 'install', 'open-url', 'repair-adb'].includes(command))
    throw new Error(`Unknown command: ${command}`);
  if (!['list', 'repair-adb'].includes(command) && (!id || !/^[A-Za-z0-9_-]{1,120}$/.test(id)))
    throw new Error('Provide a phone ID from droiddock list.');
  const needsValue = ['install', 'open-url'].includes(command);
  if (
    (needsValue && !value) ||
    (!needsValue && value) ||
    extra.length ||
    (['list', 'repair-adb'].includes(command) && id)
  )
    throw new Error('Unexpected or missing arguments. Run droiddock --help.');
  if (command === 'install' && !path.isAbsolute(value))
    throw new Error('Use an absolute path to the APK.');
  if (command === 'open-url') {
    const url = new URL(value);
    if (!['http:', 'https:', 'exp:', 'exps:'].includes(url.protocol))
      throw new Error('Use an http, https, exp or exps URL.');
  }
  return { command, id, value, json };
}
export const HELP = `DroidDock — Windows/Linux preview\n\n  droiddock list [--json]\n  droiddock boot PHONE_ID\n  droiddock status PHONE_ID [--json]\n  droiddock stop PHONE_ID\n  droiddock install PHONE_ID /absolute/path/app.apk\n  droiddock open-url PHONE_ID https://example.com\n  droiddock expo PHONE_ID [--port PORT]\n  droiddock repair-adb\n\nRun expo from your project after installing its dependencies. It boots the phone,\nuses bundled Node, and starts Expo Go with IPv4 localhost. Ctrl+C stops Metro.\nrepair-adb restarts the local Android connection server; other Android tools\nusing that server reconnect too. Android devices and their data are kept.\n`;

export async function startCommandServer({ directory, dispatch }) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const token = randomBytes(32).toString('hex');
  const endpoint = path.join(directory, 'endpoint.json');
  const server = http.createServer(async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    const reject = (code) => {
      res.writeHead(code);
      res.end(JSON.stringify({ error: 'Command rejected.' }));
    };
    if (
      req.method !== 'POST' ||
      req.url !== '/command' ||
      req.headers.origin ||
      !equal(req.headers.authorization, `Bearer ${token}`)
    )
      return reject(403);
    let length = 0,
      body = [];
    try {
      for await (const chunk of req) {
        length += chunk.length;
        if (length > MAX_BODY) {
          reject(413);
          req.destroy();
          return;
        }
        body.push(chunk);
      }
      const message = JSON.parse(Buffer.concat(body).toString('utf8'));
      if (
        !Array.isArray(message.args) ||
        message.args.length > 8 ||
        !message.args.every((arg) => typeof arg === 'string' && arg.length <= 16000)
      )
        return reject(400);
      const command = parseCommand(message.args);
      const result = await dispatch(command);
      res.end(JSON.stringify({ result }));
    } catch (error) {
      if (!res.writableEnded) {
        res.writeHead(400);
        res.end(JSON.stringify({ error: error.message }));
      }
    }
  });
  server.requestTimeout = 10_000;
  server.headersTimeout = 10_000;
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  const staging = `${endpoint}.${process.pid}.tmp`;
  await writeFile(staging, JSON.stringify({ port, token }), { mode: 0o600, flag: 'wx' });
  await rename(staging, endpoint);
  return async () => {
    try {
      if (JSON.parse(await readFile(endpoint, 'utf8')).token === token) await unlink(endpoint);
    } catch {}
    await new Promise((resolve) => server.close(resolve));
  };
}

export async function sendCommand(directory, args) {
  const { port, token } = JSON.parse(await readFile(path.join(directory, 'endpoint.json'), 'utf8'));
  if (!Number.isInteger(port) || port < 1024 || port > 65535 || !/^[a-f0-9]{64}$/.test(token))
    throw new Error('Invalid DroidDock command endpoint.');
  return await new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: '127.0.0.1',
        port,
        path: '/command',
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      },
      (res) => {
        let body = '',
          bytes = 0;
        res.on('data', (chunk) => {
          bytes += chunk.length;
          if (bytes > MAX_BODY * 4) req.destroy(new Error('Response too large.'));
          else body += chunk;
        });
        res.on('end', () => {
          try {
            const message = JSON.parse(body);
            if (message.error) reject(new Error(message.error));
            else resolve(message.result);
          } catch (error) {
            reject(error);
          }
        });
      },
    );
    req.setTimeout(360_000, () =>
      req.destroy(new Error('DroidDock command timed out. Open the app to check its status.')),
    );
    req.on('error', reject);
    req.end(JSON.stringify({ args }));
  });
}
