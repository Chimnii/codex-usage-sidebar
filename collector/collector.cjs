'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const { requestClaudeUsage } = require('./claude-usage.cjs');
const { normalizeUsageSettings } = require('./settings.cjs');

const MAX_OUTPUT_BYTES = 1024 * 1024;
const MAX_CACHE_BYTES = 256 * 1024;
const MAX_ROWS = 64;
const PROVIDERS = { codex: 'Codex', antigravity: 'Antigravity Gemini', claude: 'Claude' };
const ERRORS = Object.freeze({
  CONFIG_ERROR: '수집기 설정 확인 필요',
  MISSING_EXECUTABLE: 'CLI 실행 경로 미설정',
  START_FAILED: 'CLI 실행 실패',
  TIMEOUT: '사용량 조회 시간 초과',
  BAD_RESPONSE: '사용량 응답 형식 확인 실패',
  RPC_ERROR: '사용량 요청 실패',
  EXIT_FAILURE: 'CLI 사용량 조회 실패',
  OUTPUT_LIMIT: '사용량 응답 크기 초과',
  ABORTED: '사용량 조회 취소',
  CLAUDE_NOT_CONNECTED: 'Claude Code 로그인 정보 없음',
  CLAUDE_AUTH_REQUIRED: 'Claude Code 로그인 갱신 필요',
  RATE_LIMITED: '사용량 조회 제한, 잠시 후 재시도',
});

function failure(code) {
  const error = new Error(ERRORS[code] || ERRORS.BAD_RESPONSE);
  error.code = Object.hasOwn(ERRORS, code) ? code : 'BAD_RESPONSE';
  return error;
}

function sanitizedError(error) {
  return ERRORS[error && error.code] || ERRORS.BAD_RESPONSE;
}

function record(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function text(value, fallback = '', limit = 120) {
  return typeof value === 'string'
    ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, limit) || fallback
    : fallback;
}

function percent(value) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 100) throw failure('BAD_RESPONSE');
  return Math.round(value * 10) / 10;
}

function timestamp(value) {
  if (value === null || value === undefined) return null;
  const ms = typeof value === 'number' && Number.isFinite(value)
    ? value * 1000
    : typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(value) ? Date.parse(value) : NaN;
  if (!Number.isFinite(ms) || ms < 0 || ms > 8640000000000000) return null;
  try { return new Date(ms).toISOString(); } catch { return null; }
}

function windowDuration(minutes, fallback) {
  if (typeof minutes !== 'number' || !Number.isFinite(minutes) || minutes <= 0) return fallback;
  if (minutes >= 1440) return `${Math.round(minutes / 1440 * 10) / 10}일`;
  if (minutes >= 60) return `${Math.round(minutes / 60 * 10) / 10}시간`;
  return `${minutes}분`;
}

function checkedRows(rows) {
  if (!rows.length || rows.length > MAX_ROWS) throw failure('BAD_RESPONSE');
  return rows;
}

function parseCodex(result) {
  if (!record(result)) throw failure('BAD_RESPONSE');
  const multi = result.rateLimitsByLimitId;
  const entries = record(multi) && Object.keys(multi).length
    ? Object.entries(multi)
    : record(result.rateLimits) ? [['codex', result.rateLimits]] : [];
  const rows = [];
  for (const [key, limit] of entries) {
    if (!record(limit)) throw failure('BAD_RESPONSE');
    const group = text(limit.limitName, text(key, 'Codex'));
    for (const slot of ['primary', 'secondary']) {
      const window = limit[slot];
      if (window === null || window === undefined) continue;
      if (!record(window)) throw failure('BAD_RESPONSE');
      rows.push({
        id: `codex:${text(key, 'codex')}:${slot}`,
        label: `${group} · ${windowDuration(window.windowDurationMins, slot === 'primary' ? '기본 한도' : '추가 한도')}`,
        usedPercent: percent(window.usedPercent),
        resetsAt: timestamp(window.resetsAt),
      });
    }
  }
  return checkedRows(rows);
}

