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
  assert.throws(() => sanitizeUiReport({ ...report, detectorVersion: 1 }));
});
