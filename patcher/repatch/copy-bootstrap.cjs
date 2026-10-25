'use strict';
const fs = require('node:fs');
const path = require('node:path');
const APP_ID = 'Local.CodexUsageSidebar';

function initialize(archiveDir, dependencies = {}) {
  const proc = dependencies.process || process;
  const load = dependencies.require || require;
  const read = dependencies.readFile || (file => fs.readFileSync(file, 'utf8'));
  const root = path.resolve(archiveDir, '../../..');
  const config = JSON.parse(read(path.join(root, 'copy-startup.json')));
  if (config.schemaVersion !== 1 || config.appUserModelId !== APP_ID || !config.packageFullName) {
    throw new Error('Invalid managed copy startup settings');
  }
  const layerRoot = path.join(root, 'layer-data');
  const pkg = load('./package.json');
  pkg.__codexpp.userRoot = layerRoot;
  for (const key of ['ELECTRON_RUN_AS_NODE', 'NODE_OPTIONS', 'NODE_PATH', 'CODEX_ELECTRON_USER_DATA_PATH',
    'CODEX_ELECTRON_AGENT_RUN_ID', 'CODEXPP_REMOTE_DEBUG_PORT', 'SIDEBAR_USAGE_DEMO_RUNTIME_CACHE']) delete proc.env[key];
  for (const key of ['APPDATA', 'LOCALAPPDATA', 'USERPROFILE', 'CODEX_HOME']) {
    if (typeof config.environment?.[key] !== 'string' || !path.isAbsolute(config.environment[key])) throw new Error(`Missing profile setting: ${key}`);
    proc.env[key] = config.environment[key];
  }
  Object.assign(proc.env, {
    CODEX_PLUSPLUS_HOME: layerRoot, CODEX_PLUSPLUS_USER_ROOT: layerRoot,
    CODEX_PLUSPLUS_RUNTIME: path.join(layerRoot, 'runtime'), CODEXPP_REMOTE_DEBUG: '0',
    SIDEBAR_USAGE_PACKAGE: config.packageFullName, SIDEBAR_USAGE_VERIFY: '1'
  });
  // Bootstrap runs before Layer and the app's own bootstrap. Its later setter
  // must use the same version-independent ID as the direct-EXE shortcut.
  const { app } = load('electron');
  if (proc.platform === 'win32') {
    const nativeSetId = app.setAppUserModelId.bind(app);
    app.setAppUserModelId = () => nativeSetId(APP_ID);
    app.setAppUserModelId(APP_ID);
  }
  // Small, hidden local cleanup only: no Store query, app launch or patching.
  // This retires legacy directories after the old running copy has finally quit.
  if (!dependencies.skipMaintenance && config.projectRoot) {
    app.whenReady().then(() => {
      const child = load('node:child_process').spawn(path.join(proc.env.SystemRoot || 'C:\\Windows',
        'System32/WindowsPowerShell/v1.0/powershell.exe'), ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        path.join(config.projectRoot, 'scripts/Maintain-UsageCopy.ps1'), '-ProjectRoot', config.projectRoot],
      { detached: true, windowsHide: true, stdio: 'ignore' });
      child.on('error', () => {}); child.unref();
    }).catch(() => {});
  }
  return { root, layerRoot, appUserModelId: APP_ID, packageFullName: config.packageFullName };
}
module.exports = { initialize, APP_ID };
