'use strict';
const fs = require('node:fs');
const path = require('node:path');
const APP_ID = 'Local.CodexUsageSidebar';
const DISPLAY_NAME = 'ChatGPT with usage';

function displayTitle() {
  // Keep conversation names out of native window/taskbar captions. The app's
  // own chat headings and document content remain under its control.
  return DISPLAY_NAME;
}

function installWindowIdentity(electron, root, dependencies = {}) {
  const { app, BrowserWindow, nativeTheme } = electron;
  if (typeof app.on !== 'function') return;
  const exists = dependencies.existsFile || fs.existsSync;
  const executable = path.join(root, 'app', 'ChatGPT.exe');
  const seen = new WeakSet();
  const nativeApplied = new WeakMap();
  const safely = action => { try { action(); } catch (error) { (dependencies.warn || console.warn)('[usage-sidebar] Window appearance:', error.message); } };
  const iconPath = () => {
    const dark = nativeTheme?.shouldUseDarkColorsForSystemIntegratedUI ?? nativeTheme?.shouldUseDarkColors ?? false;
    return ['chatgpt-app-' + (dark ? 'dark' : 'light') + '.ico', 'icon-chatgpt.ico']
      .map(name => path.join(root, 'app/resources', name)).find(exists);
  };
  const apply = win => {
    if (!win || win.isDestroyed?.()) return;
    const icon = iconPath();
    safely(() => win.setAppDetails?.({ appId: APP_ID, relaunchCommand: '"' + executable + '"', relaunchDisplayName: DISPLAY_NAME,
      ...(icon ? { appIconPath: icon, appIconIndex: 0 } : {}) }));
    if (icon) safely(() => win.setIcon?.(icon));
    // Owl currently omits setAppDetails. Use Windows' property store only for
    // that missing API; keep the original app, binary resources and profile intact.
    if (typeof win.setAppDetails !== 'function' && typeof win.getNativeWindowHandle === 'function' &&
        dependencies.projectRoot && nativeApplied.get(win) !== (icon || executable)) {
      safely(() => {
        const handle = win.getNativeWindowHandle();
        const number = handle.length === 8 ? handle.readBigUInt64LE() : BigInt(handle.readUInt32LE());
        const proc = dependencies.process || process;
        const spawn = dependencies.spawn || require('node:child_process').spawn;
        const child = spawn(path.join(proc.env.SystemRoot || 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe'),
          ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(dependencies.projectRoot, 'scripts/Set-UsageWindowIdentity.ps1'),
            '-WindowHandle', number.toString(), '-Executable', executable, '-IconPath', icon || executable],
          { windowsHide: true, stdio: 'ignore', timeout: 15000 });
        nativeApplied.set(win, icon || executable);
        child.on('error', error => { nativeApplied.delete(win); (dependencies.warn || console.warn)('[usage-sidebar] Window identity:', error.message); });
        child.on('exit', code => { if (code) nativeApplied.delete(win); });
        child.unref();
      });
    }
  };
  const attach = win => {
    if (!win || seen.has(win) || win.isDestroyed?.()) return;
    seen.add(win);
    // Only presentation changes. Leave app.getName(), userData, sessionData and
    // all other profile paths under the original application's control.
    if (typeof win.setTitle === 'function') {
      const setTitle = win.setTitle.bind(win);
      win.setTitle = title => setTitle(displayTitle(title));
      win.on?.('page-title-updated', (event, title) => {
        event.preventDefault();
        if (!win.isDestroyed?.()) win.setTitle(title);
      });
      win.setTitle(win.getTitle?.());
    }
    apply(win);
  };
  app.on('browser-window-created', (_event, win) => attach(win));
  const update = () => { for (const win of BrowserWindow?.getAllWindows?.() || []) apply(win); };
  nativeTheme?.on?.('updated', update);
  app.once?.('will-quit', () => nativeTheme?.removeListener?.('updated', update));
  app.whenReady?.().then(() => { for (const win of BrowserWindow?.getAllWindows?.() || []) attach(win); }).catch(() => {});
}

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

function originalAppRunning(config, dependencies = {}) {
  const proc = dependencies.process || process;
  const list = dependencies.listExecutablePaths || (() => {
    const query = "$ErrorActionPreference='Stop'; $env:PSModulePath=(Join-Path $PSHOME 'Modules')+';'+$env:PSModulePath; ConvertTo-Json -Compress -InputObject @(Get-CimInstance Win32_Process -Filter \"Name = 'ChatGPT.exe'\" | Where-Object ExecutablePath | Select-Object -ExpandProperty ExecutablePath)";
    const output = (dependencies.execFileSync || require('node:child_process').execFileSync)(
      path.join(proc.env.SystemRoot || 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe'),
      ['-NoProfile', '-NonInteractive', '-Command', query],
      { windowsHide: true, timeout: 3000, maxBuffer: 65536, encoding: 'utf8' });
    return JSON.parse(output.replace(/^\uFEFF/, '').trim());
  });
  try {
    const source = typeof config.sourceAppDir === 'string' && path.win32.isAbsolute(config.sourceAppDir)
      ? path.win32.join(config.sourceAppDir, 'ChatGPT.exe').toLowerCase() : null;
    const paths = list();
    if (!Array.isArray(paths)) throw new Error('Unexpected process list');
    return paths.some(value => {
      if (typeof value !== 'string') return false;
      const file = path.win32.normalize(value);
      return (source && file.toLowerCase() === source) ||
        /\\WindowsApps\\OpenAI\.Codex_\d+\.\d+\.\d+\.\d+_x64__2p2nqsd0c76g0\\app\\ChatGPT\.exe$/i.test(file);
    });
  } catch (error) {
    // This optional warning must not break startup when Windows process lookup
    // is unavailable. The app's own single-instance behavior remains intact.
    (dependencies.warn || console.warn)('[usage-sidebar] Original app check:', error.message);
    return false;
  }
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
  if (proc.platform === 'win32' && originalAppRunning(config, dependencies)) {
    const { app, dialog } = load('electron');
    let korean = false;
    try { korean = app.getLocale?.().startsWith('ko'); } catch { }
    dialog.showErrorBox(DISPLAY_NAME, korean
      ? '원본 ChatGPT가 실행 중입니다. 두 앱은 로그인, 대화와 프로필을 공유합니다. 원본 앱을 완전히 종료한 뒤 ChatGPT with usage를 다시 실행하세요. 원본 앱은 종료하지 않았습니다.'
      : 'The original ChatGPT app is running. Both apps share your login, conversations and profile. Close the original completely, then open ChatGPT with usage again. The original app was left running.');
    app.exit(0);
    return { blocked: true, reason: 'original-running' };
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
  const electron = load('electron');
  const { app } = electron;
  if (proc.platform === 'win32') {
    const nativeSetId = app.setAppUserModelId.bind(app);
    app.setAppUserModelId = () => nativeSetId(APP_ID);
    app.setAppUserModelId(APP_ID);
    installWindowIdentity(electron, root, { ...dependencies, projectRoot: config.projectRoot });
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
module.exports = { initialize, updateInProgress, originalAppRunning, installWindowIdentity, displayTitle, APP_ID, DISPLAY_NAME };
