'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { spawn } = require('node:child_process');
const {
  MAX_OUTPUT_BYTES, failure, timestamp, parseCodex, parseAntigravity, killOwnedChild,
  mergeProvider, buildEnvironment, runProcess, collect, readCache,
} = require('./collector.cjs');

const at = '2026-10-22T00:00:00.000Z';
const later = '2026-10-22T00:01:00.000Z';
const codex = { rateLimitsByLimitId: {
  codex: { limitName: 'Codex', primary: { usedPercent: 47, windowDurationMins: 10080, resetsAt: 1803859200 }, secondary: null },
  review: { limitName: 'Code review', primary: { usedPercent: 1.2, windowDurationMins: 300 }, secondary: { usedPercent: 8, windowDurationMins: 10080 } },
} };
const agy = { status: 'SUCCESS', command: { name: 'usage', data: { groups: [
  { name: 'Gemini Models', buckets: [{ name: 'Weekly', window: 'weekly', remaining_fraction: 0.890483677, reset_time: at }, { name: '5 hours', window: 'five_hours', remaining_fraction: 1, reset_time: later }] },
  { name: 'Claude and GPT models', buckets: [{ name: 'Shared', remaining_fraction: 0 }] },
  { name: 'Gemini 4 Argon', buckets: [{ name: 'Weekly', window: 'weekly', remaining_fraction: 0.005899466, reset_time: at }] },
] } } };

function mockChild() {
  const child = new EventEmitter();
  child.pid = 123456;
  child.exitCode = null;
  child.signalCode = null;
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  return child;
}

function configFor(dir) {
  return {
    codexPath: process.execPath, agyPath: process.execPath,
    codexHome: path.join(dir, 'codex'), userProfile: dir,
    appData: path.join(dir, 'roaming'), localAppData: path.join(dir, 'local'),
    workDir: dir, cachePath: path.join(dir, 'cache.json'), timeoutMs: 1000,
  };
}

test('Codex prefers multi-bucket results and preserves real windows, labels and reset time', () => {
  const rows = parseCodex({ ...codex, rateLimits: { primary: { usedPercent: 99 } } });
  assert.equal(rows.length, 3);
  assert.equal(rows[0].label, 'Codex · 7일');
  assert.equal(rows[0].usedPercent, 47);
  assert.equal(rows[0].resetsAt, new Date(1803859200 * 1000).toISOString());
  assert.equal(rows[1].label, 'Code review · 5시간');
  assert.equal(rows[1].usedPercent, 1.2);
  assert.equal(rows[2].resetsAt, null);
});

test('Codex legacy fallback remains usable without inventing missing secondary or five-hour window', () => {
  const rows = parseCodex({ rateLimitsByLimitId: {}, rateLimits: codex.rateLimitsByLimitId.codex });
  assert.equal(rows.length, 1);
  assert.match(rows[0].label, /7일/);
  assert.equal(timestamp('bad date'), null);
  assert.equal(timestamp(Infinity), null);
  assert.equal(timestamp(-100), null);
});

test('Gemini groups stay distinct, fractional usage retained, and Claude/GPT quotas excluded', () => {
  const rows = parseAntigravity(agy);
  assert.equal(rows.length, 3);
  assert.deepEqual(rows.map((row) => row.usedPercent), [11, 0, 99.4]);
  assert.match(rows[0].label, /Gemini Models.*Weekly.*7일/);
  assert.match(rows[1].label, /5 hours/);
  assert.match(rows[2].label, /Gemini 4 Argon/);
  assert.ok(rows.every((row) => !/claude|gpt/i.test(row.label)));
  assert.equal(rows[0].resetsAt, at);
});

test('Empty, malformed, out-of-range, non-finite and numeric-string values never become zero usage', () => {
  for (const value of [-1, 101, Infinity, NaN, '5', null]) {
    assert.throws(() => parseCodex({ rateLimits: { primary: { usedPercent: value } } }), { code: 'BAD_RESPONSE' });
  }
  for (const value of [-0.1, 1.1, Infinity, NaN, '0.5', null]) {
    const report = structuredClone(agy);
    report.command.data.groups[0].buckets[0].remaining_fraction = value;
    assert.throws(() => parseAntigravity(report), { code: 'BAD_RESPONSE' });
  }
  assert.throws(() => parseCodex({ rateLimits: { primary: null } }), { code: 'BAD_RESPONSE' });
  assert.throws(() => parseAntigravity({ status: 'SUCCESS', command: { name: 'usage', data: { groups: [agy.command.data.groups[1]] } } }), { code: 'BAD_RESPONSE' });
  assert.throws(() => parseAntigravity({ status: 'ERROR' }), { code: 'BAD_RESPONSE' });
});

