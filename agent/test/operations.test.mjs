import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, writeFile, symlink, rm, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { executeOperation, parseHierarchy, uniqueMatch, artifactResult } from '../operations.mjs';
import { approvedPath, consumeArtifact } from '../security.mjs';
import { runProcess } from '../../desktop/src/core/process.mjs';
const args = { device: 'phone', handle: randomUUID() };
const xml =
  '<?xml version="1.0"?><hierarchy><node text="Tap" resource-id="button" content-desc="Touch" enabled="true" bounds="[10,20][50,80]"/></hierarchy>';
const png = Buffer.alloc(24);
Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(png);
png.writeUInt32BE(100, 16);
png.writeUInt32BE(200, 20);
const result = (stdout) => ({ stdout, stderr: '', code: 0 });
function fixture() {
  const calls = [];
  const config = {
    adb: '/fixture/adb',
    serial: 'emulator-5554',
    roots: [],
    run: async (_exe, argv) => {
      calls.push(argv);
      assert.deepEqual(argv.slice(0, 2), ['-s', 'emulator-5554']);
      if (argv.at(-1).includes('dumpsys')) return result('SurfaceOrientation: 0');
      if (argv.includes('screencap')) return result(png);
      if (argv.at(-1).includes("'cat'")) return result(xml);
      return result('');
    },
  };
  return { config, calls };
}
test('inspection returns PNG, native dimensions and hierarchy; latest node reference taps its center', async () => {
  const { config, calls } = fixture();
  const snapshot = await executeOperation(config, 'inspect_device', args);
  assert.equal(snapshot.width, 100);
  assert.equal(snapshot.height, 200);
  assert.equal(snapshot.nodes[0].text, 'Tap');
  assert.equal(snapshot.image, png.toString('base64'));
  await executeOperation(
    config,
    'tap',
    { ...args, inspection: snapshot.id, node: 0 },
    { inspection: snapshot },
  );
  assert.match(calls.at(-1).at(-1), /'tap' '30' '50'/);
  await assert.rejects(
    executeOperation(
      config,
      'tap',
      { ...args, inspection: randomUUID(), node: 0 },
      { inspection: snapshot },
    ),
    /Stale/,
  );
  await assert.rejects(
    executeOperation(config, 'swipe', { ...args, x: 0, y: 0, endX: 100, endY: 0 }),
    /inside/,
  );
});
test('image-only fallback, ambiguous selectors, malicious XML and Unicode paste', async () => {
  const { config } = fixture();
  const original = config.run;
  config.run = async (exe, argv) => {
    if (argv.at(-1).includes('uiautomator')) throw new Error('Hierarchy unavailable');
    return original(exe, argv);
  };
  const image = await executeOperation(config, 'inspect_device', args);
  assert.ok(image.image);
  const screenshotOnly = {
    ...config,
    run: async (exe, argv) => {
      if (argv.at(-1).includes('dumpsys')) throw new Error('Orientation unavailable');
      return config.run(exe, argv);
    },
  };
  const unknownRotation = await executeOperation(screenshotOnly, 'inspect_device', args);
  assert.ok(unknownRotation.image);
  assert.equal(unknownRotation.rotation, null);
  assert.match(image.hierarchyError, /unavailable/);
  assert.throws(() => parseHierarchy('<!DOCTYPE x [<!ENTITY a "b">]><hierarchy/>'), /Invalid/);
  assert.throws(
    () =>
      uniqueMatch([...parseHierarchy(xml), ...parseHierarchy(xml)], {
        attribute: 'text',
        value: 'Tap',
      }),
    /Ambiguous/,
  );
  const text = 'हैलो 🌍 café \' " $()';
  let sent;
  const response = await executeOperation(
    config,
    'type_text',
    { ...args, text },
    {
      input: (action) => {
        sent = action;
      },
    },
  );
  assert.deepEqual(sent, { type: 'clipboard', text });
  assert.equal(response.guestClipboardReplaced, true);
});
test('guest shell preserves argument quoting and nonzero status', async () => {
  const { config, calls } = fixture();
  config.run = async (_exe, argv) => {
    calls.push(argv);
    return { code: 7, stdout: 'out', stderr: 'error' };
  };
  const response = await executeOperation(config, 'android_shell', {
    ...args,
    args: ['printf', "a'b", '$(host)'],
  });
  assert.equal(response.code, 7);
  assert.equal(response.stderr, 'error');
  assert.match(calls[0].at(-1), /a'\\''b/);
  assert.match(calls[0].at(-1), /'\$\(host\)'/);
});
test('approved host roots reject escapes and artifacts are single use', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'droiddock-security-'));
  const outside = await mkdtemp(path.join(os.tmpdir(), 'droiddock-outside-'));
  t.after(async () => {
    await rm(directory, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  });
  await writeFile(path.join(outside, 'secret'), 'private');
  await symlink(
    outside,
    path.join(directory, 'escape'),
    process.platform === 'win32' ? 'junction' : 'dir',
  );
  await assert.rejects(
    approvedPath(path.join(directory, 'escape', 'secret'), [directory]),
    /outside/,
  );
  await assert.rejects(
    approvedPath(path.join(directory, 'escape', 'new'), [directory], { destination: true }),
    /outside/,
  );
  const { artifact } = await artifactResult(directory, { image: 'png', nodes: [] });
  assert.deepEqual(await consumeArtifact(directory, artifact), { image: 'png', nodes: [] });
  await assert.rejects(consumeArtifact(directory, artifact));
  await assert.rejects(consumeArtifact(directory, '../secret'));
});
test('process runner supports binary capture, stdin, truncation and cancellation', async () => {
  const binary = await runProcess(process.execPath, ['-e', 'process.stdin.pipe(process.stdout)'], {
    input: Buffer.from([0, 255, 1]),
    encoding: null,
  });
  assert.deepEqual(binary.stdout, Buffer.from([0, 255, 1]));
  const truncated = await runProcess(
    process.execPath,
    ['-e', 'process.stdout.write("x".repeat(10000))'],
    { maxBytes: 100, truncateOutput: true },
  );
  assert.equal(truncated.stdout.length, 100);
  assert.equal(truncated.truncated, true);
  await assert.rejects(
    runProcess(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { timeout: 25 }),
    /timed out/,
  );
});
test('pull refuses existing destinations and never writes outside approved roots', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'droiddock-transfer-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const target = path.join(root, 'download.txt');
  const config = {
    adb: 'fixture',
    serial: 'emulator-1',
    roots: [root],
    run: async (_exe, argv) => result(argv.includes('exec-out') ? Buffer.from('data') : '4'),
  };
  const request = { ...args, direction: 'pull', hostPath: target, guestPath: '/sdcard/file.txt' };
  await executeOperation(config, 'transfer_file', request);
  assert.equal(await readFile(target, 'utf8'), 'data');
  await assert.rejects(executeOperation(config, 'transfer_file', request), /EEXIST/);
  assert.equal(await readFile(target, 'utf8'), 'data');
  await assert.rejects(
    executeOperation(config, 'transfer_file', {
      ...request,
      hostPath: path.join(root, '..', 'escape.txt'),
    }),
    /outside/,
  );
});
test('element waits enforce exact matches, ambiguity and bounded deadlines', async () => {
  const { config } = fixture();
  const found = await executeOperation(config, 'wait_for_element', {
    ...args,
    selector: { attribute: 'text', value: 'Tap' },
    timeout: 1,
  });
  assert.equal(found.node.text, 'Tap');
  const started = Date.now();
  await assert.rejects(
    executeOperation(config, 'wait_for_element', {
      ...args,
      selector: { attribute: 'text', value: 'missing' },
      timeout: 1,
    }),
    /Timed out|aborted/,
  );
  assert.ok(Date.now() - started < 2000);
});
test('revocation before dispatch prevents clipboard input', async () => {
  const { config } = fixture();
  const abort = new AbortController();
  abort.abort();
  let sent = false;
  await assert.rejects(
    executeOperation(
      config,
      'type_text',
      { ...args, text: 'never paste' },
      {
        signal: abort.signal,
        input: () => {
          sent = true;
        },
      },
    ),
  );
  assert.equal(sent, false);
});
