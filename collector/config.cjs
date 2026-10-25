'use strict';
const path = require('node:path');
function resolveConfig(config, file) {
  if (!config.managedCopy) return config;
  const dataDir = path.dirname(path.resolve(file));
  const root = path.resolve(dataDir, '../..');
  return { ...config, codexPath: path.join(root, 'bin/codex.exe'),
    workDir: path.join(root, 'collector-work'), cachePath: path.join(dataDir, 'usage-cache.json') };
}
module.exports = { resolveConfig };
