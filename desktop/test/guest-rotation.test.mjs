import test from 'node:test';
import assert from 'node:assert/strict';
import { GuestRotation } from '../src/core/guest-rotation.mjs';

function fixture({ auto = '1', rotation = '0', policy = 'free' } = {}) {
  const calls = [];
  let failRestore = false;
  const controller = new GuestRotation(async (args) => {
    calls.push(args);
    if (args.includes('get')) return args.at(-1) === 'user_rotation' ? rotation : auto;
    if (args.length === 2) return policy;
    if (failRestore && args.includes('free')) throw new Error('ADB unavailable');
    return '';
  });
  return {
    controller,
    calls,
    fail: (value) => {
      failRestore = value;
    },
  };
}
test('rotation serializes clicks, remembers once and restores original Android policy/settings', async () => {
  const f = fixture();
  await Promise.all([f.controller.rotate(1), f.controller.rotate(0)]);
  assert.deepEqual(f.calls.slice(3), [
    ['wm', 'user-rotation', 'lock', '1'],
    ['wm', 'user-rotation', 'lock', '0'],
  ]);
  await f.controller.restore();
  assert.deepEqual(f.calls.slice(-3), [
    ['wm', 'user-rotation', 'free'],
    ['settings', '--user', 'current', 'put', 'system', 'user_rotation', '0'],
    ['settings', '--user', 'current', 'put', 'system', 'accelerometer_rotation', '1'],
  ]);
  assert.equal(f.controller.original, null);
});
test('invalid orientation and unrecognized policy do not mutate the guest', async () => {
  const f = fixture({ policy: 'unknown' });
  await assert.rejects(f.controller.rotate(4), /between/);
  assert.deepEqual(f.calls, []);
  await assert.rejects(f.controller.rotate(1), /restorable/);
  assert.equal(f.calls.length, 3);
  assert.equal(f.controller.original, null);
});
test('failed cleanup retains the original values for retry and deletes formerly unset settings', async () => {
  const f = fixture({ auto: 'null', rotation: 'null' });
  await f.controller.rotate(1);
  f.fail(true);
  await assert.rejects(f.controller.restore(), /ADB unavailable/);
  assert.ok(f.controller.original);
  f.fail(false);
  await f.controller.restore();
  assert.deepEqual(f.calls.slice(-2), [
    ['settings', '--user', 'current', 'delete', 'system', 'user_rotation'],
    ['settings', '--user', 'current', 'delete', 'system', 'accelerometer_rotation'],
  ]);
});
