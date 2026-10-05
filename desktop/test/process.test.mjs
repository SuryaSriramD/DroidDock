import test from 'node:test';
import assert from 'node:assert/strict';
import { runProcess } from '../src/core/process.mjs';

test('process runner returns bounded UTF-8 output and nonzero status without a shell', async () => {
  const result = await runProcess(
    process.execPath,
    [
      '-e',
      'process.stdout.write(process.env.DROIDDOCK_TEST);process.stderr.write("error");process.exitCode=7',
    ],
    { env: { ...process.env, DROIDDOCK_TEST: 'selected SDK' } },
  );
  assert.equal(result.code, 7);
  assert.equal(result.stdout, 'selected SDK');
  assert.equal(result.stderr, 'error');
});
test('process output limit terminates the exact fixture child', async () => {
  await assert.rejects(
    runProcess(
      process.execPath,
      ['-e', 'process.stdout.write("x".repeat(2048));setInterval(()=>{},1000)'],
      { maxBytes: 1024 },
    ),
    /output exceeded/,
  );
});
test('process cancellation and timeout do not wait indefinitely for children', async () => {
  const controller = new AbortController();
  const pending = runProcess(process.execPath, ['-e', 'setInterval(()=>{},1000)'], {
    signal: controller.signal,
  });
  const rejected = assert.rejects(pending, { name: 'AbortError' });
  controller.abort();
  await rejected;
  await assert.rejects(
    runProcess(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { timeout: 30 }),
    /timed out/,
  );
});
