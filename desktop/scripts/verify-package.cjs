const assert = require('node:assert/strict');
const path = require('node:path');
const asar = require('@electron/asar');

// A build inside the source tree can silently resolve missing dependencies from
// the developer's node_modules. Validate the archive before creating installers.
module.exports = async ({ appOutDir }) => {
  const archive = path.join(appOutDir, 'resources', 'app.asar');
  const files = new Set(asar.listPackage(archive).map((file) => file.replaceAll('\\', '/')));
  const visited = new Set();
  function check(packageFile) {
    if (visited.has(packageFile)) return;
    visited.add(packageFile);
    const metadata = JSON.parse(asar.extractFile(archive, packageFile.split('/').join(path.sep)));
    for (const name of Object.keys(metadata.dependencies ?? {})) {
      let directory = path.posix.dirname(packageFile);
      let dependency;
      while (true) {
        const candidate = path.posix.join(directory, 'node_modules', name, 'package.json');
        if (files.has('/' + candidate)) {
          dependency = candidate;
          break;
        }
        if (directory === '.') break;
        directory = path.posix.dirname(directory);
      }
      assert.ok(dependency, `Packaged ${metadata.name} is missing runtime dependency ${name}`);
      check(dependency);
    }
  }
  check('package.json');
  console.log(`Verified ${visited.size - 1} packaged runtime dependencies.`);
};
