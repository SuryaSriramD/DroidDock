import { executeOperation, artifactResult } from './operations.mjs';
const abort = new AbortController();
process.once('SIGTERM', () => abort.abort());
process.once('SIGINT', () => abort.abort());
try {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 4 * 1024 * 1024) throw new Error('Agent worker input too large.');
    chunks.push(chunk);
  }
  const { config, tool, args, inspection } = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  const result = await executeOperation(config, tool, args, { signal: abort.signal, inspection });
  process.stdout.write(JSON.stringify(await artifactResult(config.artifacts, result)));
} catch (error) {
  process.stderr.write(error.message + '\n');
  process.exitCode = 1;
}