test('Initial failure is unavailable; later failure preserves good values and exact successful timestamp', () => {
  const failed = { status: 'rejected', reason: new Error('secret-token=do-not-show') };
  const first = mergeProvider('codex', null, failed, at, null);
  assert.equal(first.status, 'unavailable');
  assert.deepEqual(first.windows, []);
  assert.equal(first.checkedAt, null);
  assert.ok(!first.error.includes('secret'));
  const good = mergeProvider('codex', null, { status: 'fulfilled', value: parseCodex(codex) }, at, at);
  const stale = mergeProvider('codex', good, failed, later, null);
  assert.equal(stale.status, 'stale');
  assert.equal(stale.checkedAt, at);
  assert.equal(stale.attemptedAt, later);
  assert.deepEqual(stale.windows, good.windows);
  assert.equal(mergeProvider('claude', null, failed, at, null).status, 'unavailable');
  assert.equal(mergeProvider('claude', null, { status: 'disconnected' }, null, null).status, 'disconnected');
});

test('CLI environment removes desktop injection and restores explicit profiles', () => {
  const config = { userProfile: 'real-profile', appData: 'real-roaming', localAppData: 'real-local', codexHome: 'chosen-codex' };
  const source = { PATH: 'preserve', USERPROFILE: 'test-profile', APPDATA: 'test-roaming', LOCALAPPDATA: 'test-local', ELECTRON_RUN_AS_NODE: '1', CODEX_HOME: 'test', CODEX_ELECTRON_USER_DATA_PATH: 'test', CODEXPP_REMOTE_DEBUG: '1', CODEX_PLUSPLUS_HOME: 'test', CLAUDECODE: '1', XDG_CACHE_HOME: 'test-cache' };
  const agyEnv = buildEnvironment(config, 'antigravity', source);
  assert.deepEqual(agyEnv, { PATH: 'preserve', USERPROFILE: 'real-profile', APPDATA: 'real-roaming', LOCALAPPDATA: 'real-local' });
  assert.equal(buildEnvironment(config, 'codex', source).CODEX_HOME, 'chosen-codex');
  assert.equal(source.CODEX_HOME, 'test');
});

test('Codex transport sends only initialize, initialized and usage; timer and child cleaned once', async () => {
  const child = mockChild();
  const packets = [];
  let kills = 0;
  child.stdin.on('data', (chunk) => {
    const packet = JSON.parse(chunk);
    packets.push(packet);
    if (packet.method === 'initialize') queueMicrotask(() => child.stdout.write(JSON.stringify({ id: 1, result: {} }) + '\n'));
    if (packet.method === 'account/rateLimits/read') queueMicrotask(() => child.stdout.write(JSON.stringify({ id: 2, result: codex }) + '\n'));
  });
  const windows = await runProcess('fake', [], { protocol: 'codex', timeoutMs: 50, spawnImpl: () => child, killImpl: async (owned) => { assert.equal(owned, child); kills++; } });
  assert.deepEqual(packets.map((packet) => packet.method), ['initialize', 'initialized', 'account/rateLimits/read']);
  assert.equal(windows.length, 3);
  assert.equal(kills, 1);
  await new Promise((resolve) => setTimeout(resolve, 75));
  assert.equal(kills, 1, 'cleared timeout must not run cleanup again');
});

test('Timeout, cancellation, output cap and spawn failure terminate only the owned child', async (t) => {
  await t.test('timeout', async () => {
    const child = mockChild(); let kills = 0;
    await assert.rejects(runProcess('fake', [], { timeoutMs: 20, spawnImpl: () => child, killImpl: async (owned) => { assert.equal(owned, child); kills++; } }), { code: 'TIMEOUT' });
    assert.equal(kills, 1);
  });
  await t.test('abort', async () => {
    const child = mockChild(); let kills = 0;
    const controller = new AbortController();
    const pending = runProcess('fake', [], { signal: controller.signal, timeoutMs: 100, spawnImpl: () => child, killImpl: async () => { kills++; } });
    controller.abort();
    await assert.rejects(pending, { code: 'ABORTED' });
    assert.equal(kills, 1);
  });
  await t.test('output cap', async () => {
    const child = mockChild(); let kills = 0;
    const pending = runProcess('fake', [], { timeoutMs: 100, spawnImpl: () => child, killImpl: async () => { kills++; } });
    child.stdout.write('x'.repeat(MAX_OUTPUT_BYTES + 1));
    await assert.rejects(pending, { code: 'OUTPUT_LIMIT' });
    assert.equal(kills, 1);
  });
  await t.test('failed spawn', async () => {
    await assert.rejects(runProcess('fake', [], { timeoutMs: 30, spawnImpl: () => { throw new Error('secret'); }, killImpl: async () => {} }), { code: 'START_FAILED' });
  });
});

test('Agy capture validates success JSON and discards stderr instead of leaking it', async () => {
  const child = mockChild();
  const pending = runProcess('fake', [], { timeoutMs: 100, spawnImpl: () => child, killImpl: async () => {} });
  child.stderr.write('private-user@email.invalid SECRET');
  child.stdout.write(JSON.stringify(agy));
  child.exitCode = 0;
  child.emit('close', 0);
  assert.equal((await pending).length, 3);
});

