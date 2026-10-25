'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { ENDPOINT, MAX_RESPONSE_BYTES, parseClaude, requestClaudeUsage } = require('../collector/claude-usage.cjs');
const { collect, failure } = require('../collector/collector.cjs');
const { initialSnapshot, sanitizeSnapshot, mergeSnapshots, failedSnapshot } = require('../tweak/main-bridge.cjs');
const { initialProviders, normalizeSnapshot, displayWindowLabel } = require('../tweak/index.js');

const at = '2026-10-24T01:00:00.000Z';
const usage = { five_hour: { utilization: 7, resets_at: '2026-10-24T05:00:00Z' }, seven_day: { utilization: 0, resets_at: '2026-10-25T07:00:00Z' }, seven_day_sonnet: null };
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sidebar-claude-fixture-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const config = { claudeCredentialsPath: path.join(root, 'credentials.json'), cachePath: path.join(root, 'usage-cache.json'),
    userProfile: root, codexHome: root, appData: root, localAppData: root, workDir: root, timeoutMs: 1000 };
  fs.writeFileSync(config.claudeCredentialsPath, JSON.stringify({ claudeAiOauth: { accessToken: 'fixture-secret', refreshToken: 'never-use-fixture-refresh', expiresAt: Date.now() + 3600000 } }));
  return config;
}
const otherUsage = async () => [{ id: 'week', label: '7일', usedPercent: 20, resetsAt: null }];

test('Claude keeps real zero/fractional percentages and separates 5H/7D and optional model windows', () => {
  assert.deepEqual(parseClaude(usage).map(row => row.usedPercent), [7, 0]);
  assert.equal(parseClaude({ five_hour: { utilization: 0.4, resets_at: null } })[0].usedPercent, 0.4);
  assert.equal(parseClaude({ ...usage, seven_day_opus: { utilization: 12.3, resets_at: null } }).length, 3);
  for (const invalid of [null, -1, 101, Infinity, '7']) {
    assert.throws(() => parseClaude({ five_hour: { utilization: invalid } }), { code: 'BAD_RESPONSE' });
  }
  assert.throws(() => parseClaude({ five_hour: null, seven_day: null }), { code: 'BAD_RESPONSE' });
});

test('Claude reads current credentials each request and sends them only to its fixed endpoint', async t => {
  const config = fixture(t);
  const before = fs.readFileSync(config.claudeCredentialsPath);
  let requests = 0;
  const fetchImpl = async (url, options) => {
    requests++;
    assert.equal(url, ENDPOINT);
    assert.equal(options.method, 'GET');
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers.Authorization, `Bearer ${requests === 1 ? 'fixture-secret' : 'rotated-fixture-secret'}`);
    return new Response(JSON.stringify(usage));
  };
  const rows = await requestClaudeUsage(config, { fetchImpl });
  assert.deepEqual(fs.readFileSync(config.claudeCredentialsPath), before);
  fs.writeFileSync(config.claudeCredentialsPath, JSON.stringify({ claudeAiOauth: { accessToken: 'rotated-fixture-secret' } }));
  await requestClaudeUsage(config, { fetchImpl });
  assert.equal(requests, 2);
  assert.doesNotMatch(JSON.stringify(rows), /secret|refreshToken|accessToken/);
});

test('missing and expired Claude credentials never trigger network or model calls', async t => {
  const config = fixture(t);
  const fetchImpl = () => { throw new Error('must not request'); };
  fs.writeFileSync(config.claudeCredentialsPath, JSON.stringify({ claudeAiOauth: { accessToken: 'expired', expiresAt: 1 } }));
  await assert.rejects(requestClaudeUsage(config, { fetchImpl }), { code: 'CLAUDE_AUTH_REQUIRED' });
  fs.unlinkSync(config.claudeCredentialsPath);
  await assert.rejects(requestClaudeUsage(config, { fetchImpl }), { code: 'CLAUDE_NOT_CONNECTED' });
});

