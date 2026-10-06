import { spawn } from 'node:child_process';

export function abortError() {
  return new DOMException('The operation was cancelled.', 'AbortError');
}
export function checkAbort(signal) {
  if (signal?.aborted) throw abortError();
}
export function delay(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(abortError());
    const finish = (error) => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', cancel);
      error ? reject(error) : resolve();
    };
    const cancel = () => finish(abortError());
    const timer = setTimeout(() => finish(), ms);
    signal?.addEventListener('abort', cancel, { once: true });
  });
}

/** No shell, bounded output, exact-child timeout/cancellation. Nonzero exits are returned. */
export function runProcess(
  executable,
  args,
  {
    env = process.env,
    signal,
    timeout = 30_000,
    maxBytes = 1024 * 1024,
    spawnProcess = spawn,
  } = {},
) {
  return new Promise((resolve, reject) => {
    try {
      checkAbort(signal);
    } catch (error) {
      reject(error);
      return;
    }
    let child,
      timer,
      fallback,
      finished = false,
      failure,
      bytes = 0;
    const stdout = [],
      stderr = [];
    const finish = (error, code, exitSignal) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      clearTimeout(fallback);
      signal?.removeEventListener('abort', cancel);
      if (error || failure) reject(error || failure);
      else
        resolve({
          stdout: Buffer.concat(stdout).toString('utf8'),
          stderr: Buffer.concat(stderr).toString('utf8'),
          code,
          signal: exitSignal,
        });
    };
    const fail = (error) => {
      if (finished || failure) return;
      failure = error;
      try {
        child?.kill('SIGKILL');
      } catch {
        /* The exact child may already have exited. */
      }
      fallback = setTimeout(() => finish(error), 2000);
    };
    const cancel = () => fail(abortError());
    try {
      child = spawnProcess(executable, args, {
        env,
        shell: false,
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      for (const [stream, output] of [
        [child.stdout, stdout],
        [child.stderr, stderr],
      ]) {
        stream?.on('data', (data) => {
          if (finished || failure) return;
          bytes += data.length;
          if (bytes > maxBytes) {
            fail(new Error('Command output exceeded its safety limit.'));
            return;
          }
          output.push(Buffer.from(data));
        });
      }
      child.once('error', (error) => finish(error));
      child.once('close', (code, exitSignal) => finish(null, code, exitSignal));
      timer = setTimeout(
        () => fail(new Error(`Command timed out after ${Math.ceil(timeout / 1000)} seconds.`)),
        timeout,
      );
      signal?.addEventListener('abort', cancel, { once: true });
      if (signal?.aborted) cancel();
    } catch (error) {
      finish(error);
    }
  });
}

export function requireSuccess(result, operation) {
  if (result.code !== 0)
    throw new Error(
      `${operation} failed (${result.code ?? result.signal ?? 'unknown'}). ${(result.stderr || result.stdout || '').trim().slice(-4096)}`,
    );
  return result;
}

export function shellArguments(tokens) {
  return ['shell', tokens.map((token) => `'${String(token).replaceAll("'", "'\\''")}'`).join(' ')];
}
