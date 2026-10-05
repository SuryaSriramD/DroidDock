/** Device windows use desktop points; Android input continues to use decoded pixels. */
export function deviceWindowBounds({ width, height, workArea, current }) {
  if (![width, height].every((value) => Number.isFinite(value) && value > 0 && value <= 8192))
    throw new Error('Invalid display size.');
  if (
    !workArea ||
    !['x', 'y', 'width', 'height'].every((key) => Number.isFinite(workArea[key])) ||
    workArea.width < 1 ||
    workArea.height < 1
  )
    throw new Error('Invalid desktop work area.');
  const landscape = width > height;
  const availableWidth = Math.max(1, workArea.width - 24),
    availableHeight = Math.max(1, workArea.height - 24);
  const desired = landscape ? { width: 820, height: 440 } : { width: 440, height: 860 };
  if (current) {
    desired.width = Math.max(360, current.height - 52);
    desired.height = Math.max(260, current.width + 52);
  }
  const scale = Math.min(1, availableWidth / desired.width, availableHeight / desired.height);
  const w = Math.round(desired.width * scale),
    h = Math.round(desired.height * scale);
  const x = current?.x ?? workArea.x + (workArea.width - w) / 2;
  const y = current?.y ?? workArea.y + (workArea.height - h) / 2;
  return {
    x: Math.round(Math.max(workArea.x + 12, Math.min(x, workArea.x + workArea.width - 12 - w))),
    y: Math.round(Math.max(workArea.y + 12, Math.min(y, workArea.y + workArea.height - 12 - h))),
    width: w,
    height: h,
  };
}
