'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { prepare, main } = require('../scripts/patch-layer-runtime.cjs');

const configLine = 'var CODEX_CONFIG_FILE = (0, import_node_path6.join)((0, import_node_os2.homedir)(), ".codex", "config.toml");';
const pathsLine = 'exports.CODEX_CONFIG_FILE = (0, node_path_1.join)((0, node_os_1.homedir)(), ".codex", "config.toml");';
function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sidebar-layer-isolation-'));
  fs.writeFileSync(path.join(root, 'main.js'), `var CODEX_PLUSPLUS_VERSION = "1.1.4";\n${configLine}\nfunction loadAllMainTweaks() {\n  syncMcpServersFromEnabledTweaks();\n  started++;\n}\n`);
  fs.writeFileSync(path.join(root, 'runtime-paths.js'), pathsLine);
  return root;
}
function cleanup(root) {
  assert.equal(path.dirname(root), path.resolve(os.tmpdir()));
  assert.ok(path.basename(root).startsWith('sidebar-layer-isolation-'));
  fs.rmSync(root, { recursive: true, force: true });
}
test('Layer runtime starts tweaks without synchronizing shared MCP config; patch is idempotent', () => {
  const root = fixture();
  try {
    const original = fs.readFileSync(path.join(root, 'main.js'), 'utf8');
    assert.equal(main(['--runtime-root', root, '--check']).status, 'validated');
    assert.equal(fs.readFileSync(path.join(root, 'main.js'), 'utf8'), original);
    main(['--runtime-root', root]);
    const source = fs.readFileSync(path.join(root, 'main.js'), 'utf8');
    const context = { process: { env: { CODEX_HOME: path.join(root, 'shared-profile') } }, import_node_path6: path,
      import_node_os2: { homedir: () => root }, started: 0,
      syncMcpServersFromEnabledTweaks: () => { throw Error('Shared config must not be written'); } };
    vm.createContext(context);
    vm.runInContext(source + '\nloadAllMainTweaks();', context);
    assert.equal(context.started, 1);
    assert.equal(context.CODEX_CONFIG_FILE, path.join(root, 'shared-profile/config.toml'));
    assert.ok(prepare(root).every(file => !file.changed));
  } finally { cleanup(root); }
});
test('unsupported MCP hook rejects the complete plan before writing either runtime file', () => {
  const root = fixture();
  try {
    const mainPath = path.join(root, 'main.js');
    fs.appendFileSync(mainPath, '\nfunction duplicate() {\n  syncMcpServersFromEnabledTweaks();\n}\n');
    const before = fs.readFileSync(mainPath, 'utf8');
    assert.throws(() => main(['--runtime-root', root]), /Unsupported or ambiguous/);
    assert.equal(fs.readFileSync(mainPath, 'utf8'), before);
    assert.equal(fs.readFileSync(path.join(root, 'runtime-paths.js'), 'utf8'), pathsLine);
  } finally { cleanup(root); }
});
test('pinned upstream Layer has the exact supported hooks (read-only)', () => {
  const root = path.resolve(__dirname, '../node_modules/chatgpt-layer/assets/runtime');
  const plan = prepare(root);
  assert.equal(plan.length, 2);
  const patched = plan.find(file => file.name === 'main.js');
  assert.ok(patched.updated.includes('MCP sync disabled'));
  assert.ok(!patched.updated.includes('  syncMcpServersFromEnabledTweaks();'));
  assert.equal(fs.readFileSync(patched.file, 'utf8'), patched.original);
});
