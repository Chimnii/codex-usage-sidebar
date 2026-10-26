'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { normalizeUsageSettings } = require('../collector/settings.cjs');
const { collect, closeOwnedChild, failure, writeCache, readCache } = require('../collector/collector.cjs');
const { visibleProviders, viewSettings, normalizeSnapshot, initialProviders, isDelayed } = require('../tweak/index.js');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sidebar-usage-settings-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return { codexPath: process.execPath, agyPath: process.execPath, claudeCredentialsPath: path.join(root, 'unused-fixture.json'),
    codexHome: root, userProfile: root, appData: root, localAppData: root, workDir: root, cachePath: path.join(root, 'cache.json') };
}
const rows = [{ id: 'week', label: '7일', usedPercent: 42, resetsAt: null }];

test('delay marks wait for three collection intervals, including old caches without repeated renderer failures', () => {
  const now = Date.parse('2026-10-27T00:10:00Z');
  const provider = { id: 'codex', status: 'stale', checkedAt: now - 179999, windows: rows };
  const defaults = viewSettings();
  assert.equal(isDelayed(provider, now, defaults), false);
  assert.equal(isDelayed({ ...provider, checkedAt: now - 180000 }, now, defaults), true);
  assert.equal(isDelayed({ ...provider, status: 'ok', checkedAt: now - 180000 }, now, defaults), true, 'an old cached success still needs a mark');
  assert.equal(isDelayed({ ...provider, checkedAt: now }, now, defaults), false, 'a fresh success removes the mark');
  assert.equal(isDelayed({ ...provider, checkedAt: null }, now, defaults), true, 'unknown-age cached data cannot claim freshness');
  assert.equal(isDelayed({ ...provider, windows: [] }, now, defaults), false);
  for (const intervalSeconds of [30, 120, 3600]) {
    const settings = viewSettings({ providers: { codex: { intervalSeconds } } });
    assert.equal(isDelayed({ ...provider, checkedAt: now - intervalSeconds * 3000 + 1 }, now, settings), false);
    assert.equal(isDelayed({ ...provider, checkedAt: now - intervalSeconds * 3000 }, now, settings), true);
  }
});

test('usage settings are bounded, deduplicated and contain no executable or arbitrary config fields', () => {
  const s = normalizeUsageSettings({ language: 'fr', providerOrder: ['claude', 'claude', 'other'], hiddenProviders: ['antigravity', 'other'],
    providers: { codex: { intervalSeconds: -1, timeoutSeconds: 5000 }, claude: { intervalSeconds: 7200 } }, secret: 'private' });
  assert.equal(s.language, 'auto'); assert.deepEqual(s.providerOrder, ['claude', 'codex', 'antigravity']);
  assert.deepEqual(s.hiddenProviders, ['antigravity']); assert.deepEqual(s.providers.codex, { intervalSeconds: 30, timeoutSeconds: 60 });
  assert.equal(s.providers.claude.intervalSeconds, 3600); assert.equal(s.providers.antigravity.intervalSeconds, 60);
  assert.equal('secret' in s, false);
});

test('individual polling schedules survive collector restarts; manual refresh respects Claude backoff', async t => {
  const config = fixture(t);
  config.usage = { providers: { codex: { intervalSeconds: 30, timeoutSeconds: 2 }, antigravity: { intervalSeconds: 120, timeoutSeconds: 4 }, claude: { intervalSeconds: 60, timeoutSeconds: 3 } } };
  const calls = { codex: 0, antigravity: 0, claude: 0 };
  let now = Date.parse('2026-10-25T00:00:00Z'), rateLimited = false;
  const options = { now: () => new Date(now).toISOString(),
    runProcessImpl: async (_, __, o) => { calls[o.protocol]++; assert.equal(o.timeoutMs, o.protocol === 'codex' ? 2000 : 4000); return rows; },
    claudeRequestImpl: async c => { calls.claude++; assert.equal(c.timeoutMs, 3000); if (rateLimited) throw failure('RATE_LIMITED'); return rows; } };
  await collect(config, options); assert.deepEqual(calls, { codex: 1, antigravity: 1, claude: 1 });
  now += 30000; await collect(config, options); assert.deepEqual(calls, { codex: 2, antigravity: 1, claude: 1 });
  now += 30000; rateLimited = true;
  const failed = await collect(config, options); assert.deepEqual(calls, { codex: 3, antigravity: 1, claude: 2 });
  assert.equal(failed.providers[2].errorCode, 'RATE_LIMITED'); assert.equal(failed.providers[2].consecutiveFailures, 1);
  now += 1000;
  const manual = await collect(config, { ...options, forceRefresh: true });
  assert.deepEqual(calls, { codex: 4, antigravity: 2, claude: 2 });
  assert.equal(manual.providers[2].nextAttemptAt, failed.providers[2].nextAttemptAt);
  assert.equal(manual.providers[2].checkedAt, failed.providers[2].checkedAt);
  now += 300000; rateLimited = false;
  const recovered = await collect(config, options);
  assert.equal(recovered.providers[2].status, 'ok'); assert.equal(recovered.providers[2].consecutiveFailures, 0);
  assert.equal(recovered.providers[2].nextAttemptAt, undefined);
});

