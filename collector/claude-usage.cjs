'use strict';

const fs = require('node:fs');
const ENDPOINT = 'https://api.anthropic.com/api/oauth/usage';
const MAX_RESPONSE_BYTES = 128 * 1024;
const CODES = new Set(['CLAUDE_NOT_CONNECTED', 'CLAUDE_AUTH_REQUIRED', 'RATE_LIMITED', 'BAD_RESPONSE', 'TIMEOUT', 'ABORTED', 'OUTPUT_LIMIT', 'RPC_ERROR']);

function usageError(code, retryAfterMs) {
  const error = new Error(code);
  error.code = code;
  if (retryAfterMs) error.retryAfterMs = retryAfterMs;
  return error;
}

function parseClaude(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw usageError('BAD_RESPONSE');
  const rows = [];
  for (const [key, label] of [
    ['five_hour', 'Claude · 5시간'], ['seven_day', 'Claude · 7일'],
    ['seven_day_opus', 'Claude Opus · 7일'], ['seven_day_sonnet', 'Claude Sonnet · 7일'],
  ]) {
    const window = data[key];
    if (window === null || window === undefined) continue;
    if (typeof window !== 'object' || Array.isArray(window) || typeof window.utilization !== 'number' ||
        !Number.isFinite(window.utilization) || window.utilization < 0 || window.utilization > 100) throw usageError('BAD_RESPONSE');
    const reset = typeof window.resets_at === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(window.resets_at) ? Date.parse(window.resets_at) : NaN;
    rows.push({ id: `claude:${key}`, label, usedPercent: Math.round(window.utilization * 10) / 10,
      resetsAt: Number.isFinite(reset) ? new Date(reset).toISOString() : null });
  }
  if (!rows.length) throw usageError('BAD_RESPONSE');
  return rows;
}

async function readAccessToken(credentialsPath) {
  try {
    const stat = await fs.promises.stat(credentialsPath);
    if (!stat.isFile() || stat.size > 64 * 1024) throw usageError('CLAUDE_AUTH_REQUIRED');
    const credentials = JSON.parse((await fs.promises.readFile(credentialsPath, 'utf8')).replace(/^\uFEFF/, ''));
    const oauth = credentials?.claudeAiOauth;
    const token = oauth?.accessToken;
    if (typeof token !== 'string' || !token.length || token.length > 16384 || /[\r\n]/.test(token) ||
        (typeof oauth.expiresAt === 'number' && oauth.expiresAt <= Date.now())) throw usageError('CLAUDE_AUTH_REQUIRED');
    return token;
  } catch (error) {
    throw usageError(error.code === 'ENOENT' ? 'CLAUDE_NOT_CONNECTED' : 'CLAUDE_AUTH_REQUIRED');
  }
}

async function requestClaudeUsage(config, options = {}) {
  if (options.signal?.aborted) throw usageError('ABORTED');
  // Read Claude Code's current credentials each time. Never copy, refresh, or
  // rewrite its tokens, and never pass them to a process or the renderer.
  const token = await readAccessToken(config.claudeCredentialsPath);
  const controller = new AbortController();
  const abort = () => controller.abort();
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; controller.abort(); }, config.timeoutMs || 20000);
  options.signal?.addEventListener('abort', abort, { once: true });
  if (options.signal?.aborted) controller.abort();
  let response;
  try {
    response = await (options.fetchImpl || fetch)(ENDPOINT, {
      method: 'GET', redirect: 'error', signal: controller.signal,
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json', 'anthropic-beta': 'oauth-2025-04-20' },
    });
    if (response.status === 429) {
      const header = response.headers.get('retry-after');
      const seconds = header !== null && /^\d+(?:\.\d+)?$/.test(header) ? Number(header) * 1000 : Date.parse(header) - Date.now();
      throw usageError('RATE_LIMITED', Math.min(3600000, Math.max(300000, Number.isFinite(seconds) ? seconds : 300000)));
    }
    if (response.status === 401 || response.status === 403) throw usageError('CLAUDE_AUTH_REQUIRED', 300000);
    if (!response.ok) throw usageError('RPC_ERROR');
    const reader = response.body?.getReader();
    if (!reader) throw usageError('BAD_RESPONSE');
    let bytes = 0;
    const chunks = [];
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > MAX_RESPONSE_BYTES) throw usageError('OUTPUT_LIMIT');
        chunks.push(Buffer.from(value));
      }
    } finally { await reader.cancel().catch(() => {}); }
    return parseClaude(JSON.parse(Buffer.concat(chunks).toString('utf8')));
  } catch (error) {
    if (options.signal?.aborted) throw usageError('ABORTED');
    if (timedOut) throw usageError('TIMEOUT');
    if (CODES.has(error?.code)) throw usageError(error.code, error.retryAfterMs);
    throw usageError('BAD_RESPONSE');
  } finally {
    clearTimeout(timer);
    options.signal?.removeEventListener('abort', abort);
    if (response?.body && !response.body.locked) await response.body.cancel().catch(() => {});
  }
}

module.exports = { ENDPOINT, MAX_RESPONSE_BYTES, parseClaude, requestClaudeUsage };
