#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const { collect, failedSnapshot } = require('./collector.cjs');

async function main() {
  const controller = new AbortController();
  const cancel = () => controller.abort();
  const signals = ['SIGINT', 'SIGTERM', 'SIGHUP'];
  signals.forEach((name) => process.on(name, cancel));
  let watchedStdin = false;
  try {
    // A supervising parent keeps the pipe open; EOF means its owner has gone.
    const stat = fs.fstatSync(0);
    // Windows anonymous pipes can report neither isFIFO nor isSocket.
    if (!process.stdin.isTTY && !stat.isCharacterDevice()) {
      watchedStdin = true;
      process.stdin.on('end', cancel);
      process.stdin.on('error', cancel);
      process.stdin.resume();
    }
  } catch {}
  let snapshot;
  try {
    const args = process.argv.slice(2);
    if ((args.length !== 2 && !(args.length === 3 && args[2] === '--refresh')) || args[0] !== '--config') throw new Error('config');
    const stat = fs.statSync(args[1]);
    if (!stat.isFile() || stat.size > 64 * 1024) throw new Error('config');
    const config = require('./config.cjs').resolveConfig(JSON.parse(fs.readFileSync(args[1], 'utf8').replace(/^\uFEFF/, '')), args[1]);
    snapshot = await collect(config, { signal: controller.signal, forceRefresh: args[2] === '--refresh' });
  } catch { snapshot = failedSnapshot(); }
  finally {
    signals.forEach((name) => process.removeListener(name, cancel));
    if (watchedStdin) {
      process.stdin.removeListener('end', cancel);
      process.stdin.removeListener('error', cancel);
      process.stdin.pause();
      process.stdin.unref?.();
    }
  }
  // Exactly one JSON object on stdout. Never print subprocess stderr or auth data.
  process.stdout.write(JSON.stringify(snapshot) + '\n');
}

if (require.main === module) main().catch(() => { process.stdout.write(JSON.stringify(failedSnapshot()) + '\n'); });
module.exports = { main };