function parseAntigravity(report) {
  if (!record(report) || report.status !== 'SUCCESS' || report.command?.name !== 'usage' || !Array.isArray(report.command?.data?.groups)) {
    throw failure('BAD_RESPONSE');
  }
  const rows = [];
  report.command.data.groups.forEach((group, groupIndex) => {
    if (!record(group) || typeof group.name !== 'string') throw failure('BAD_RESPONSE');
    // Antigravity's Claude/GPT quotas are not Claude Code or Codex subscriptions.
    if (!/\bgemini\b/i.test(group.name)) return;
    if (!Array.isArray(group.buckets) || !group.buckets.length) throw failure('BAD_RESPONSE');
    group.buckets.forEach((bucket, bucketIndex) => {
      if (!record(bucket) || typeof bucket.remaining_fraction !== 'number' || !Number.isFinite(bucket.remaining_fraction)
        || bucket.remaining_fraction < 0 || bucket.remaining_fraction > 1) throw failure('BAD_RESPONSE');
      const label = text(bucket.name, text(bucket.window, `한도 ${bucketIndex + 1}`));
      const period = bucket.window === 'weekly' ? '7일' : bucket.window === 'daily' ? '1일' : '';
      const rowLabel = [text(group.name), label, period && !label.includes(period) ? period : ''].filter(Boolean).join(' · ');
      rows.push({
        id: `gemini:${text(group.id, String(groupIndex))}:${text(bucket.id, text(bucket.window, String(bucketIndex)))}:${bucketIndex}`.slice(0, 160),
        label: rowLabel,
        usedPercent: percent((1 - bucket.remaining_fraction) * 100),
        resetsAt: timestamp(bucket.reset_time),
      });
    });
  });
  return checkedRows(rows);
}

function cachedProvider(value, id) {
  if (!record(value) || value.id !== id || !Array.isArray(value.windows) || value.windows.length < 1 || value.windows.length > MAX_ROWS) return null;
  const checkedAt = timestamp(value.checkedAt);
  if (!checkedAt) return null;
  try {
    const windows = value.windows.map((row) => {
      if (!record(row) || !text(row.id) || !text(row.label)) throw failure('BAD_RESPONSE');
      return { id: text(row.id, '', 160), label: text(row.label, '', 160), usedPercent: percent(row.usedPercent), resetsAt: timestamp(row.resetsAt) };
    });
    return { id, checkedAt, windows };
  } catch { return null; }
}

function mergeProvider(id, previous, outcome, attemptedAt, checkedAt) {
  if (outcome.status === 'disconnected') return { id, label: PROVIDERS[id], status: 'disconnected', checkedAt: null, attemptedAt: null, windows: [], error: null, errorCode: null, durationMs: null, consecutiveFailures: 0 };
  const base = { id, label: PROVIDERS[id], attemptedAt, durationMs: null };
  if (outcome.status === 'fulfilled') {
    return { ...base, status: 'ok', checkedAt, windows: outcome.value, error: null, errorCode: null, consecutiveFailures: 0 };
  }
  const good = cachedProvider(previous, id);
  return { ...base, status: good ? 'stale' : outcome.reason?.code === 'CLAUDE_NOT_CONNECTED' ? 'disconnected' : 'unavailable', checkedAt: good?.checkedAt ?? null, windows: good?.windows ?? [], error: sanitizedError(outcome.reason),
    errorCode: Object.hasOwn(ERRORS, outcome.reason?.code) ? outcome.reason.code : 'BAD_RESPONSE',
    consecutiveFailures: Math.min(100000, (Number.isInteger(previous?.consecutiveFailures) ? previous.consecutiveFailures : 0) + 1) };
}

function buildEnvironment(config, provider, source = process.env) {
  const env = { ...source };
  for (const key of Object.keys(env)) {
    if (/^(?:CODEX_|CODEXPP_|ELECTRON_|CLAUDECODE$|XDG_(?:CACHE|CONFIG|DATA|STATE)_HOME$)/i.test(key)) delete env[key];
  }
  // The copied desktop app overrides these. Restore explicit CLI profile roots.
  for (const [key, value] of Object.entries({ USERPROFILE: config.userProfile, APPDATA: config.appData, LOCALAPPDATA: config.localAppData })) {
    if (value) env[key] = value;
  }
  if (provider === 'codex') env.CODEX_HOME = config.codexHome;
  return env;
}

function killOwnedChild(child, platform = process.platform) {
  if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  if (platform !== 'win32') {
    try { child.kill('SIGKILL'); } catch {}
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      // ChildProcess.kill uses the handle belonging to this child, not a searched PID.
      if (child.exitCode === null && child.signalCode === null) { try { child.kill(); } catch {} }
      resolve();
    };
    const timer = setTimeout(finish, 1500);
    try {
      const killer = spawn(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'taskkill.exe'), ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
      killer.once('error', finish);
      killer.once('close', finish);
    } catch { finish(); }
  });
}

