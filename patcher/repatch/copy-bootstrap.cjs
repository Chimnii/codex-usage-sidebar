'use strict';
const fs = require('node:fs');
const path = require('node:path');
const APP_ID = 'Local.CodexUsageSidebar';

function updateInProgress(projectRoot, token, dependencies = {}) {
  if (!projectRoot || !path.isAbsolute(projectRoot)) return false;
  const read = dependencies.readFile || (file => fs.readFileSync(file, 'utf8'));
  const isLocked = dependencies.isUpdateLocked || (file => {
    let fd;
    try { fd = fs.openSync(file, 'r+'); return false; }
    catch (error) { return ['EBUSY', 'EACCES', 'EPERM'].includes(error.code); }
    finally { if (fd !== undefined) fs.closeSync(fd); }
  });
  const base = path.join(projectRoot, '.local/copy');
  let marker;
  try {
    const value = read(path.join(base, 'update-in-progress.json'));
    if (value.length > 4096) throw new Error('Invalid update marker');
    marker = JSON.parse(value);
    if (marker.schemaVersion !== 1 || !/^[a-f0-9]{32}$/.test(marker.ownerToken)) throw new Error('Invalid update marker');
  } catch (error) {
    // A missing/unreadable marker must not bypass a currently owned update.
    // A malformed leftover cannot block startup after its OS lock is released.
    return isLocked(path.join(base, 'update.lock'));
  }
  const time = (dependencies.now || Date.now)();
  const started = Date.parse(marker.startedAt), expires = Date.parse(marker.expiresAt);
  if (!Number.isFinite(started) || !Number.isFinite(expires) || started > time + 60000
      || expires <= time || expires - started > 26 * 60 * 60 * 1000) return false;
  if (token === marker.ownerToken) return false;
  return isLocked(path.join(base, 'update.lock'));
}

function initialize(archiveDir, dependencies = {}) {
  const proc = dependencies.process || process;
  const load = dependencies.require || require;
  const read = dependencies.readFile || (file => fs.readFileSync(file, 'utf8'));
  const root = path.resolve(archiveDir, '../../..');
  const config = JSON.parse(read(path.join(root, 'copy-startup.json')));
  if (config.schemaVersion !== 1 || config.appUserModelId !== APP_ID || !config.packageFullName) {
    throw new Error('Invalid managed copy startup settings');
  }
  const ownerToken = proc.env.SIDEBAR_USAGE_UPDATE_OWNER;
  delete proc.env.SIDEBAR_USAGE_UPDATE_OWNER;
  if (updateInProgress(config.projectRoot, ownerToken, dependencies)) {
    const { app, dialog } = load('electron');
    let korean = false;
    try { korean = app.getLocale?.().startsWith('ko'); } catch { /* Locale may not be ready yet. */ }
    dialog.showErrorBox(korean ? '업데이트 진행 중' : 'Update in progress', korean
      ? '업데이트 도우미가 대기 중이거나 복사본을 갱신하고 있습니다. 도우미가 완료 후 앱을 실행합니다. 취소하려면 도우미 창을 닫은 뒤 다시 실행하세요.'
      : 'The update helper is waiting or preparing the copy. It will open the app when finished. To cancel, close the helper window, then try again.');
    app.exit(0);
    return { blocked: true };
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
module.exports = { initialize, updateInProgress, APP_ID };
