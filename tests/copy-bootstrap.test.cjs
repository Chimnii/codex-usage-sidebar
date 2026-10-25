'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { initialize, APP_ID } = require('../patcher/repatch/copy-bootstrap.cjs');
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
    assert.equal(config.workDir, path.join(root, 'layer-data/collector-work'));
    assert.equal(config.codexHome, environment.CODEX_HOME);
  });
}
test('ordinary installer collector config is unchanged', () => {
  const config = { codexPath: 'original', workDir: 'original' };
  assert.equal(resolveConfig(config, 'unused'), config);
});
