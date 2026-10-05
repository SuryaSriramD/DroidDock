import test from 'node:test';
import assert from 'node:assert/strict';
import { phoneGeometry, guestPoint } from '../src/renderer/phone-input.mjs';

test('phone chrome keeps real portrait and landscape aspect ratios within its available space', () => {
  for (const available of [
    { width: 414, height: 770 },
    { width: 344, height: 400 },
    { width: 770, height: 330 },
  ]) {
    for (const display of [
      { width: 1080, height: 2400 },
      { width: 2400, height: 1080 },
    ]) {
      const size = phoneGeometry(available, display);
      assert.ok(
        Math.abs(size.screenWidth / size.screenHeight - display.width / display.height) < 1e-10,
      );
      assert.ok(size.width <= available.width - 24 + 1e-9);
      assert.ok(size.height <= available.height - 16 + 1e-9);
      assert.equal(size.width - size.screenWidth, 20);
      assert.ok(size.radius <= 64);
    }
  }
});

test('touch geometry excludes aspect-fit margins and clamps a captured drag without changing guest dimensions', () => {
  const rect = { left: 10, top: 20, width: 400, height: 400 };
  const display = { width: 1080, height: 2400 };
  assert.equal(guestPoint({ x: 20, y: 30 }, rect, display), null);
  assert.deepEqual(guestPoint({ x: 210, y: 220 }, rect, display), {
    x: 540,
    y: 1200,
    width: 1080,
    height: 2400,
  });
  assert.deepEqual(guestPoint({ x: 500, y: 500 }, rect, display, true), {
    x: 1079,
    y: 2399,
    width: 1080,
    height: 2400,
  });
});

test('rotated input follows the decoded landscape frame rather than the configured portrait phone', () => {
  assert.deepEqual(
    guestPoint(
      { x: 300, y: 135 },
      { left: 0, top: 0, width: 600, height: 270 },
      { width: 2400, height: 1080 },
    ),
    { x: 1200, y: 540, width: 2400, height: 1080 },
  );
  assert.equal(
    guestPoint(
      { x: 0, y: 0 },
      { left: 0, top: 0, width: 0, height: 20 },
      { width: 2400, height: 1080 },
    ),
    null,
  );
  const fallback = phoneGeometry({ width: 414, height: 770 }, { width: NaN, height: 0 });
  assert.ok(Number.isFinite(fallback.width) && fallback.width > 0);
});