test('explicitly disabled providers are hidden, while configured missing executables remain an error', async t => {
  const config = fixture(t); config.agyPath = null; config.claudeCredentialsPath = null;
  config.providerEnabled = { antigravity: true, claude: false };
  const snapshot = await collect(config, { runProcessImpl: async file => { if (!file) throw failure('MISSING_EXECUTABLE'); return rows; } });
  assert.equal(snapshot.providers[1].status, 'unavailable'); assert.equal(snapshot.providers[1].errorCode, 'MISSING_EXECUTABLE');
  assert.equal(snapshot.providers[2].disabled, true);
  const normalized = normalizeSnapshot(snapshot, initialProviders());
  assert.equal(normalized.find(p => p.id === 'claude').disabled, true);
  assert.deepEqual(visibleProviders(normalized, viewSettings()).map(p => p.id), ['codex', 'antigravity']);
});

test('provider/window sorting and hiding are presentation-only and preserve exact window IDs', () => {
  const source = ['codex', 'antigravity', 'claude'].map(id => ({ id, windows: [{ id: 'first' }, { id: 'second' }, { id: 'third' }] }));
  const settings = viewSettings({ providerOrder: ['claude', 'codex'], hiddenProviders: ['antigravity'], windowOrder: { codex: ['third', 'first'] }, hiddenWindows: { codex: ['second'] } });
  const shown = visibleProviders(source, settings);
  assert.deepEqual(shown.map(p => p.id), ['claude', 'codex']); assert.deepEqual(shown[1].windows.map(w => w.id), ['third', 'first']);
  assert.deepEqual(source[0].windows.map(w => w.id), ['first', 'second', 'third']);
});

test('successful child EOF gets a short exit grace; an unresponsive owned child still stops', async () => {
  const child = new EventEmitter(); child.exitCode = null; child.signalCode = null; child.stdin = new PassThrough();
  let killed = 0;
  child.stdin.on('finish', () => { child.exitCode = 0; child.emit('close', 0); });
  await closeOwnedChild(child, async () => { killed++; }, 30); assert.equal(killed, 0);
  const hung = new EventEmitter(); hung.exitCode = null; hung.signalCode = null; hung.stdin = new PassThrough();
  await closeOwnedChild(hung, async () => { killed++; }, 10); assert.equal(killed, 1);
});

test('long window IDs survive cache and renderer so exact hide preferences remain usable', async t => {
  const config = fixture(t), id = 'codex:' + 'x'.repeat(120) + ':secondary';
  const snapshot = { version: 1, updatedAt: new Date().toISOString(), providers: [{ id: 'codex', status: 'ok', checkedAt: new Date().toISOString(), windows: [{ ...rows[0], id }] }] };
  await writeCache(config.cachePath, snapshot); const cached = await readCache(config.cachePath);
  assert.equal(cached.codex.windows[0].id, id);
  const providers = normalizeSnapshot({ version: 1, providers: [cached.codex] }, initialProviders());
  assert.equal(providers[0].windows[0].id, id);
  assert.equal(visibleProviders(providers, viewSettings({ hiddenWindows: { codex: [id] } })).some(p => p.id === 'codex'), false);
});
