'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const INTERVAL = 6 * 60 * 60 * 1000;
const RETRY = 60 * 60 * 1000;

function sanitizeStatus(value) {
  const storeStatus = value?.storeStatus || (value?.storeUpdateAvailable ? 'available' : 'current');
  const storeCheckedAt = value?.storeStatus ? value.storeCheckedAt : value?.checkedAt;
  if (value?.schemaVersion !== 1 || !['current', 'available', 'error', 'unknown'].includes(value.status)
      || !Number.isFinite(Date.parse(value.checkedAt))
      || !/^OpenAI\.Codex_\d+\.\d+\.\d+\.\d+_x64__2p2nqsd0c76g0$/.test(value.installedPackage)
      || !/^\d+\.\d+\.\d+\.\d+$/.test(value.installedVersion)
      || typeof value.storeUpdateAvailable !== 'boolean' || typeof value.copyUpdateRequired !== 'boolean'
      || !['current', 'available', 'error', 'unchecked'].includes(storeStatus)
      || (storeCheckedAt !== null && !Number.isFinite(Date.parse(storeCheckedAt)))
      || (value.status === 'available') !== (value.storeUpdateAvailable || value.copyUpdateRequired)
      || (value.status === 'current' && storeStatus !== 'current')
      || (storeStatus === 'available' && !value.storeUpdateAvailable)
      || (storeStatus === 'unchecked' && storeCheckedAt !== null)) {
    throw new Error('Invalid Store update status');
  }
  return { ...Object.fromEntries(['schemaVersion', 'status', 'checkedAt', 'installedPackage', 'installedVersion',
    'storeUpdateAvailable', 'copyUpdateRequired'].map(key => [key, value[key]])), storeStatus, storeCheckedAt,
    storeError: ['metadata-pending', 'query-failed'].includes(value.storeError) ? value.storeError : null };
}

