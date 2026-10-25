const { test } = require('node:test');
const assert = require('node:assert/strict');
const { initialSnapshot, sanitizeSnapshot, mergeSnapshots, failedSnapshot, sanitizeUiReport } = require('../tweak/main-bridge.cjs');

function successful(id, percent) {
  const s = initialSnapshot();
  Object.assign(s.providers.find(p => p.id === id), {
    status: 'ok', checkedAt: '2026-10-21T15:00:00Z',
    windows: [{ id: 'week', label: '7일', usedPercent: percent, resetsAt: '2026-10-28T15:00:00Z' }]
  });
  return s;
}

test('first failure leaves unknown quota and disconnected Claude', () => {
  const s = failedSnapshot(initialSnapshot());
  assert.deepEqual(s.providers.map(p => [p.id, p.status, p.windows.length]), [
    ['codex', 'unavailable', 0], ['claude', 'disconnected', 0], ['antigravity', 'unavailable', 0]
  ]);
});

test('collector cache loss cannot erase already displayed quota; other provider still updates', () => {
  const before = successful('codex', 47);
  const incoming = successful('antigravity', 99.4);
  incoming.providers.find(p => p.id === 'codex').error = 'failed';
  const result = mergeSnapshots(before, sanitizeSnapshot(incoming));
  assert.equal(result.providers[0].status, 'stale');
  assert.equal(result.providers[0].checkedAt, before.providers[0].checkedAt);
  assert.deepEqual(result.providers[0].windows, before.providers[0].windows);
  assert.equal(result.providers[2].status, 'ok');
  assert.equal(result.providers[2].windows[0].usedPercent, 99.4);
});

test('only real finite percentages reach renderer; real zero remains zero', () => {
  assert.equal(sanitizeSnapshot(successful('codex', 0)).providers[0].windows[0].usedPercent, 0);
  for (const invalid of [NaN, Infinity, null, '47', -1, 101]) {
    assert.throws(() => sanitizeSnapshot(successful('codex', invalid)));
  }
});

test('UI verification persists only bounded counts and flags, never conversation contents', () => {
  const report = { detectorVersion: 2, mountedPanels: 1, visiblePanels: 1, sidebarLinkCount: 25,
    withinSidebar: true, composerPresent: true, snagDetected: false, text: 'private conversation', url: 'private location' };
  const clean = sanitizeUiReport(report);
  assert.equal(clean.visiblePanels, 1);
  assert.equal(clean.composerPresent, true);
  assert.equal('text' in clean, false);
  assert.equal('url' in clean, false);
  assert.throws(() => sanitizeUiReport({ ...report, visiblePanels: '1' }));
  assert.throws(() => sanitizeUiReport({ ...report, sidebarLinkCount: 100001 }));
  assert.throws(() => sanitizeUiReport({ ...report, snagDetected: 'false' }));
  assert.equal(sanitizeUiReport({ ...report, hiddenBySettings: true }).hiddenBySettings, true);
  assert.throws(() => sanitizeUiReport({ ...report, hiddenBySettings: 'true' }));
  assert.throws(() => sanitizeUiReport({ ...report, detectorVersion: 1 }));
});

test('IPC permits only bounded error metadata and cannot expose raw diagnostics', () => {
  const snapshot = successful('codex', 42), provider = snapshot.providers[0];
  Object.assign(provider, { error: 'private-token', errorCode: 'TIMEOUT', nextAttemptAt: '2026-10-26T00:00:00Z', durationMs: 25, consecutiveFailures: 2, raw: 'private-token' });
  const clean = sanitizeSnapshot(snapshot);
  assert.equal(clean.providers[0].errorCode, 'TIMEOUT'); assert.equal(clean.providers[0].durationMs, 25);
  assert.equal(clean.providers[0].consecutiveFailures, 2); assert.doesNotMatch(JSON.stringify(clean), /private-token/);
  provider.errorCode = 'private-token'; provider.durationMs = Infinity; provider.consecutiveFailures = -5;
  const invalid = sanitizeSnapshot(snapshot).providers[0]; assert.equal(invalid.errorCode, null); assert.equal(invalid.durationMs, null); assert.equal(invalid.consecutiveFailures, 0);
});

