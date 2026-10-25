'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { initialize, updateInProgress, APP_ID } = require('../patcher/repatch/copy-bootstrap.cjs');
const { resolveConfig } = require('../collector/config.cjs');

for (const slot of ['staging', 'active', 'previous']) {
  test(`direct EXE bootstrap resolves ${slot}, profiles, updater and stable shell identity without launcher`, () => {
    const root = path.resolve('test-only', slot);
    const archive = path.join(root, 'app/resources/app.asar');
    const pkg = { __codexpp: { userRoot: 'old staging path' } };
    const env = { CODEX_ELECTRON_USER_DATA_PATH: 'wrong', CODEXPP_REMOTE_DEBUG: '1', NODE_OPTIONS: 'bad' };
    const calls = [];
    const app = { setAppUserModelId: id => calls.push(id) };
    const environment = Object.fromEntries(['APPDATA', 'LOCALAPPDATA', 'USERPROFILE', 'CODEX_HOME'].map(k => [k, path.resolve('original-profile', k)]));
    const result = initialize(archive, {
      process: { platform: 'win32', env }, skipMaintenance: true,
      readFile: file => { assert.equal(file, path.join(root, 'copy-startup.json')); return JSON.stringify({ schemaVersion: 1, appUserModelId: APP_ID, packageFullName: 'original-version', environment }); },
      require: name => name === './package.json' ? pkg : { app }
    });
    assert.equal(result.layerRoot, path.join(root, 'layer-data'));
    assert.equal(pkg.__codexpp.userRoot, result.layerRoot);
    assert.equal(env.SIDEBAR_USAGE_PACKAGE, 'original-version');
    assert.equal(env.CODEX_HOME, environment.CODEX_HOME);
    assert.equal(env.APPDATA, environment.APPDATA);
    assert.equal(env.CODEX_ELECTRON_USER_DATA_PATH, undefined);
    assert.equal(env.NODE_OPTIONS, undefined);
    assert.equal(env.CODEXPP_REMOTE_DEBUG, '0');
    app.setAppUserModelId('com.openai.codex');
    assert.deepEqual(calls, [APP_ID, APP_ID]);
    const configPath = path.join(root, 'layer-data/tweak-data/local.sidebar-usage-demo/collector-config.json');
    const config = resolveConfig({ managedCopy: true, codexHome: environment.CODEX_HOME }, configPath);
    assert.equal(config.codexPath, path.join(root, 'layer-data/bin/codex.exe'));
    const modern = resolveConfig({ managedCopy: true, cliSource: 'app' }, path.join(root, 'layer-data/tweak-data/local.sidebar-usage-demo/collector-config.json'));
    assert.equal(modern.codexPath, path.join(root, 'app/resources/codex.exe'));
    assert.equal(config.workDir, path.join(root, 'layer-data/collector-work'));
    assert.equal(config.codexHome, environment.CODEX_HOME);
  });
}
test('ordinary installer collector paths are preserved', () => {
  const config = { codexPath: 'original', workDir: 'original' };
  const result = resolveConfig(config, 'unused');
  assert.equal(result.codexPath, config.codexPath);
  assert.equal(result.workDir, config.workDir);
});

const NOW = Date.parse('2026-10-25T00:00:00Z');
const token = '0123456789abcdef0123456789abcdef';
function updateMarker(extra = {}) {
  return { schemaVersion: 1, pid: 123, ownerToken: token, startedAt: new Date(NOW - 1000).toISOString(),
    expiresAt: new Date(NOW + 3600000).toISOString(), ...extra };
}
test('direct startup respects a live updater, but not stale, malformed or expired leftovers without a lock', () => {
  const root = path.resolve('fixture-project');
  const deps = { now: () => NOW, readFile: () => JSON.stringify(updateMarker()), isUpdateLocked: () => true };
  assert.equal(updateInProgress(root, undefined, deps), true);
  assert.equal(updateInProgress(root, token, deps), false);
  assert.equal(updateInProgress(root, undefined, { ...deps, isUpdateLocked: () => false }), false);
  assert.equal(updateInProgress(root, undefined, { ...deps, readFile: () => '{broken' }), true);
  assert.equal(updateInProgress(root, undefined, { ...deps, readFile: () => '{broken', isUpdateLocked: () => false }), false);
  assert.equal(updateInProgress(root, undefined, { ...deps, readFile: () => JSON.stringify(updateMarker({ expiresAt: new Date(NOW - 1).toISOString() })) }), false);
  assert.equal(updateInProgress(root, undefined, { ...deps, readFile: () => { throw Object.assign(Error('missing'), { code: 'ENOENT' }); } }), true);
});
test('blocked startup shows a friendly message and exits before package, profile or Layer changes', () => {
  const root = path.resolve('fixture-project/.local/copy/active'), projectRoot = path.resolve('fixture-project');
  const env = { CODEX_HOME: 'untouched', NODE_OPTIONS: 'untouched' }, calls = [];
  const result = initialize(path.join(root, 'app/resources/app.asar'), {
    process: { platform: 'win32', env }, now: () => NOW, isUpdateLocked: () => true,
    readFile: file => file.endsWith('copy-startup.json') ? JSON.stringify({ schemaVersion: 1, appUserModelId: APP_ID, packageFullName: 'fixture', projectRoot }) : JSON.stringify(updateMarker()),
    require: name => {
      assert.equal(name, 'electron');
      return { app: { getLocale: () => 'en-US', exit: code => calls.push(['exit', code]) }, dialog: { showErrorBox: (...args) => calls.push(['message', ...args]) } };
    }
  });
  assert.equal(result.blocked, true);
  assert.deepEqual(env, { CODEX_HOME: 'untouched', NODE_OPTIONS: 'untouched' });
  assert.equal(calls[0][0], 'message'); assert.match(calls[0][2], /helper/);
  assert.deepEqual(calls[1], ['exit', 0]);
});
