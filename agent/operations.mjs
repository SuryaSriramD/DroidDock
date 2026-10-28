import { randomUUID } from 'node:crypto';
import { writeFile, unlink, open, stat } from 'node:fs/promises';
import path from 'node:path';
import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { runProcess, requireSuccess, shellArguments, delay } from '../desktop/src/core/process.mjs';
import { approvedPath, privateDirectory } from './security.mjs';
import { validate } from './contract.mjs';
const PNG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
export function parseHierarchy(xml) {
  if (
    Buffer.byteLength(xml) > 2 * 1024 * 1024 ||
    /<!DOCTYPE|<!ENTITY/i.test(xml) ||
    XMLValidator.validate(xml) !== true
  )
    throw new Error('Invalid or oversized Android UI hierarchy.');
  const tree = new XMLParser({
    ignoreAttributes: false,
    attributeNamePrefix: '',
    processEntities: false,
    parseAttributeValue: false,
  }).parse(xml);
  const nodes = [];
  function walk(value, depth = 0) {
    if (depth > 128 || nodes.length > 10000)
      throw new Error('Android UI hierarchy exceeds inspection limit.');
    for (const node of [value].flat()) {
      if (!node || typeof node !== 'object') continue;
      const match = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(node.bounds || '');
      if (match)
        nodes.push({
          id: nodes.length,
          text: node.text || '',
          'resource-id': node['resource-id'] || '',
          'content-desc': node['content-desc'] || '',
          class: node.class || '',
          enabled: node.enabled === 'true',
          bounds: match.slice(1).map(Number),
        });
      if (node.node) walk(node.node, depth + 1);
    }
  }
  if (tree.hierarchy) walk(tree.hierarchy.node);
  return nodes;
}
export function uniqueMatch(nodes, selector) {
  const matches = nodes.filter((n) => n[selector.attribute] === selector.value);
  if (matches.length > 1)
    throw new Error(
      'Ambiguous UI selector; use a unique resource ID or inspect and select a node.',
    );
  return matches[0];
}
export async function executeOperation(config, tool, rawArgs, { signal, input, inspection } = {}) {
  const args = validate(tool, rawArgs);
  signal?.throwIfAborted();
  const adb = async (tokens, options = {}) =>
    (config.run ?? runProcess)(config.adb, ['-s', config.serial, ...tokens], {
      env: { ...process.env, ...config.environment },
      signal,
      timeout: 30000,
      maxBytes: 2 * 1024 * 1024,
      ...options,
    });
  const checked = async (tokens, options) =>
    requireSuccess(await adb(tokens, options), 'Android operation');
  const shell = (tokens, options) => checked(shellArguments(tokens), options);
  async function dimensions() {
    const png = (
      await checked(['exec-out', 'screencap', '-p'], { encoding: null, maxBytes: 16 * 1024 * 1024 })
    ).stdout;
    if (!png.subarray(0, 8).equals(PNG) || png.length < 24)
      throw new Error('Android did not return a PNG screenshot.');
    const orientation = await shell(['dumpsys', 'input'])
      .then((result) => result.stdout.match(/SurfaceOrientation:\s*([0-3])/))
      .catch((error) => {
        if (signal?.aborted) throw error;
        return null;
      });
    return {
      rotation: orientation ? Number(orientation[1]) : null,
      png,
      width: png.readUInt32BE(16),
      height: png.readUInt32BE(20),
    };
  }
  async function hierarchy() {
    const temporary = `/data/local/tmp/droiddock-${randomUUID()}.xml`;
    try {
      await shell(['uiautomator', 'dump', temporary], { timeout: 10000 });
      return parseHierarchy((await shell(['cat', temporary])).stdout);
    } finally {
      await shell(['rm', '-f', temporary], { timeout: 3000, signal: undefined }).catch(() => {});
    }
  }
  const packageName = (value) => {
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(value))
      throw new Error('Invalid Android package name.');
    return value;
  };
  switch (tool) {
    case 'inspect_device': {
      const before = await dimensions();
      let nodes = [],
        hierarchyError;
      try {
        nodes = await hierarchy();
      } catch (error) {
        if (signal?.aborted) throw error;
        hierarchyError = error.message;
      }
      const after = await dimensions();
      if (
        before.width !== after.width ||
        before.height !== after.height ||
        before.rotation !== after.rotation
      )
        throw new Error('Android rotated during inspection; inspect again.');
      const snapshot = {
        id: randomUUID(),
        capturedAt: new Date().toISOString(),
        width: after.width,
        height: after.height,
        orientation: after.width > after.height ? 'landscape' : 'portrait',
        rotation: after.rotation,
        nodes,
        ...(hierarchyError && { hierarchyError }),
      };
      return { ...snapshot, image: after.png.toString('base64') };
    }
    case 'tap':
    case 'swipe': {
      const { width, height, rotation } = await dimensions();
      let { x, y } = args;
      if (args.node !== undefined) {
        if (
          !inspection ||
          inspection.id !== args.inspection ||
          inspection.width !== width ||
          inspection.height !== height ||
          inspection.rotation !== rotation ||
          rotation === null
        )
          throw new Error('Stale inspection; inspect the phone again.');
        const node = inspection.nodes[args.node];
        if (!node?.enabled) throw new Error('Unknown or disabled UI node.');
        const [left, top, right, bottom] = node.bounds;
        x = Math.floor((left + right) / 2);
        y = Math.floor((top + bottom) / 2);
      }
      const valid = (x, y) =>
        Number.isInteger(x) && Number.isInteger(y) && x >= 0 && y >= 0 && x < width && y < height;
      if (!valid(x, y) || (tool === 'swipe' && !valid(args.endX, args.endY)))
        throw new Error('Coordinates must be inside the native Android screen.');
      await shell(
        tool === 'tap'
          ? ['input', 'tap', String(x), String(y)]
          : [
              'input',
              'swipe',
              String(x),
              String(y),
              String(args.endX),
              String(args.endY),
              String(args.duration),
            ],
      );
      return { success: true };
    }
    case 'type_text':
      if (!input) throw new Error('Open the DroidDock phone display to paste text.');
      await input({ type: 'clipboard', text: args.text });
      return { success: true, guestClipboardReplaced: true };
    case 'press_key':
      await shell([
        'input',
        'keyevent',
        String({ back: 4, home: 3, recents: 187, enter: 66, delete: 67 }[args.key]),
      ]);
      return { success: true };
    case 'wait_for_element': {
      const deadline = Date.now() + args.timeout * 1000;
      do {
        const remaining = deadline - Date.now();
        if (remaining <= 0) break;
        const timeoutSignal = AbortSignal.timeout(remaining);
        const attempt = AbortSignal.any([...(signal ? [signal] : []), timeoutSignal]);
        const result = await executeOperation(
          config,
          'inspect_device',
          { device: args.device, handle: args.handle },
          { signal: attempt },
        );
        const node = uniqueMatch(result.nodes, args.selector);
        if (node)
          return {
            node,
            capturedAt: result.capturedAt,
            message: 'Element matched. Inspect again before using node references.',
          };
        await delay(Math.min(500, Math.max(1, deadline - Date.now())), signal);
      } while (Date.now() < deadline);
      throw new Error('Timed out waiting for UI element.');
    }
    case 'android_shell':
      return adb(shellArguments(args.args), {
        timeout: args.timeout * 1000,
        truncateOutput: true,
        maxBytes: 256 * 1024,
      });
    case 'read_logs': {
      const tokens = ['logcat', '-d', '-v', 'threadtime', '-t', String(args.lines)];
      if (args.package) {
        const pid = (await shell(['pidof', packageName(args.package)])).stdout.trim();
        if (!/^\d+$/.test(pid))
          throw new Error('Package must have one running PID for log filtering.');
        tokens.push('--pid', pid);
      }
      tokens.push(`*:${args.priority}`);
      return adb(tokens, { truncateOutput: true, maxBytes: 256 * 1024 });
    }
    case 'app_action': {
      let result;
      switch (args.action) {
        case 'install': {
          const filename = await approvedPath(args.value, config.roots);
          if (!filename.toLowerCase().endsWith('.apk')) throw new Error('Choose a readable APK.');
          result = await checked(['install', '-r', filename], { timeout: 180000 });
          if (!result.stdout.split(/\r?\n/).some((line) => line.trim() === 'Success'))
            throw new Error('Android did not confirm APK installation.');
          break;
        }
        case 'launch': {
          if (args.value.includes('/')) {
            if (!/^[A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+$/.test(args.value))
              throw new Error('Invalid package/activity.');
            result = await shell(['am', 'start', '-W', '-n', args.value]);
          } else
            result = await shell([
              'monkey',
              '-p',
              packageName(args.value),
              '-c',
              'android.intent.category.LAUNCHER',
              '1',
            ]);
          break;
        }
        case 'force-stop':
          result = await shell(['am', 'force-stop', packageName(args.value)]);
          break;
        case 'uninstall':
          result = await checked(['uninstall', packageName(args.value)]);
          break;
        case 'clear-data':
          result = await shell(['pm', 'clear', packageName(args.value)]);
          break;
        case 'open-url': {
          const url = new URL(args.value);
          if (
            [
              'file:',
              'content:',
              'javascript:',
              'data:',
              'droiddock:',
              'android-simulator:',
            ].includes(url.protocol)
          )
            throw new Error('Unsupported app link scheme.');
          result = await shell([
            'am',
            'start',
            '-W',
            '-a',
            'android.intent.action.VIEW',
            '-d',
            args.value,
          ]);
          break;
        }
      }
      if (/\bError:|\bFailure\b/.test(result.stdout + result.stderr))
        throw new Error(
          'Android rejected the app operation: ' + (result.stderr || result.stdout).slice(-4096),
        );
      return result;
    }
    case 'transfer_file': {
      if (!args.guestPath.startsWith('/') || /[\r\n\0]/.test(args.guestPath))
        throw new Error('Guest path must be absolute.');
      const target = await approvedPath(args.hostPath, config.roots, {
        destination: args.direction === 'pull',
      });
      if (args.direction === 'push') {
        if ((await stat(target)).size > 256 * 1024 * 1024)
          throw new Error('File exceeds 256 MiB transfer limit.');
        await checked(['push', target, args.guestPath], { timeout: 60000 });
      } else {
        const size = (await shell(['stat', '-c', '%s', args.guestPath])).stdout.trim();
        if (!/^\d+$/.test(size) || Number(size) > 256 * 1024 * 1024)
          throw new Error('Guest file exceeds transfer limit.');
        const bytes = (
          await checked(['exec-out', shellArguments(['cat', args.guestPath])[1]], {
            encoding: null,
            maxBytes: 256 * 1024 * 1024,
            timeout: 60000,
          })
        ).stdout;
        if (bytes.length !== Number(size))
          throw new Error('Guest file changed during transfer; retry.');
        await approvedPath(target, config.roots, { destination: true });
        const file = await open(target, 'wx', 0o600);
        try {
          await file.writeFile(bytes);
        } catch (error) {
          await unlink(target).catch(() => {});
          throw error;
        } finally {
          await file.close();
        }
      }
      return { success: true };
    }
    default:
      throw new Error('Unsupported device operation.');
  }
}
export async function artifactResult(directory, value) {
  await privateDirectory(directory);
  const id = `${randomUUID()}.json`;
  await writeFile(path.join(directory, id), JSON.stringify(value), { flag: 'wx', mode: 0o600 });
  return { artifact: id };
}
