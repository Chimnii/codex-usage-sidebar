#!/usr/bin/env node
'use strict';
const { inspect, prepare } = require('./engine.cjs');
const names = { '--original-app-dir': 'originalAppDir', '--layer-root': 'layerRoot', '--layer-source-root': 'layerSourceRoot', '--output-app-dir': 'outputAppDir', '--asar-module': 'asarModule', '--portable-copy': 'portableCopy' };
async function main(args) {
  const mode = args.shift(), options = {};
  if (!['inspect', 'prepare'].includes(mode)) throw Error('Usage: cli.cjs inspect|prepare --original-app-dir PATH --layer-root PATH --layer-source-root PATH [--asar-module PATH] [--output-app-dir NEW_PATH]');
  while (args.length) {
    const name = args.shift(), key = names[name], value = args.shift();
    if (!key || options[key] !== undefined || !value || value.startsWith('--')) throw Error(`Invalid/duplicate argument: ${name}`);
    options[key] = value;
  }
  for (const key of ['originalAppDir', 'layerRoot', 'layerSourceRoot']) if (!options[key]) throw Error(`Missing argument: ${key}`);
  const report = await (mode === 'prepare' ? prepare(options) : inspect(options));
  process.stdout.write(`${JSON.stringify(report)}\n`);
}
main(process.argv.slice(2)).catch(error => {
  process.stderr.write(`${JSON.stringify({ status: 'error', error: error.message })}\n`);
  process.exitCode = 1;
});
