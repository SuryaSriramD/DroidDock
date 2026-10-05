const positive = (value, fallback) => (Number.isFinite(value) && value > 0 ? value : fallback);

// The same fit, margins, bezel and corner proportions as SimulatorChromeLayout.
export function phoneGeometry(available, display) {
  const width = Math.max(1, positive(available.width, 1) - 24);
  const height = Math.max(1, positive(available.height, 1) - 16);
  const frameWidth = positive(display.width, 1080);
  const frameHeight = positive(display.height, 2400);
  const bezel = Math.min(10, Math.min(width, height) / 8);
  const scale = Math.min((width - bezel * 2) / frameWidth, (height - bezel * 2) / frameHeight);
  const screenWidth = frameWidth * scale;
  const screenHeight = frameHeight * scale;
  const radius = Math.min(64, Math.min(screenWidth, screenHeight) * 0.15 + bezel);
  return {
    screenWidth,
    screenHeight,
    width: screenWidth + bezel * 2,
    height: screenHeight + bezel * 2,
    bezel,
    radius,
    screenRadius: Math.max(0, radius - bezel),
  };
}

export function guestPoint(point, rect, display, clamp = false) {
  if (
    ![rect.width, rect.height, display.width, display.height].every(
      (value) => Number.isFinite(value) && value > 0,
    )
  )
    return null;
  if (![point.x, point.y, rect.left, rect.top].every(Number.isFinite)) return null;
  const scale = Math.min(rect.width / display.width, rect.height / display.height);
  const left = rect.left + (rect.width - display.width * scale) / 2;
  const top = rect.top + (rect.height - display.height * scale) / 2;
  let x = (point.x - left) / scale;
  let y = (point.y - top) / scale;
  if (!clamp && (x < 0 || y < 0 || x >= display.width || y >= display.height)) return null;
  return {
    x: Math.max(0, Math.min(display.width - 1, Math.floor(x))),
    y: Math.max(0, Math.min(display.height - 1, Math.floor(y))),
    width: display.width,
    height: display.height,
  };
}

export const androidKeys = Object.freeze({
  Enter: 66,
  Backspace: 67,
  Tab: 61,
  Escape: 4,
  ArrowUp: 19,
  ArrowDown: 20,
  ArrowLeft: 21,
  ArrowRight: 22,
  Delete: 112,
  Home: 3,
  PageUp: 92,
  PageDown: 93,
});
