'use strict';
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const unit = fs.readdirSync(path.join(root, 'tests')).filter(n => n.endsWith('.test.cjs') && n !== 'repatch-engine.test.cjs').map(n => 'tests/' + n);
for (const args of [['--test', ...unit, 'collector/collector.test.cjs'], ['tests/repatch-engine.test.cjs']]) {
  const p = spawnSync(process.execPath, args, { cwd: root, stdio: 'inherit' });
  if (p.status !== 0) process.exit(p.status || 1);
}