function runProcess(file, args, options = {}) {
  if (typeof file !== 'string' || !file) return Promise.reject(failure('MISSING_EXECUTABLE'));
  if (options.signal?.aborted) return Promise.reject(failure('ABORTED'));
  const spawnProcess = options.spawnImpl || spawn;
  const killChild = options.killImpl || killOwnedChild;
  return new Promise((resolve, reject) => {
    let child;
    let finished = false;
    let output = '';
    let buffer = '';
    let bytes = 0;
    let phase = 'initialize';
    const abort = () => finish(failure('ABORTED'));
    const timer = setTimeout(() => finish(failure('TIMEOUT')), options.timeoutMs || 20000);
    const finish = (error, value) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', abort);
      // Successful app-server replies can exit cleanly on EOF. Failed/hung
      // requests still stop immediately; only the owned child is ever killed.
      Promise.resolve(closeOwnedChild(child, killChild, error ? 0 : options.exitGraceMs ?? 250))
        .catch(() => {}).then(() => error ? reject(error) : resolve(value));
    };
    const write = (packet) => {
      if (!finished) { try { child.stdin.write(JSON.stringify(packet) + '\n'); } catch { finish(failure('START_FAILED')); } }
    };
    const codexLine = (line) => {
      if (!line.trim() || finished) return;
      let packet;
      try { packet = JSON.parse(line); } catch { finish(failure('BAD_RESPONSE')); return; }
      if (!record(packet)) { finish(failure('BAD_RESPONSE')); return; }
      if (packet.id !== 1 && packet.id !== 2) return; // Ignore protocol notifications.
      if (packet.error) { finish(failure('RPC_ERROR')); return; }
      if (packet.id === 1 && phase === 'initialize') {
        if (!record(packet.result)) { finish(failure('BAD_RESPONSE')); return; }
        phase = 'usage';
        write({ method: 'initialized', params: {} });
        write({ id: 2, method: 'account/rateLimits/read', params: {} });
      } else if (packet.id === 2 && phase === 'usage') {
        try { finish(null, parseCodex(packet.result)); } catch (error) { finish(error); }
      }
    };
    try {
      child = spawnProcess(file, args, { cwd: options.cwd, env: options.env, windowsHide: true, shell: false, stdio: ['pipe', 'pipe', 'pipe'] });
      child.once('error', () => finish(failure('START_FAILED')));
      child.stdin.on('error', () => { if (!finished) finish(failure('START_FAILED')); });
      child.stdout.setEncoding('utf8').on('data', (chunk) => {
        if (finished) return;
        bytes += Buffer.byteLength(chunk);
        if (bytes > MAX_OUTPUT_BYTES) { finish(failure('OUTPUT_LIMIT')); return; }
        if (options.protocol === 'codex') {
          buffer += chunk;
          let newline;
          while (!finished && (newline = buffer.indexOf('\n')) >= 0) {
            const line = buffer.slice(0, newline);
            buffer = buffer.slice(newline + 1);
            codexLine(line);
          }
        } else output += chunk;
      });
      // Count and discard diagnostics; raw CLI output must never reach the UI/cache.
      child.stderr.on('data', (chunk) => {
        if (finished) return;
        bytes += chunk.length;
        if (bytes > MAX_OUTPUT_BYTES) finish(failure('OUTPUT_LIMIT'));
      });
      child.once('close', (code) => {
        if (finished) return;
        if (options.protocol === 'codex') {
          if (buffer.trim()) codexLine(buffer);
          if (!finished) finish(failure('EXIT_FAILURE'));
        } else if (code !== 0) finish(failure('EXIT_FAILURE'));
        else {
          try { finish(null, parseAntigravity(JSON.parse(output))); } catch { finish(failure('BAD_RESPONSE')); }
        }
      });
      options.signal?.addEventListener('abort', abort, { once: true });
      if (options.signal?.aborted) { abort(); return; }
      if (options.protocol === 'codex') {
        write({ id: 1, method: 'initialize', params: { clientInfo: { name: 'sidebar-usage-collector', version: '1.1.0' } } });
      } else child.stdin.end();
    } catch { finish(failure('START_FAILED')); }
  });
}

