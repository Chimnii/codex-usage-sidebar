'use strict';

const PROVIDER_IDS = ['codex', 'antigravity', 'claude'];
const object = value => value && typeof value === 'object' && !Array.isArray(value) ? value : {};
const ids = value => [...new Set((Array.isArray(value) ? value : []).filter(v => typeof v === 'string' && v.length <= 160))].slice(0, 64);
const bounded = (value, fallback, min, max) => Number.isFinite(value) ? Math.min(max, Math.max(min, Math.round(value))) : fallback;

// Deliberately small JSON settings: no expressions, executable paths or selectors.
function normalizeUsageSettings(value) {
  const source = object(value), providers = object(source.providers);
  const result = {
    language: ['ko', 'en'].includes(source.language) ? source.language : 'auto',
    providerOrder: [...new Set([...ids(source.providerOrder).filter(id => PROVIDER_IDS.includes(id)), ...PROVIDER_IDS])],
    hiddenProviders: ids(source.hiddenProviders).filter(id => PROVIDER_IDS.includes(id)),
    windowOrder: {}, hiddenWindows: {}, providers: {}
  };
  for (const id of PROVIDER_IDS) {
    result.windowOrder[id] = ids(object(source.windowOrder)[id]);
    result.hiddenWindows[id] = ids(object(source.hiddenWindows)[id]);
    const timing = object(providers[id]);
    result.providers[id] = {
      intervalSeconds: bounded(timing.intervalSeconds, 60, 30, 3600),
      timeoutSeconds: bounded(timing.timeoutSeconds, 20, 1, 60)
    };
  }
  return result;
}

module.exports = { normalizeUsageSettings, PROVIDER_IDS };