test('bridge coalesces refreshes, keeps one timer, exposes optional settings and cleans its owned lifetime', () => {
  const vm = require('node:vm'), fs = require('node:fs'), path = require('node:path');
  const { EventEmitter } = require('node:events'), { PassThrough } = require('node:stream');
  const directory = path.resolve(__dirname, '../tweak'), handlers = new Map(), timers = [], children = [], writes = [];
  const app = new EventEmitter(); app.getLocale = () => 'en-US'; app.getPath = () => 'fixture-profile';
  const processFake = new EventEmitter(); Object.assign(processFake, { env: { NODE_OPTIONS: 'private-injection' }, execPath: process.execPath, platform: 'linux' });
  let now = Date.now();
  const config = { nodePath: process.execPath, workDir: directory, cachePath: path.join(directory, 'missing-cache.json'),
    providerEnabled: { antigravity: false, claude: false }, usage: { language: 'en', providers: { codex: { intervalSeconds: 120, timeoutSeconds: 2 } } } };
  const spawn = (exe, args, options) => {
    const child = new EventEmitter(); Object.assign(child, { pid: 1, exitCode: null, stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(), args, options });
    child.kill = () => { child.killed = true; }; children.push(child); return child;
  };
  const imports = name => name === 'electron' ? { app, ipcMain: { removeHandler: channel => handlers.delete(channel.split(':').slice(-2).join(':')) } }
    : name === 'node:fs' ? { existsSync: fs.existsSync, readFileSync: file => { if (file.endsWith('collector-config.json')) return JSON.stringify(config); throw Error('fixture missing'); }, writeFileSync: (_, data) => writes.push(JSON.parse(data)) }
    : name === 'node:child_process' ? { spawn } : require(name);
  const context = { module: { exports: {} }, require: imports, __dirname: directory, process: processFake,
    Date: class extends Date { static now() { return now; } }, setTimeout: (fn, ms) => { const timer = { fn, ms, unref() {} }; timers.push(timer); return timer; }, clearTimeout: timer => { if (timer) timer.cancelled = true; } };
  vm.runInNewContext(fs.readFileSync(path.join(directory, 'main-bridge.cjs'), 'utf8'), context);
  const bridge = context.module.exports, api = { fs: { dataDir: directory }, manifest: { id: 'fixture' }, log: { warn() {} }, ipc: { handle: (name, fn) => handlers.set(name, fn) } };
  bridge.start(api);
  assert.equal(children.length, 1); assert.equal(children[0].options.env.NODE_OPTIONS, undefined);
  assert.equal(handlers.get('usage:get')().usage.language, 'en'); assert.equal(handlers.get('usage:get')().providers[1].disabled, true);
  handlers.get('usage:refresh')(); handlers.get('usage:refresh')(); assert.equal(children.length, 1);
  function finish(child) { child.stdout.write(JSON.stringify(initialSnapshot())); child.exitCode = 0; child.emit('close', 0); }
  finish(children[0]); assert.equal(timers.filter(t => !t.cancelled).length, 1); assert.equal(timers.at(-1).ms, 120000);
  now += 11000; handlers.get('usage:refresh')({ reason: 'resume' }); assert.equal(children.length, 1, 'window switching must not increase collection frequency');
  handlers.get('usage:refresh')(); handlers.get('usage:refresh')(); assert.equal(children.length, 2);
  assert.equal(children[1].args.at(-1), '--refresh'); assert.equal(timers.filter(t => !t.cancelled).length, 1);
  bridge.stop(); const stoppedWrites = writes.length;
  finish(children[1]); assert.equal(writes.length, stoppedWrites); assert.equal(handlers.size, 0);
  assert.equal(timers.filter(t => !t.cancelled).length, 0); assert.equal(app.listenerCount('before-quit'), 0); assert.equal(processFake.listenerCount('exit'), 0);
});
