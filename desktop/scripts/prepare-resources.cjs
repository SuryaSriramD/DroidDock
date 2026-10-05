const fs = require('node:fs/promises');
const path = require('node:path');

// Reuse the existing native app artwork, extracting PNG payloads without
// re-rendering it or requiring macOS image tools on Windows/Linux builders.
async function prepareResources() {
  const desktop = path.resolve(__dirname, '..');
  const data = await fs.readFile(path.join(desktop, '..', 'Resources', 'AppIcon.icns'));
  if (data.toString('ascii', 0, 4) !== 'icns' || data.readUInt32BE(4) !== data.length)
    throw new Error('Invalid DroidDock icon archive.');
  const images = new Map();
  for (let offset = 8; offset < data.length;) {
    if (offset + 8 > data.length) throw new Error('Truncated icon entry.');
    const kind = data.toString('ascii', offset, offset + 4);
    const length = data.readUInt32BE(offset + 4);
    if (length < 8 || offset + length > data.length) throw new Error('Invalid icon entry length.');
    const payload = data.subarray(offset + 8, offset + length);
    if (payload.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])))
      images.set(kind, payload);
    offset += length;
  }
  const linux = images.get('ic10') ?? images.get('ic09');
  const windows = images.get('ic08');
  if (!linux || !windows || windows.readUInt32BE(16) !== 256 || windows.readUInt32BE(20) !== 256)
    throw new Error('The source icon must contain PNG artwork at 256px and 512px or 1024px.');
  const ico = Buffer.alloc(22);
  ico.writeUInt16LE(1, 2); // ICO file type
  ico.writeUInt16LE(1, 4); // One PNG entry; dimensions zero mean 256px.
  ico.writeUInt16LE(1, 10);
  ico.writeUInt16LE(32, 12);
  ico.writeUInt32LE(windows.length, 14);
  ico.writeUInt32LE(22, 18);
  await fs.mkdir(path.join(desktop, 'build'), { recursive: true });
  await fs.writeFile(path.join(desktop, 'build', 'icon.png'), linux);
  await fs.writeFile(path.join(desktop, 'build', 'icon.ico'), Buffer.concat([ico, windows]));
}

module.exports = prepareResources;
if (require.main === module)
  prepareResources().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
