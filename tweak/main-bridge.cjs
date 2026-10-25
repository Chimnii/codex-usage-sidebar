'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
let current = null;
const PROVIDERS = [['codex', 'Codex'], ['claude', 'Claude'], ['antigravity', 'Antigravity Gemini']];
const MAX_OUTPUT = 256 * 1024;
// Packaged tweaks carry the collector locally; source checkouts keep it separate.
const COLLECTOR_ROOT = fs.existsSync(path.join(__dirname, 'collector/config.cjs'))
  ? path.join(__dirname, 'collector') : path.join(__dirname, '../collector');
const { normalizeUsageSettings } = require(path.join(COLLECTOR_ROOT, 'settings.cjs'));
const { ERRORS } = require(path.join(COLLECTOR_ROOT, 'collector.cjs'));

function initialSnapshot() {
  return { version: 1, updatedAt: null, providers: PROVIDERS.map(([id, label]) => ({
    id, label, status: id === 'claude' ? 'disconnected' : 'unavailable', checkedAt: null,
    attemptedAt: null, windows: [], error: null
  })) };
}

function sanitizeSnapshot(value) {
  if (value?.version !== 1 || !Array.isArray(value.providers)) throw new Error('invalid snapshot');
  const result = initialSnapshot();
  const date = v => typeof v === 'string' && Number.isFinite(Date.parse(v)) ? v : null;
  result.updatedAt = date(value.updatedAt);
  for (const target of result.providers) {
    const source = value.providers.find(p => p?.id === target.id);
    if (!source || !['ok', 'stale', 'unavailable', 'disconnected'].includes(source.status) || !Array.isArray(source.windows)) throw new Error('invalid provider');
    if (source.status === 'disconnected' && (target.id === 'codex' || source.windows.length)) throw new Error('invalid disconnected provider');
    target.status = source.status;
    if (source.disabled === true && source.status === 'disconnected') target.disabled = true;
    target.checkedAt = date(source.checkedAt);
    target.attemptedAt = date(source.attemptedAt);
    target.error = source.error ? '사용량을 갱신하지 못했습니다.' : null;
    target.errorCode = Object.hasOwn(ERRORS, source.errorCode) ? source.errorCode : null;
    target.nextAttemptAt = date(source.nextAttemptAt);
    target.durationMs = Number.isFinite(source.durationMs) ? Math.min(120000, Math.max(0, Math.round(source.durationMs))) : null;
    target.consecutiveFailures = Number.isInteger(source.consecutiveFailures) ? Math.min(100000, Math.max(0, source.consecutiveFailures)) : 0;
    target.windows = source.windows.slice(0, 20).map(w => {
      if (typeof w?.usedPercent !== 'number' || !Number.isFinite(w.usedPercent) || w.usedPercent < 0 || w.usedPercent > 100) throw new Error('invalid usage');
      return { id: String(w.id || '').slice(0, 160), label: String(w.label || '').slice(0, 160), usedPercent: w.usedPercent, resetsAt: date(w.resetsAt) };
    });
    if (target.status === 'ok' && !target.windows.length) throw new Error('empty successful usage');
  }
  return result;
}

function failedSnapshot(previous) {
  return { ...previous, updatedAt: new Date().toISOString(), providers: previous.providers.map(p => p.status === 'disconnected' ? p : ({
    ...p, status: p.windows.length ? 'stale' : 'unavailable', attemptedAt: new Date().toISOString(), error: '사용량을 갱신하지 못했습니다.',
    errorCode: 'RPC_ERROR', consecutiveFailures: Math.min(100000, (p.consecutiveFailures || 0) + 1)
  })) };
}

function mergeSnapshots(previous, next) {
  return { ...next, providers: next.providers.map(p => {
    if (p.status === 'ok' || p.disabled === true) return p;
    const old = previous.providers.find(v => v.id === p.id);
    if (!old?.windows.length) return p;
    if (p.windows.length && Date.parse(p.checkedAt) > Date.parse(old.checkedAt)) return p;
    return { ...p, status: 'stale', checkedAt: old.checkedAt, windows: old.windows };
  }) };
}

function killOwnedTree(child) {
  if (!child?.pid || child.exitCode !== null) return;
  if (process.platform === 'win32') {
    const killer = spawn(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'taskkill.exe'), ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    killer.on('error', () => { try { child.kill(); } catch {} });
  } else child.kill('SIGTERM');
}

