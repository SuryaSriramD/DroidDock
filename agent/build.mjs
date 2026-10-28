import { build } from 'esbuild';
await rm('dist', { recursive: true, force: true });
await build({
  entryPoints: ['server.mjs', 'worker.mjs', 'self-test.mjs', 'controller.mjs'],
  outdir: 'dist',
  outExtension: { '.js': '.mjs' },
  bundle: true,
  platform: 'node',
  target: 'node22',
  format: 'esm',
  banner: {
    js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);",
  },
});

import { readdir, readFile, rm, writeFile } from 'node:fs/promises';
const licenses = [];
const lock = JSON.parse(await readFile('package-lock.json', 'utf8'));
for (const [directory, metadata] of Object.entries(lock.packages)) {
  if (!directory || metadata.dev) continue;
  const texts = [];
  for (const name of await readdir(directory))
    if (/^(license|licence|notice|copying)/i.test(name)) {
      try {
        texts.push(await readFile(directory + '/' + name, 'utf8'));
      } catch {}
    }
  licenses.push({
    package: directory,
    version: metadata.version,
    license: metadata.license,
    texts,
  });
}
await writeFile('dist/THIRD-PARTY-NOTICES.json', JSON.stringify(licenses, null, 2));