function closeOwnedChild(child, killChild = killOwnedChild, graceMs = 250) {
  if (!child) return Promise.resolve();
  return new Promise(resolve => {
    let settled = false, timer;
    const done = () => {
      if (settled) return;
      settled = true; clearTimeout(timer); child.removeListener('close', done); resolve();
    };
    child.once('close', done);
    try { if (child.stdin && !child.stdin.destroyed) child.stdin.end(); } catch {}
    if (settled) return;
    if (child.exitCode !== null || child.signalCode !== null) { done(); return; }
    const force = () => { if (!settled) Promise.resolve(killChild(child)).catch(() => {}).then(done); };
    if (graceMs > 0) timer = setTimeout(force, graceMs); else force();
  });
}

function validateConfig(config) {
  if (!record(config)) throw failure('CONFIG_ERROR');
  for (const key of ['codexHome', 'userProfile', 'appData', 'localAppData', 'workDir', 'cachePath']) {
    if (typeof config[key] !== 'string' || !path.isAbsolute(config[key])) throw failure('CONFIG_ERROR');
  }
  for (const key of ['codexPath', 'agyPath', 'claudeCredentialsPath']) {
    if (config[key] !== null && config[key] !== undefined && (typeof config[key] !== 'string' || !path.isAbsolute(config[key]))) throw failure('CONFIG_ERROR');
  }
  const timeoutMs = config.timeoutMs ?? 20000;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > 60000) throw failure('CONFIG_ERROR');
  const usage = normalizeUsageSettings(config.usage);
  // Preserve the legacy top-level timeout for callers without per-provider settings.
  for (const id of Object.keys(PROVIDERS)) {
    if (config.usage?.providers?.[id]?.timeoutSeconds === undefined) usage.providers[id].timeoutSeconds = timeoutMs / 1000;
  }
  return { ...config, timeoutMs, usage };
}

async function readCache(cachePath) {
  try {
    const stat = await fs.promises.stat(cachePath);
    if (!stat.isFile() || stat.size > MAX_CACHE_BYTES) return {};
    const json = JSON.parse(await fs.promises.readFile(cachePath, 'utf8'));
    if (json.version !== 1 || !Array.isArray(json.providers)) return {};
    return Object.fromEntries(['codex', 'antigravity', 'claude'].map((id) => {
      const value = json.providers.find((item) => item?.id === id);
      return [id, normalizeCachedProvider(value, id)];
    }));
  } catch { return {}; }
}

function normalizeCachedProvider(value, id) {
  const good = cachedProvider(value, id);
  const nextAttemptAt = id === 'claude' ? timestamp(value?.nextAttemptAt) : null;
  return {
    id, label: PROVIDERS[id],
    status: good ? value.status === 'ok' ? 'ok' : 'stale' : id !== 'codex' && value?.status === 'disconnected' ? 'disconnected' : 'unavailable',
    checkedAt: good?.checkedAt ?? null, attemptedAt: timestamp(value?.attemptedAt), windows: good?.windows ?? [],
    error: Object.values(ERRORS).includes(value?.error) ? value.error : null,
    errorCode: Object.hasOwn(ERRORS, value?.errorCode) ? value.errorCode : null,
    durationMs: Number.isFinite(value?.durationMs) ? Math.min(120000, Math.max(0, Math.round(value.durationMs))) : null,
    consecutiveFailures: Number.isInteger(value?.consecutiveFailures) ? Math.min(100000, Math.max(0, value.consecutiveFailures)) : 0,
    ...(nextAttemptAt ? { nextAttemptAt } : {}),
    ...(value?.disabled === true && value?.status === 'disconnected' ? { disabled: true } : {}),
  };
}