function sanitizeUiReport(value) {
  // Only bounded counts/booleans cross into persisted verification evidence.
  // Never save messages, thread titles, URLs, DOM text, or input contents.
  if (!value || typeof value !== 'object' || value.detectorVersion !== 2) throw new Error('invalid UI report');
  const count = key => {
    if (!Number.isInteger(value[key]) || value[key] < 0 || value[key] > 100000) throw new Error('invalid UI count');
    return value[key];
  };
  const flag = key => {
    if (typeof value[key] !== 'boolean') throw new Error('invalid UI flag');
    return value[key];
  };
  if (value.claudeRows !== undefined) count('claudeRows');
  return {
    detectorVersion: 2,
    mountedPanels: count('mountedPanels'), visiblePanels: count('visiblePanels'),
    sidebarLinkCount: count('sidebarLinkCount'), withinSidebar: flag('withinSidebar'),
    composerPresent: flag('composerPresent'), snagDetected: flag('snagDetected'),
    claudeRows: value.claudeRows ?? 0,
    hiddenBySettings: value.hiddenBySettings === undefined ? false : flag('hiddenBySettings'),
    reportedAt: new Date().toISOString()
  };
}

function start(api) {
  stop();
  const { app, ipcMain } = require('electron');
  const configPath = path.join(api.fs.dataDir, 'collector-config.json');
  const statusPath = path.join(api.fs.dataDir, 'bridge-status.json');
  const channel = `codexpp:${api.manifest.id}:usage:get`;
  const refreshChannel = `codexpp:${api.manifest.id}:usage:refresh`;
  const reportChannel = `codexpp:${api.manifest.id}:usage:ui-report`;
  const updateChannel = `codexpp:${api.manifest.id}:update:launch`;
  const verificationEnabled = process.env.SIDEBAR_USAGE_VERIFY === '1';
  const state = { stopped: false, timer: null, child: null, timeout: null, snapshot: initialSnapshot(), cycles: 0, lastStarted: 0, startedAt: new Date().toISOString() };
  current = state;
  let config;
  try {
    config = require(path.join(COLLECTOR_ROOT, 'config.cjs')).resolveConfig(JSON.parse(fs.readFileSync(configPath, 'utf8')), configPath);
    if (!path.isAbsolute(config.nodePath) || !fs.existsSync(config.nodePath)) throw new Error('node missing');
    try {
      state.snapshot = sanitizeSnapshot(JSON.parse(fs.readFileSync(config.cachePath, 'utf8')));
      state.snapshot.providers.forEach(p => { if (p.status === 'ok') p.status = 'stale'; });
    } catch { /* No valid previous usage: keep unknown values. */ }
  } catch {
    config = null;
    api.log.warn('Usage collector configuration is unavailable.');
  }
  const usage = normalizeUsageSettings(config?.usage);
  const timings = Object.entries(usage.providers).filter(([id]) => id === 'codex' ||
    (config?.providerEnabled?.[id] !== false && (config?.providerEnabled?.[id] === true || (id === 'claude' ? config?.claudeCredentialsPath : config?.agyPath)))).map(([, timing]) => timing);
  const intervalMs = Math.min(...timings.map(p => p.intervalSeconds * 1000));
  const timeoutMs = Math.max(...timings.map(p => p.timeoutSeconds * 1000)) + 5000;
  let locale = Intl.DateTimeFormat().resolvedOptions().locale;
  try { locale = app.getLocale?.() || locale; } catch { /* Some Electron builds require app readiness. */ }
  const language = usage.language === 'auto' ? (locale.startsWith('ko') ? 'ko' : 'en') : usage.language;
  // Hide deliberately disabled providers immediately, including cached older data.
  for (const provider of state.snapshot.providers) {
    if (provider.id === 'codex' || !config) continue;
    const file = provider.id === 'claude' ? config.claudeCredentialsPath : config.agyPath;
    if (config.providerEnabled?.[provider.id] === false || (!file && config.providerEnabled?.[provider.id] !== true)) {
      Object.assign(provider, { disabled: true, status: 'disconnected', windows: [], checkedAt: null });
    }
  }
  const updater = config?.projectRoot && process.env.SIDEBAR_USAGE_PACKAGE
    ? require('./update-bridge.cjs').createUpdateController({ projectRoot: config.projectRoot,
      dataDir: api.fs.dataDir, runningPackage: process.env.SIDEBAR_USAGE_PACKAGE, log: api.log }) : null;
  let updateMenu = null;
  if (updater) {
    try { updateMenu = require('./update-menu.cjs').createUpdateMenu({ ...require('electron'), updater, log: api.log, language }); }
    catch { api.log.warn('Help menu update integration is unavailable; automatic Store checks remain enabled.'); }
  }

  function record(extra = {}) {
    try { fs.writeFileSync(statusPath, JSON.stringify({
      startedAt: state.startedAt, intervalMs, cycles: state.cycles,
      collectorPid: state.child?.pid ?? null, active: !!state.child, stopped: state.stopped,
      updateMenuEntries: updateMenu?.getPatchedCount() ?? 0,
      updateMenuHealth: updateMenu?.getHealth?.() ?? null,
      updatedAt: state.snapshot.updatedAt, providers: state.snapshot.providers.map(p => ({ id: p.id, status: p.status, disabled: p.disabled === true,
        checkedAt: p.checkedAt, attemptedAt: p.attemptedAt, nextAttemptAt: p.nextAttemptAt,
        errorCode: p.errorCode, durationMs: p.durationMs, consecutiveFailures: p.consecutiveFailures })),
      ...(verificationEnabled ? {
        launchId: process.env.SIDEBAR_USAGE_LAUNCH_ID || null,
        runtime: { executable: process.execPath, userData: app.getPath('userData'), codexHome: config?.codexHome || process.env.CODEX_HOME || null },
        ui: state.ui || null
      } : {}), ...extra
    }, null, 2)); } catch { /* Diagnostics cannot interrupt the UI. */ }
  }
  function schedule() {
    if (state.stopped) return;
    clearTimeout(state.timer);
    state.timer = setTimeout(() => run(), intervalMs);
    state.timer.unref?.();
  }
  function run(forceRefresh = false) {
    if (state.stopped || state.child) return;
    clearTimeout(state.timer); state.timer = null;
    if (!config) { state.snapshot = failedSnapshot(state.snapshot); record(); schedule(); return; }
    const started = Date.now();
    state.lastStarted = started;
    state.cycles++;
    let stdout = '', overflow = false, finished = false;
    const env = { ...process.env };
    delete env.ELECTRON_RUN_AS_NODE;
    delete env.NODE_OPTIONS;
    const child = spawn(config.nodePath, [path.join(COLLECTOR_ROOT, 'collect.cjs'), '--config', configPath, ...(forceRefresh ? ['--refresh'] : [])], {
      windowsHide: true, cwd: config.workDir, env, stdio: ['pipe', 'pipe', 'pipe']
    });
    state.child = child;
    record({ cycleStartedAt: new Date(started).toISOString() });
    child.stdin.on('error', () => {});
    child.stderr.resume(); // Never persist raw CLI diagnostics or credentials.
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      if (overflow) return;
      stdout += chunk;
      if (stdout.length > MAX_OUTPUT && !overflow) { overflow = true; stdout = ''; killOwnedTree(child); }
    });
    state.timeout = setTimeout(() => { overflow = true; killOwnedTree(child); }, timeoutMs);
    function finish(code) {
      if (finished) return;
      finished = true;
      clearTimeout(state.timeout);
      state.timeout = null;
      state.child = null;
      if (state.stopped) return;
      try {
        if (code !== 0 || overflow) throw new Error('collector failed');
        state.snapshot = mergeSnapshots(state.snapshot, sanitizeSnapshot(JSON.parse(stdout)));
      } catch { state.snapshot = failedSnapshot(state.snapshot); }
      record({ cycleCompletedAt: new Date().toISOString(), durationMs: Date.now() - started, nextRefreshAt: new Date(Date.now() + intervalMs).toISOString() });
      schedule();
    }
    child.on('error', () => finish(-1));
    child.on('close', code => finish(code));
  }

  ipcMain.removeHandler(channel);
  ipcMain.removeHandler(refreshChannel);
  ipcMain.removeHandler(reportChannel);
  ipcMain.removeHandler(updateChannel);
  api.ipc.handle('usage:get', () => ({ ...state.snapshot, usage: { ...usage, language }, collecting: !!state.child,
    diagnosticsEnabled: verificationEnabled, appUpdate: updater?.getState() }));
  api.ipc.handle('usage:refresh', request => {
    if (state.stopped || !config) return { ok: false };
    const resume = request?.reason === 'resume';
    if (state.child || Date.now() - state.lastStarted < (resume ? intervalMs : 10000)) return { ok: true, collecting: !!state.child };
    run(!resume); return { ok: true, collecting: true };
  });
  api.ipc.handle('update:launch', () => updater?.launch() || { ok: false });
  api.ipc.handle('usage:ui-report', report => {
    if (!verificationEnabled || state.stopped) return false;
    try { state.ui = sanitizeUiReport(report); record(); return true; } catch { return false; }
  });
  const onExit = () => state.child?.stdin.destroy();
  const onQuit = () => state.stop();
  process.once('exit', onExit);
  app.on('before-quit', onQuit);
  state.stop = () => {
    if (state.stopped) return;
    state.stopped = true;
    clearTimeout(state.timer); clearTimeout(state.timeout);
    updateMenu?.stop();
    updater?.stop();
    const child = state.child;
    if (child) { child.stdin.end(); killOwnedTree(child); }
    state.child = null;
    ipcMain.removeHandler(channel);
    ipcMain.removeHandler(refreshChannel);
    ipcMain.removeHandler(reportChannel);
    ipcMain.removeHandler(updateChannel);
    app.removeListener('before-quit', onQuit);
    process.removeListener('exit', onExit);
    record();
    if (current === state) current = null;
  };
  run();
}

function stop() { current?.stop?.(); }
module.exports = { start, stop, initialSnapshot, sanitizeSnapshot, failedSnapshot, mergeSnapshots, sanitizeUiReport };
