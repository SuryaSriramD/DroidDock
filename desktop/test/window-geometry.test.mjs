import test from 'node:test';
import assert from 'node:assert/strict';
import { deviceWindowBounds } from '../src/window-geometry.mjs';
test('portrait and rotated phone windows fit a laptop work area and keep the top-left when possible', () => {
  const workArea = { x: 0, y: 0, width: 1366, height: 728 };
  const portrait = deviceWindowBounds({ width: 1080, height: 2400, workArea });
  assert.ok(portrait.height > portrait.width);
  assert.ok(portrait.y + portrait.height <= workArea.height);
  const landscape = deviceWindowBounds({ width: 2400, height: 1080, workArea, current: portrait });
  assert.ok(landscape.width > landscape.height);
  assert.equal(landscape.y, portrait.y);
  assert.ok(landscape.x >= 0 && landscape.x + landscape.width <= workArea.width);
});
test('negative-origin monitors and oversized previous windows remain within the visible screen', () => {
  const area = { x: -1920, y: 30, width: 1920, height: 1050 };
  const result = deviceWindowBounds({
    width: 800,
    height: 600,
    workArea: area,
    current: { x: 3000, y: 5000, width: 900, height: 1400 },
  });
  assert.ok(result.x >= area.x && result.x + result.width <= 0);
  assert.ok(result.y + result.height <= 1080);
  assert.throws(() => deviceWindowBounds({ width: Infinity, height: 0, workArea: area }));
});