test('Claude HTTP failures and response limits expose no raw server content or credentials', async t => {
  const config = fixture(t);
  for (const [status, code] of [[401, 'CLAUDE_AUTH_REQUIRED'], [403, 'CLAUDE_AUTH_REQUIRED'], [429, 'RATE_LIMITED'], [500, 'RPC_ERROR']]) {
    await assert.rejects(requestClaudeUsage(config, { fetchImpl: async () => new Response('fixture-secret echoed', { status, headers: { 'retry-after': '0' } }) }), error => {
      assert.equal(error.code, code);
      assert.doesNotMatch(error.message, /secret/);
      if (status === 429) assert.equal(error.retryAfterMs, 300000);
      return true;
    });
  }
  await assert.rejects(requestClaudeUsage(config, { fetchImpl: async () => new Response('x'.repeat(MAX_RESPONSE_BYTES + 1)) }), { code: 'OUTPUT_LIMIT' });
  await assert.rejects(requestClaudeUsage(config, { fetchImpl: async () => { throw new Error('private URL fixture-secret'); } }), error => error.code === 'BAD_RESPONSE' && !error.message.includes('secret'));
});

test('Claude timeout and parent cancellation terminate the owned request', async t => {
  const config = fixture(t);
  const fetchImpl = (_, { signal }) => new Promise((_, reject) => {
    if (signal.aborted) reject(new Error('aborted'));
    else signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
  });
  await assert.rejects(requestClaudeUsage({ ...config, timeoutMs: 20 }, { fetchImpl }), { code: 'TIMEOUT' });
  const controller = new AbortController();
  const pending = requestClaudeUsage(config, { fetchImpl, signal: controller.signal });
  controller.abort();
  await assert.rejects(pending, { code: 'ABORTED' });
});

test('Claude survives collector restarts, backs off after 429 and preserves last good data', async t => {
  const config = fixture(t);
  let requests = 0;
  const options = { now: () => at, runProcessImpl: otherUsage, claudeRequestImpl: async () => { requests++; return parseClaude(usage); } };
  const first = await collect(config, options);
  assert.equal(first.providers[2].status, 'ok');
  const after = '2026-10-24T01:01:00.000Z';
  const rateLimited = async () => { requests++; throw failure('RATE_LIMITED'); };
  const second = await collect(config, { ...options, now: () => after, claudeRequestImpl: rateLimited });
  assert.equal(second.providers[2].status, 'stale');
  assert.equal(second.providers[2].checkedAt, at);
  assert.deepEqual(second.providers[2].windows, first.providers[2].windows);
  assert.equal(second.providers[2].nextAttemptAt, '2026-10-24T01:06:00.000Z');
  const third = await collect(config, { ...options, now: () => '2026-10-24T01:02:00.000Z', claudeRequestImpl: rateLimited });
  assert.equal(requests, 2);
  assert.equal(third.providers[0].status, 'ok');
  assert.equal(third.providers[2].status, 'stale');
  const recovered = await collect(config, { ...options, now: () => '2026-10-24T01:07:00.000Z' });
  assert.equal(requests, 3);
  assert.equal(recovered.providers[2].status, 'ok');
  assert.equal(recovered.providers[2].nextAttemptAt, undefined);
  assert.doesNotMatch(fs.readFileSync(config.cachePath, 'utf8'), /secret|accessToken|refreshToken/);
});

test('Claude initial errors stay unknown, and missing credentials stay disconnected', async t => {
  const config = fixture(t);
  for (const [code, expected] of [['CLAUDE_NOT_CONNECTED', 'disconnected'], ['TIMEOUT', 'unavailable']]) {
    const result = await collect(config, { forceRefresh: true, now: () => at, runProcessImpl: otherUsage, claudeRequestImpl: async () => { throw failure(code); } });
    assert.equal(result.providers[2].status, expected);
    assert.deepEqual(result.providers[2].windows, []);
  }
});

test('Claude usage crosses IPC and renderer with short labels and retains values on failure', () => {
  const snapshot = initialSnapshot();
  Object.assign(snapshot.providers.find(p => p.id === 'claude'), { status: 'ok', checkedAt: at, windows: parseClaude(usage) });
  const clean = sanitizeSnapshot(snapshot);
  const rendered = normalizeSnapshot(clean, initialProviders());
  const claude = rendered.find(p => p.id === 'claude');
  assert.equal(claude.status, 'ok');
  assert.equal(claude.windows.length, 2);
  assert.deepEqual(claude.windows.map(row => displayWindowLabel(claude, row)), ['Claude 5H', 'Claude 7D']);
  assert.deepEqual(claude.windows.map(row => row.usedPercent), [7, 0]);
  const failed = failedSnapshot(clean);
  assert.equal(failed.providers.find(p => p.id === 'claude').status, 'stale');
  assert.deepEqual(mergeSnapshots(clean, initialSnapshot()).providers.find(p => p.id === 'claude').windows, parseClaude(usage));
  assert.equal(normalizeSnapshot(initialSnapshot(), rendered).find(p => p.id === 'claude').status, 'stale');
});