async function writeCache(cachePath, snapshot) {
  const json = {
    version: 1,
    updatedAt: timestamp(snapshot.updatedAt),
    providers: ['codex', 'antigravity', 'claude'].map((id) => {
      const value = snapshot.providers.find((provider) => provider.id === id);
      return normalizeCachedProvider(value, id);
    }),
  };
  const temp = `${cachePath}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await fs.promises.mkdir(path.dirname(cachePath), { recursive: true });
    await fs.promises.writeFile(temp, JSON.stringify(json), { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    await fs.promises.rename(temp, cachePath);
  } catch {
    try { await fs.promises.unlink(temp); } catch {}
    // Collection is still valid when its last-good cache cannot be persisted.
  }
}

function failedSnapshot(code = 'CONFIG_ERROR', now = new Date().toISOString()) {
  return { version: 1, updatedAt: now, providers: ['codex', 'antigravity', 'claude'].map((id) => mergeProvider(id, null, { status: id === 'claude' ? 'disconnected' : 'rejected', reason: failure(code) }, now, null)) };
}

async function collectClaude(config, previous, options, attemptedAt, now) {
  const next = Date.parse(previous?.nextAttemptAt);
  const attemptMs = Date.parse(attemptedAt);
  // A rate-limited response survives short-lived collector processes, so the
  // desktop's one-minute tick does not repeatedly hit a throttled endpoint.
  if (next > attemptMs && next <= attemptMs + 3600000) return previous;
  try {
    const windows = await (options.claudeRequestImpl || requestClaudeUsage)(config, { signal: options.signal });
    return mergeProvider('claude', previous, { status: 'fulfilled', value: windows }, attemptedAt, now());
  } catch (reason) {
    const result = mergeProvider('claude', previous, { status: 'rejected', reason }, attemptedAt, null);
    const delay = reason.code === 'RATE_LIMITED' ? Math.min(3600000, Math.max(300000, Number(reason.retryAfterMs) || 300000))
      : reason.code === 'CLAUDE_AUTH_REQUIRED' ? 300000 : 0;
    return { ...result, ...(delay ? { nextAttemptAt: new Date(attemptMs + delay).toISOString() } : {}) };
  }
}

async function collect(rawConfig, options = {}) {
  const config = validateConfig(rawConfig);
  const now = options.now || (() => new Date().toISOString());
  const run = options.runProcessImpl || runProcess;
  const previous = await readCache(config.cachePath);
  const attemptedAt = now();
  const providers = await Promise.all(['codex', 'antigravity', 'claude'].map(async (id) => {
    const optionalPath = id === 'claude' ? config.claudeCredentialsPath : config.agyPath;
    if (id !== 'codex' && (config.providerEnabled?.[id] === false || (!optionalPath && config.providerEnabled?.[id] !== true))) {
      return { ...mergeProvider(id, null, { status: 'disconnected' }, null, null), disabled: true };
    }
    const timing = config.usage.providers[id];
    const lastAttempt = Date.parse(previous[id]?.attemptedAt);
    const elapsed = Date.parse(attemptedAt) - lastAttempt;
    if (!options.forceRefresh && elapsed >= 0 && elapsed < timing.intervalSeconds * 1000) return previous[id];
    const started = Date.now();
    const measured = value => ({ ...value, durationMs: Math.min(120000, Date.now() - started) });
    if (id === 'claude') {
      if (!optionalPath) return measured(mergeProvider(id, previous[id], { status: 'rejected', reason: failure('CONFIG_ERROR') }, attemptedAt, null));
      const result = await collectClaude({ ...config, timeoutMs: timing.timeoutSeconds * 1000 }, previous.claude, options, attemptedAt, now);
      return result === previous.claude ? result : measured(result);
    }
    try {
      const windows = await run(id === 'codex' ? config.codexPath : config.agyPath,
        id === 'codex' ? ['app-server', '--listen', 'stdio://'] : ['--print', '/usage', '--output-format', 'json'],
        { cwd: config.workDir, env: buildEnvironment(config, id), timeoutMs: timing.timeoutSeconds * 1000, signal: options.signal, protocol: id === 'codex' ? 'codex' : 'antigravity' });
      return measured(mergeProvider(id, previous[id], { status: 'fulfilled', value: windows }, attemptedAt, now()));
    } catch (reason) {
      return measured(mergeProvider(id, previous[id], { status: 'rejected', reason }, attemptedAt, null));
    }
  }));
  const snapshot = { version: 1, updatedAt: now(), providers };
  await writeCache(config.cachePath, snapshot);
  return snapshot;
}

module.exports = { MAX_OUTPUT_BYTES, ERRORS, failure, sanitizedError, timestamp, percent, parseCodex, parseAntigravity, cachedProvider, mergeProvider, buildEnvironment, killOwnedChild, closeOwnedChild, runProcess, validateConfig, readCache, writeCache, failedSnapshot, collect };