test('Atomic normalized cache survives provider failures; unconfigured Claude is never executed', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidebar-collector-fixture-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const config = configFor(dir);
  let calls = 0;
  const first = await collect(config, { now: () => at, runProcessImpl: async (file, args, options) => { calls++; return options.protocol === 'codex' ? parseCodex(codex) : parseAntigravity(agy); } });
  assert.equal(calls, 2);
  assert.equal(first.providers[2].status, 'disconnected');
  const saved = JSON.parse(fs.readFileSync(config.cachePath, 'utf8'));
  assert.deepEqual(saved, first);
  const next = await collect(config, { now: () => later, runProcessImpl: async () => { throw failure('TIMEOUT'); } });
  assert.equal(next.providers[0].status, 'stale');
  assert.equal(next.providers[1].status, 'stale');
  assert.deepEqual(next.providers[0].windows, first.providers[0].windows);
  assert.equal(next.providers[0].checkedAt, at);
  assert.equal(next.providers[0].attemptedAt, later);
  assert.equal(fs.readdirSync(dir).filter((name) => name.endsWith('.tmp')).length, 0);
  fs.writeFileSync(config.cachePath, '{malformed');
  assert.deepEqual(await readCache(config.cachePath), {});
  const initialFailure = await collect(config, { now: () => later, runProcessImpl: async () => { throw failure('TIMEOUT'); } });
  assert.equal(initialFailure.providers[0].status, 'unavailable');
  assert.deepEqual(initialFailure.providers[0].windows, []);
});

test('Real fixture child is gone after bounded timeout (no real service CLI)', async () => {
  let owned;
  await assert.rejects(runProcess(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
    timeoutMs: 100,
    spawnImpl: (...args) => { owned = spawn(...args); return owned; },
  }), { code: 'TIMEOUT' });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.ok(owned.exitCode !== null || owned.signalCode !== null);
});

test('Collector CLI emits exactly one JSON snapshot and exits while parent stdin remains open', async () => {
  const child = spawn(process.execPath, [path.join(__dirname, 'collect.cjs'), '--config', path.join(__dirname, 'does-not-exist.json')], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  child.stdout.setEncoding('utf8').on('data', (data) => { stdout += data; });
  child.stderr.setEncoding('utf8').on('data', (data) => { stderr += data; });
  const code = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill(); reject(new Error('Fixture CLI did not exit')); }, 3000);
    child.once('close', (value) => { clearTimeout(timer); resolve(value); });
    child.once('error', reject);
  });
  assert.equal(code, 0);
  assert.equal(stderr, '');
  assert.equal(stdout.trim().split('\n').length, 1);
  assert.equal(JSON.parse(stdout).providers[0].status, 'unavailable');
});

test('Collector stdin EOF cancels and kills owned fixture children (no real service CLI)', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidebar-eof-fixture-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const pidPath = path.join(dir, 'pids.txt');
  const fixturePath = path.join(dir, 'fixture.cjs');
  const preloadPath = path.join(dir, 'preload.cjs');
  fs.writeFileSync(fixturePath, `require('node:fs').appendFileSync(${JSON.stringify(pidPath)}, process.pid + '\\n'); setInterval(() => {}, 1000);`);
  fs.writeFileSync(preloadPath, `const cp = require('node:child_process'); const original = cp.spawn; cp.spawn = (file, args, options) => /taskkill\\.exe$/i.test(file) ? original(file, args, options) : original(process.execPath, [${JSON.stringify(fixturePath)}], options);`);
  const config = configFor(dir);
  config.timeoutMs = 10000;
  const configPath = path.join(dir, 'config.json');
  fs.writeFileSync(configPath, JSON.stringify(config));
  const child = spawn(process.execPath, ['--require', preloadPath, path.join(__dirname, 'collect.cjs'), '--config', configPath], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  t.after(async () => { await killOwnedChild(child); });
  let stdout = '', stderr = '';
  child.stdout.setEncoding('utf8').on('data', (data) => { stdout += data; });
  child.stderr.setEncoding('utf8').on('data', (data) => { stderr += data; });
  const exit = new Promise((resolve, reject) => {
    const timer = setTimeout(() => { killOwnedChild(child).finally(() => reject(new Error('EOF fixture did not exit'))); }, 5000);
    child.once('close', (value) => { clearTimeout(timer); resolve(value); });
    child.once('error', reject);
  });
  const start = Date.now();
  let pids = [];
  while (Date.now() - start < 3000) {
    try { pids = fs.readFileSync(pidPath, 'utf8').trim().split('\n').filter(Boolean).map(Number); } catch {}
    if (pids.length === 2) break;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.equal(pids.length, 2);
  child.stdin.end();
  assert.equal(await exit, 0);
  assert.equal(stderr, '');
  const snapshot = JSON.parse(stdout);
  assert.ok(snapshot.providers.slice(0, 2).every((provider) => provider.status === 'unavailable' && provider.error === '사용량 조회 취소'));
  for (const pid of pids) {
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' }, `fixture PID ${pid} should be gone`);
  }
});
