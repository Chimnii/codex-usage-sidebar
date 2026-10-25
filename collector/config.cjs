'use strict';
const path = require('node:path');
const { normalizeUsageSettings } = require('./settings.cjs');
function resolveConfig(config, file) {
  config = { ...config, usage: normalizeUsageSettings(config?.usage) };
  if (!config.managedCopy) return config;
  const dataDir = path.dirname(path.resolve(file));
  const root = path.resolve(dataDir, '../..');
  return { ...config, codexPath: config.cliSource === 'app' ? path.resolve(root, '../app/resources/codex.exe') : path.join(root, 'bin/codex.exe'),
    workDir: path.join(root, 'collector-work'), cachePath: path.join(dataDir, 'usage-cache.json') };
}
module.exports = { resolveConfig };