function createUpdateController({ projectRoot, dataDir, runningPackage, log }, dependencies = {}) {
  const spawnProcess = dependencies.spawn || spawn;
  const now = dependencies.now || Date.now;
  const later = dependencies.setTimeout || setTimeout;
  const cancel = dependencies.clearTimeout || clearTimeout;
  const read = dependencies.readFile || (file => fs.readFileSync(file, 'utf8'));
  const write = dependencies.writeFile || ((file, value) => fs.writeFileSync(file, value));
  const powershell = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe');
  const cache = path.join(dataDir, 'update-status.json');
  let stopped = false, timer = null, checker = null, abortQuery = null, helper = null, inFlight = null, flightLocal = false, scheduleId = 0;
  let state = { schemaVersion: 1, status: 'unknown', checkedAt: null, stale: false, waiting: false, checking: false };
  try {
    const old = sanitizeStatus(JSON.parse(read(cache)));
    if (now() - Date.parse(old.checkedAt) >= 0 && now() - Date.parse(old.checkedAt) < INTERVAL) state = { ...old, stale: old.storeStatus === 'error', waiting: false, checking: false };
  } catch { /* First launch has no update status. */ }

  function query(localOnly) {
    if (dependencies.query) return dependencies.query(localOnly);
    return new Promise((resolve, reject) => {
      const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(projectRoot, 'scripts/Update-UsageCopy.ps1'),
        '-ProjectRoot', projectRoot, '-CheckOnly', '-Json', '-RunningPackageFullName', runningPackage];
      if (localOnly) args.push('-LocalOnly');
      const child = spawnProcess(powershell, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      checker = child;
      let text = '', settled = false;
      const finish = (error, value) => {
        if (settled) return;
        settled = true; cancel(timeout);
        if (checker === child) { checker = null; abortQuery = null; }
        if (error) reject(error); else resolve(value);
      };
      const terminate = () => { if (settled) return; try { child.kill(); } catch {} finish(new Error('Update query stopped')); };
      const timeout = later(terminate, localOnly ? 30000 : 200000);
      abortQuery = terminate;
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', chunk => { if (settled) return; text += chunk; if (text.length > 65536) { text = ''; terminate(); } });
      child.stderr.resume();
      child.on('error', error => finish(error));
      child.on('close', code => {
        if (settled) return;
        try { if (code !== 0) throw new Error('Update query failed'); finish(null, JSON.parse(text.replace(/^\uFEFF/, '').trim())); }
        catch (error) { finish(error); }
      });
    });
  }
  function schedule(delay, localOnly = false) {
    cancel(timer); timer = null;
    const id = ++scheduleId;
    if (stopped) return;
    timer = later(() => { if (stopped || id !== scheduleId) return; timer = null; return check(localOnly); }, delay);
    timer?.unref?.();
  }
  function check(localOnly = false) {
    if (stopped) return Promise.resolve({ ok: false, reason: 'stopped' });
    // A Help click during the cheap startup check still obtains a Store result.
    if (inFlight) return !localOnly && flightLocal ? inFlight.then(() => check()) : inFlight;
    flightLocal = localOnly;
    cancel(timer); timer = null; ++scheduleId;
    state = { ...state, checking: true };
    let delay = INTERVAL;
    // A shared promise lets a manual click await the exact background request.
    // Defer query so even a synchronous adapter cannot race promise assignment.
    inFlight = Promise.resolve().then(() => { if (stopped) throw new Error('Stopped'); return query(localOnly); }).then(value => {
      let result = sanitizeStatus(value);
      if (stopped) return { ok: false, reason: 'stopped' };
      if (localOnly && result.storeStatus === 'unchecked') {
        // Do not let a startup comparison renew the six-hour Store timestamp.
        const samePackage = result.installedPackage === state.installedPackage;
        if (samePackage && state.storeStatus) {
          result = { ...result, storeStatus: state.storeStatus, storeCheckedAt: state.storeCheckedAt,
            storeError: state.storeError, storeUpdateAvailable: !!state.storeUpdateAvailable };
        }
        result.status = result.copyUpdateRequired || result.storeUpdateAvailable ? 'available'
          : result.storeStatus === 'current' ? 'current' : result.storeStatus === 'error' ? 'error' : 'unknown';
        const last = Date.parse(result.storeCheckedAt), interval = result.storeStatus === 'error' ? RETRY : INTERVAL;
        delay = Number.isFinite(last) ? Math.max(0, interval - (now() - last)) : 0;
      } else if (result.storeStatus === 'error') {
        delay = RETRY;
        // Keep an earlier update notification, but explicitly mark its Store
        // evidence stale. A fresh local comparison is still usable offline.
        if (result.installedPackage === state.installedPackage && state.storeUpdateAvailable) {
          result = { ...result, status: 'available', storeUpdateAvailable: true };
        }
      }
      state = { ...result, stale: result.storeStatus === 'error', waiting: !!helper, checking: false };
      try { write(cache, JSON.stringify(result)); } catch { /* Cache is optional. */ }
      const ok = result.storeStatus !== 'error' || result.copyUpdateRequired;
      return { ok, ...(ok ? {} : { reason: 'check-failed' }), state: { ...state } };
    }).catch(() => {
      if (stopped) return { ok: false, reason: 'stopped' };
      state = { ...state, status: state.status === 'available' ? 'available' : 'error', storeStatus: 'error', storeError: 'query-failed', stale: true, checking: false };
      delay = RETRY;
      log?.warn?.('Store update check failed; retaining the last status.');
      // Explicit failure is separate from the retained last successful status.
      return { ok: false, reason: 'check-failed', state: { ...state } };
    }).finally(() => { inFlight = null; if (!stopped) schedule(delay); });
    return inFlight;
  }
  async function launch() {
    if (stopped || state.status !== 'available') return { ok: false };
    if (helper) return { ok: true, waiting: true };
    // Only a fixed local script can be launched. Renderer arguments are ignored.
    return new Promise(resolve => {
      let child;
      try {
        child = spawnProcess(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
          path.join(projectRoot, 'scripts/Run-UsageUpdateHelper.ps1'), '-ProjectRoot', projectRoot],
        { cwd: projectRoot, detached: true, windowsHide: false, stdio: 'ignore' });
      } catch { resolve({ ok: false }); return; }
      helper = child;
      child.once('spawn', () => { state.waiting = true; child.unref(); resolve({ ok: true, waiting: true }); });
      child.once('error', () => { if (helper === child) helper = null; state.waiting = false; resolve({ ok: false }); });
      child.once('exit', () => { if (helper === child) helper = null; state.waiting = false; });
    });
  }
  // Always compare the registered local original soon after launch; remote
  // checks retain their independent six-hour cadence and a single timer.
  schedule(10000, true);
  return {
    getState: () => ({ ...state }), check, launch,
    stop() { stopped = true; cancel(timer); timer = null; ++scheduleId; state.checking = false; abortQuery?.(); /* Detached updater survives normal app exit. */ }
  };
}
module.exports = { createUpdateController, sanitizeStatus, INTERVAL, RETRY };
