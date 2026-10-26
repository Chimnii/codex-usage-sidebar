"use strict";

// The renderer reads cached, sanitized usage only; collection lives in main.
const TWEAK_ID = "local.sidebar-usage-demo";
const DIAGNOSTIC_KEY = "__sidebarUsageDemo";
const PANEL_ATTRIBUTE = "data-sidebar-usage-demo";
const ROOT_SELECTOR = "[data-sidebar-navigation-root]";
const FOOTER_SELECTOR = "div.absolute.inset-x-0.bottom-0.z-20";
const STYLE_ID = "sidebar-usage-demo-style";
const PROVIDERS = [
  { id: "codex", label: "GPT" },
  { id: "antigravity", label: "Antigravity Gemini" },
  { id: "claude", label: "Claude" }
];
let current = null;
let mainBridge = null;
let language = 'ko';
const STRINGS = {
  ko: { usage: '사용량', panel: '사용량 패널', services: '서비스 사용량', stale: '갱신 지연', ok: '사용률', disconnected: '미연결', unavailable: '조회 불가', waiting: '조회 대기',
    last: '마지막 조회 성공', retry: '다음 재시도', reset: '초기화 예정', resetWaiting: '초기화 대기', unknown: '사용량 정보 없음', used: '사용', refresh: '사용량 새로고침', refreshing: '갱신 요청 중',
    errors: { CONFIG_ERROR: '수집기 설정 확인 필요', MISSING_EXECUTABLE: 'CLI 실행 경로 확인 필요', START_FAILED: 'CLI 실행 실패', TIMEOUT: '조회 시간 초과', BAD_RESPONSE: '응답 형식 확인 실패', RPC_ERROR: '사용량 요청 실패', EXIT_FAILURE: 'CLI 조회 실패', OUTPUT_LIMIT: '응답 크기 초과', ABORTED: '조회 취소', CLAUDE_NOT_CONNECTED: 'Claude Code 로그인 필요', CLAUDE_AUTH_REQUIRED: 'Claude Code 로그인 갱신 필요', RATE_LIMITED: '조회 제한, 재시도 대기', IPC_ERROR: '수집기 연결 실패', STALE_DATA: '최근 사용량이 아직 수신되지 않음' } },
  en: { usage: 'Usage', panel: 'Usage panel', services: 'Service usage', stale: 'Delayed', ok: 'Usage', disconnected: 'Disconnected', unavailable: 'Unavailable', waiting: 'Waiting',
    last: 'Last successful check', retry: 'Next retry', reset: 'Resets', resetWaiting: 'Reset pending', unknown: 'Usage unavailable', used: 'used', refresh: 'Refresh usage', refreshing: 'Requesting refresh',
    errors: { CONFIG_ERROR: 'Check collector settings', MISSING_EXECUTABLE: 'Check CLI path', START_FAILED: 'CLI failed to start', TIMEOUT: 'Request timed out', BAD_RESPONSE: 'Invalid usage response', RPC_ERROR: 'Usage request failed', EXIT_FAILURE: 'CLI request failed', OUTPUT_LIMIT: 'Response too large', ABORTED: 'Request cancelled', CLAUDE_NOT_CONNECTED: 'Sign in to Claude Code', CLAUDE_AUTH_REQUIRED: 'Sign in to Claude Code again', RATE_LIMITED: 'Rate limited; waiting to retry', IPC_ERROR: 'Collector connection failed', STALE_DATA: 'Recent usage has not arrived' } }
};
const tr = key => STRINGS[language][key];
function chooseLanguage(value) {
  if (value === 'ko' || value === 'en') return value;
  const locale = (typeof document !== 'undefined' && document.documentElement.lang) || (typeof navigator !== 'undefined' && navigator.language) || 'en';
  return locale.toLowerCase().startsWith('ko') ? 'ko' : 'en';
}
function viewSettings(value = {}) {
  const strings = v => [...new Set((Array.isArray(v) ? v : []).filter(s => typeof s === 'string' && s.length <= 160))].slice(0, 64);
  const ids = PROVIDERS.map(p => p.id);
  return { language: chooseLanguage(value.language), providerOrder: [...new Set([...strings(value.providerOrder).filter(id => ids.includes(id)), ...ids])],
    hiddenProviders: strings(value.hiddenProviders), windowOrder: value.windowOrder || {}, hiddenWindows: value.hiddenWindows || {}, providers: value.providers || {} };
}
function visibleProviders(providers, settings) {
  const rank = (order, id) => { const index = Array.isArray(order) ? order.indexOf(id) : -1; return index < 0 ? 10000 : index; };
  return providers.filter(p => !p.disabled && !settings.hiddenProviders.includes(p.id)).map(p => {
    const hidden = Array.isArray(settings.hiddenWindows[p.id]) ? settings.hiddenWindows[p.id] : [];
    const windows = p.windows.filter(w => !hidden.includes(w.id)).sort((a, b) => rank(settings.windowOrder[p.id], a.id) - rank(settings.windowOrder[p.id], b.id));
    return { ...p, windows, allWindowsHidden: p.windows.length > 0 && !windows.length };
  }).filter(p => !p.allWindowsHidden).sort((a, b) => rank(settings.providerOrder, a.id) - rank(settings.providerOrder, b.id));
}

function boundedInvoke(api, name, pending, timeoutMs = 10000, request) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true; clearTimeout(timer); pending.delete(cancel);
      if (error) reject(error); else resolve(value);
    };
    const cancel = () => finish(new Error('cancelled'));
    const timer = setTimeout(() => finish(new Error('IPC timeout')), timeoutMs);
    pending.add(cancel);
    Promise.resolve().then(() => api.ipc.invoke(name, request)).then(value => finish(null, value), error => finish(error));
  });
}

const CSS = `
[data-sidebar-usage-demo] {
  box-sizing: border-box; position: relative; display: flow-root;
  width: 100%; min-width: 0; max-width: 100%; flex: none; padding: 7px 12px 8px;
  color: inherit; font-family: inherit; font-size: 11px; line-height: 1.4;
  -webkit-app-region: no-drag;
}
[data-sidebar-usage-demo][hidden], [data-sidebar-usage-demo][data-empty] { display: none !important; }
[data-sidebar-usage-demo] * { box-sizing: border-box; }
[data-sidebar-usage-demo] .sud-card {
  min-width: 0; padding: 6px 8px; max-height: var(--sud-max-height, 180px);
  overflow-y: auto; overflow-x: hidden; overscroll-behavior: contain; scrollbar-width: thin;
  border: 1px solid color-mix(in srgb, currentColor 12%, transparent);
  border-radius: 10px; background: color-mix(in srgb, currentColor 3%, transparent);
}
[data-sidebar-usage-demo] .sud-refresh {
  position: absolute; right: 3px; top: 0; padding: 1px 3px; border: 0; border-radius: 3px;
  color: inherit; background: transparent; font: inherit; cursor: pointer; opacity: 0;
}
[data-sidebar-usage-demo]:hover .sud-refresh, [data-sidebar-usage-demo]:focus-within .sud-refresh { opacity: .7; }
[data-sidebar-usage-demo] .sud-refresh:focus-visible { opacity: 1; outline: 1px solid currentColor; }
[data-sidebar-usage-demo] .sud-refresh:disabled { cursor: default; }
[data-sidebar-usage-demo] .sud-row {
  display: flex; align-items: center; gap: 6px; min-width: 0; height: 20px;
}
[data-sidebar-usage-demo] .sud-label {
  display: inline-flex; align-items: center; flex: 0 0 70px; min-width: 0;
  max-width: calc(100% - 116px); white-space: nowrap; opacity: .8;
}
[data-sidebar-usage-demo] .sud-label-text {
  flex: 0 1 auto; min-width: 0;
  overflow: hidden; text-overflow: ellipsis;
}
[data-sidebar-usage-demo] .sud-indicator-slot {
  display: inline-flex; flex: 0 0 8px; width: 8px; height: 8px;
  align-items: center; justify-content: center; margin-left: 3px;
}
[data-sidebar-usage-demo] .sud-delay {
  display: block; width: 8px; height: 8px; border-radius: 50%;
  border: 1.25px solid color-mix(in srgb, currentColor 25%, transparent);
  border-top-color: currentColor; animation: sud-delay-spin .9s linear infinite;
}
@keyframes sud-delay-spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  [data-sidebar-usage-demo] .sud-delay { animation: none; }
}
[data-sidebar-usage-demo] .sud-value {
  flex: 0 0 38px; text-align: right; white-space: nowrap;
  font-variant-numeric: tabular-nums; opacity: .85;
}
[data-sidebar-usage-demo] .sud-track {
  flex: 1 1 0; min-width: 6px; overflow: hidden; height: 3px; border-radius: 999px;
  background: color-mix(in srgb, currentColor 10%, transparent);
}
[data-sidebar-usage-demo] .sud-fill { display: block; height: 100%; border-radius: inherit; background: currentColor; opacity: .48; }
[data-sidebar-usage-demo] .sud-reset {
  flex: 0 0 54px; margin: 0; text-align: right; white-space: nowrap;
  overflow: hidden; text-overflow: ellipsis;
  opacity: .55; font-size: 10px; font-variant-numeric: tabular-nums;
}
[data-sidebar-usage-demo] .sud-notes {
  display: flex; align-items: center; justify-content: space-between; gap: 4px;
  min-width: 0; margin-top: 4px; height: 13px; opacity: .5; font-size: 9px;
}
[data-sidebar-usage-demo] .sud-notes span { min-width: 0; white-space: nowrap; }
[data-sidebar-usage-demo] .sud-more { margin-top: 6px; }
[data-sidebar-usage-demo] .sud-more summary { cursor: pointer; opacity: .65; font-size: 10px; }
[data-sidebar-usage-demo] .sud-more summary:focus-visible { outline: 1px solid currentColor; outline-offset: 2px; }
[data-sidebar-usage-demo][data-compact] { padding: 5px 10px; }
[data-sidebar-usage-demo][data-compact] .sud-card { padding: 6px 8px; }
`;

// Layer evaluates one renderer entry without Node require; keep UI code self-contained.
const createUpdateUi = (() => {


// vQc's native sidebarFooter layout: profile on the left, update action in
// the trailing flex group on the right. Scope queries to the sidebar footer.
const SLOT_SELECTOR = '[class~="h-toolbar"] > .flex.items-center[class~="empty:hidden"]';
const BUTTON_ATTRIBUTE = 'data-usage-copy-update';
const HIDDEN_ATTRIBUTE = 'data-usage-copy-native-update';
const CSS = `
[${HIDDEN_ATTRIBUTE}] { display: none !important; }
[${BUTTON_ATTRIBUTE}] {
  -webkit-app-region: no-drag; cursor: pointer; border: 0; border-radius: 999px;
  color: white; background: var(--color-chart-blue, #3b82f6); height: 22px;
  padding: 0 9px; font-family: inherit; font-size: 10px; font-weight: 600;
  line-height: 22px; white-space: nowrap; flex: none;
}
[${BUTTON_ATTRIBUTE}]:hover { filter: brightness(1.1); }
[${BUTTON_ATTRIBUTE}]:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
[${BUTTON_ATTRIBUTE}]:disabled { cursor: default; opacity: .65; }
`;

function createUpdateUi(api, doc = document) {
  let state = { status: 'unknown' }, stopped = false, launching = false, launchError = null;
  const pending = new Set();
  const label = (ko, en) => language === 'ko' ? ko : en;
  const mounts = new Map();
  const style = doc.createElement('style'); style.textContent = CSS;
  (doc.head || doc.documentElement).append(style);
  function remove(slot, mount) {
    mount.button.remove();
    for (const node of mount.hidden) node.removeAttribute(HIDDEN_ATTRIBUTE);
    mounts.delete(slot);
  }
  function reconcile() {
    if (stopped) return;
    const slots = new Set();
    if (state.status === 'available') {
      for (const root of doc.querySelectorAll('[data-sidebar-navigation-root]')) {
        if (root.closest('[inert], [data-app-shell-active-page="false"]')) continue;
        for (const footer of root.querySelectorAll('div.absolute.inset-x-0.bottom-0.z-20')) {
          if (footer.closest('[data-sidebar-navigation-root]') !== root) continue;
          const slot = footer.querySelector(SLOT_SELECTOR);
          if (slot) slots.add(slot);
        }
      }
    }
    for (const [slot, mount] of mounts) if (!slot.isConnected || !slots.has(slot)) remove(slot, mount);
    for (const slot of slots) {
      let mount = mounts.get(slot);
      if (!mount) {
        const button = doc.createElement('button');
        button.type = 'button'; button.setAttribute(BUTTON_ATTRIBUTE, '');
        mount = { button, hidden: new Set() }; mounts.set(slot, mount);
        button.addEventListener('click', async () => {
          if (launching || state.waiting) return;
          launching = true; launchError = null; reconcile();
          try {
            const result = await boundedInvoke(api, 'update:launch', pending);
            if (stopped) return;
            if (result?.ok) state = { ...state, waiting: true };
            else launchError = label('도우미를 열지 못했습니다. Update.cmd를 직접 실행해 주세요.', 'Could not open the helper. Run Update.cmd.');
          } catch { launchError = label('도우미 연결에 실패했습니다. Update.cmd를 직접 실행해 주세요.', 'Could not reach the helper. Run Update.cmd.'); }
          finally { launching = false; if (!stopped) reconcile(); }
        });
        slot.append(button);
      }
      // Hide only the native update pill in this action slot, keeping profile,
      // usage and other native actions untouched. Restore it when unmounted.
      for (const button of slot.querySelectorAll('button.bg-chart-blue')) {
        if (!button.hasAttribute(HIDDEN_ATTRIBUTE)) button.setAttribute(HIDDEN_ATTRIBUTE, '');
        mount.hidden.add(button);
      }
      if (mount.button.parentNode !== slot) slot.append(mount.button);
      const text = state.waiting ? label('종료 후 업데이트', 'Update on exit') : launching ? label('도우미 여는 중', 'Opening helper') : label('업데이트', 'Update');
      if (mount.button.textContent !== text) mount.button.textContent = text;
      mount.button.disabled = launching || state.waiting === true;
      mount.button.setAttribute('aria-label', state.waiting ? label('앱을 종료하면 업데이트를 시작합니다', 'Update after closing the app') : label('업데이트 도우미 실행', 'Open update helper'));
      mount.button.title = launchError || (state.waiting ? label('작업을 마치고 앱을 완전히 종료하면 업데이트와 재실행이 이어집니다. 도우미 창을 닫으면 취소됩니다.', 'Close the app when ready; the helper will update and relaunch it. Close the helper to cancel.')
        : (state.copyUpdateRequired ? label('원본이 업데이트되었습니다. 복사본 재패치 도우미를 엽니다.', 'The installed app is newer. Open the copy refresh helper.') : label('새 버전 업데이트 도우미를 엽니다.', 'Open the update helper.'))
          + (state.stale ? label(' Store 조회가 지연되어 마지막 결과를 사용합니다.', ' Store check delayed; using the last result.') : ''));
    }
  }
  return {
    reconcile,
    setState(next) { if (next && ['unknown','current','available','error'].includes(next.status)) { state = { ...next }; reconcile(); } },
    stop() { stopped = true; for (const cancel of [...pending]) cancel(); for (const [slot, mount] of mounts) remove(slot, mount); style.remove(); }
  };
}
return createUpdateUi;

})();

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function dateValue(value) {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value !== "string" && typeof value !== "number") return null;
  const numeric = typeof value === "number" && value < 1e12 ? value * 1000 : value;
  const time = new Date(numeric).getTime();
  return Number.isFinite(time) ? time : null;
}

function formatTime(time) {
  return new Date(time).toLocaleString(language === 'ko' ? 'ko-KR' : 'en-US', {
    month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit"
  });
}

function formatRelativeTime(time, now) {
  if (time === null) return "—";
  const remaining = time - now;
  if (remaining <= 0) return tr('resetWaiting');
  if (remaining >= 86400000) return language === 'ko' ? `${Math.ceil(remaining / 86400000)}일 후` : `in ${Math.ceil(remaining / 86400000)}d`;
  if (remaining >= 3600000) return language === 'ko' ? `${Math.ceil(remaining / 3600000)}시간 후` : `in ${Math.ceil(remaining / 3600000)}h`;
  return language === 'ko' ? `${Math.max(1, Math.ceil(remaining / 60000))}분 후` : `in ${Math.max(1, Math.ceil(remaining / 60000))}m`;
}

function initialProviders() {
  return PROVIDERS.map(provider => ({
    ...provider, status: provider.id === "claude" ? "disconnected" : "unavailable",
    checkedAt: null, attemptedAt: null, windows: []
  }));
}

function normalizeSnapshot(snapshot, previous) {
  if (!snapshot || snapshot.version !== 1 || !Array.isArray(snapshot.providers)) return null;
  return PROVIDERS.map(provider => {
    const last = previous.find(item => item.id === provider.id);
    const incoming = snapshot.providers.find(item => item && item.id === provider.id);
    if (!incoming) return last;
    const windows = (Array.isArray(incoming.windows) ? incoming.windows : []).slice(0, 20)
      .filter(window => window && typeof window.usedPercent === "number" && Number.isFinite(window.usedPercent))
      .map((window, index) => ({
        id: typeof window.id === "string" ? window.id.slice(0, 160) : String(index),
        label: typeof window.label === "string" && window.label.trim() ? window.label.slice(0, 80) : "사용량",
        usedPercent: Math.min(100, Math.max(0, window.usedPercent)),
        resetsAt: dateValue(window.resetsAt)
      }));
    const status = ["ok", "stale", "unavailable", "disconnected"].includes(incoming.status)
      ? incoming.status : "unavailable";
    const hasHistory = last.windows.length > 0;
    if (status === 'disconnected' && incoming.disabled === true) return { ...provider, status, disabled: true, checkedAt: null, attemptedAt: null, windows: [] };
    return {
      ...provider,
      status: windows.length ? (status === "ok" ? "ok" : "stale") : (hasHistory ? "stale" : status === "disconnected" ? "disconnected" : "unavailable"),
      checkedAt: dateValue(incoming.checkedAt) || last.checkedAt,
      attemptedAt: dateValue(incoming.attemptedAt),
      errorCode: Object.hasOwn(STRINGS.en.errors, incoming.errorCode) ? incoming.errorCode : null,
      nextAttemptAt: dateValue(incoming.nextAttemptAt),
      windows: windows.length ? windows : last.windows
    };
  });
}

function displayPeriod(period) {
  if (/^(?:7\s*일|주간|weekly|7\s*days?)$/i.test(period)) return "7D";
  if (/^(?:5\s*시간|5\s*hours?)$/i.test(period)) return "5H";
  if (language === 'en') return period.replace(/(\d+(?:\.\d+)?)\s*일/g, '$1D').replace(/(\d+(?:\.\d+)?)\s*시간/g, '$1H').replace(/(\d+(?:\.\d+)?)\s*분/g, '$1M');
  return period;
}

function displayWindowLabel(provider, window) {
  if (provider.id === "claude") return window.label.split("·").map(part => displayPeriod(part.trim())).join(" ");
  if (provider.id === "codex") {
    const label = window.label.replace(/^codex\s*[·:]\s*/i, "");
    return `GPT ${label.split("·").map(part => displayPeriod(part.trim())).join(" · ")}`;
  }
  if (provider.id !== "antigravity") return window.label;
  const parts = window.label.split("·").map(part => part.trim());
  const group = parts[0].replace(/^Gemini Models$/i, "Gemini");
  const sourcePeriods = new Map([["Five Hour Limit Remaining", "5시간"], ["Weekly Limit Remaining", "7일"]]);
  const period = parts.slice(1).find(part => /^(?:\d+(?:\.\d+)?\s*(?:일|시간|분)|주간|월간)$/.test(part))
    || parts.slice(1).map(part => sourcePeriods.get(part)).find(Boolean);
  const shortGroup = group === "Gemini 4 Argon" ? "Argon" : group;
  return /^Gemini\b/i.test(group) && period ? `${shortGroup} ${displayPeriod(period)}` : window.label;
}

function providerTooltip(provider) {
  const state = provider.status === 'unavailable' && !provider.attemptedAt ? tr('waiting') : tr(provider.status);
  return `${provider.label} · ${state}${provider.checkedAt != null ? `\n${tr('last')}: ${formatTime(provider.checkedAt)}` : ''}`
    + (provider.errorCode ? `\n${STRINGS[language].errors[provider.errorCode] || ''}` : '')
    + (provider.nextAttemptAt ? `\n${tr('retry')}: ${formatTime(provider.nextAttemptAt)}` : '');
}

function delayThresholdMs(provider, settings) {
  const configured = settings.providers[provider.id]?.intervalSeconds;
  const interval = Number.isFinite(configured) ? Math.max(30, Math.min(3600, configured)) : 60;
  return interval * 3000;
}

function isDelayed(provider, now, settings) {
  if (!provider.windows.length) return false;
  if (provider.checkedAt != null) return now - provider.checkedAt >= delayThresholdMs(provider, settings);
  // Cached values with no trustworthy success time cannot be presented as fresh.
  return provider.status === 'stale';
}

function delayMarker(tooltip) {
  const marker = element('span', 'sud-delay');
  marker.title = tooltip;
  marker.setAttribute('role', 'img');
  marker.setAttribute('aria-label', tooltip);
  return marker;
}

function makeRow(provider, window, now, delayed) {
  const row = element("div", "sud-row");
  const percent = window ? Math.round(window.usedPercent * 10) / 10 : null;
  const displayLabel = window ? displayWindowLabel(provider, window) : provider.id === "antigravity" ? "Gemini" : provider.label;
  const sourceLabel = window ? window.label : provider.label;
  const resetsAt = window ? window.resetsAt : null;
  const tooltip = `${providerTooltip(provider)}\n${sourceLabel}${window ? `\nID: ${window.id}` : ''}${resetsAt !== null ? `\n${tr('reset')}: ${formatTime(resetsAt)}` : ""}`;
  const label = element("span", "sud-label");
  label.append(element('span', 'sud-label-text', displayLabel));
  label.title = tooltip;
  row.title = tooltip;
  row.toggleAttribute('data-delayed', delayed);
  const track = element("div", "sud-track");
  track.setAttribute("role", "progressbar");
  track.setAttribute("aria-label", `${provider.label} ${displayLabel} ${tr('usage')}`);
  track.setAttribute("aria-valuemin", "0");
  track.setAttribute("aria-valuemax", "100");
  if (percent !== null) {
    track.setAttribute("aria-valuenow", String(percent));
    track.setAttribute("aria-valuetext", `${percent}% ${tr('used')}`);
    const fill = element("span", "sud-fill");
    fill.style.width = `${percent}%`;
    track.append(fill);
  } else {
    track.setAttribute("aria-valuetext", tr('unknown'));
  }
  const reset = element("span", "sud-reset", formatRelativeTime(resetsAt, now));
  reset.title = tooltip;
  // Keep the spinner beside the actual text within a fixed label column.
  // Its reserved slot prevents status changes from moving any column.
  const indicator = element('span', 'sud-indicator-slot');
  if (delayed) indicator.append(delayMarker(providerTooltip({ ...provider, status: 'stale' })));
  label.append(indicator);
  row.append(label, track, element("span", "sud-value", percent !== null ? `${percent}%` : "—"), reset);
  return row;
}

function renderProviders(panel, providers, now = Date.now(), settings = viewSettings()) {
  providers = visibleProviders(providers, settings);
  panel.toggleAttribute('data-empty', providers.length === 0);
  panel.setAttribute('aria-label', tr('services'));
  panel.querySelector('.sud-card').setAttribute('aria-label', tr('panel'));
  const refreshButton = panel.querySelector('.sud-refresh');
  if (refreshButton) { refreshButton.title = tr('refresh'); refreshButton.setAttribute('aria-label', tr('refresh')); }
  const list = panel.querySelector(".sud-providers");
  const expanded = new Set(Array.from(list.querySelectorAll("details[open]"), item => item.dataset.provider));
  const contents = document.createDocumentFragment();
  for (const provider of providers) {
    if (provider.status === "disconnected" && !provider.windows.length) continue;
    const section = element("section", "sud-provider");
    section.dataset.provider = provider.id;
    section.dataset.status = provider.status;
    section.setAttribute("aria-label", provider.label);
    section.title = providerTooltip(provider);
    const delayed = isDelayed(provider, now, settings);
    if (!provider.windows.length) section.append(makeRow(provider, null, now, delayed));
    // Three rows keep distinct Antigravity Gemini buckets visible by default.
    for (const window of provider.windows.slice(0, 3)) section.append(makeRow(provider, window, now, delayed));
    if (provider.windows.length > 3) {
      const details = element("details", "sud-more");
      details.dataset.provider = provider.id;
      details.open = expanded.has(provider.id);
      details.append(element("summary", "", language === 'ko' ? `추가 한도 ${provider.windows.length - 3}개` : `${provider.windows.length - 3} more limits`));
      for (const window of provider.windows.slice(3)) details.append(makeRow(provider, window, now, delayed));
      section.append(details);
    }
    contents.append(section);
  }
  const notes = element("div", "sud-notes");
  for (const provider of providers.filter(provider => provider.status === "disconnected" && !provider.windows.length)) {
    const note = element("span", `sud-${provider.id}`, `${provider.label} ${tr('disconnected')}`);
    note.dataset.provider = provider.id;
    note.dataset.status = "disconnected";
    note.title = providerTooltip(provider);
    notes.append(note);
  }
  const unavailable = providers.filter(provider => provider.status === "unavailable");
  const statusText = unavailable.length
    ? (unavailable.some(provider => provider.attemptedAt) ? tr('unavailable') : tr('waiting')) : "";
  if (statusText) {
    const status = element("span", "sud-status", statusText);
    status.title = unavailable.map(providerTooltip).join("\n\n");
    notes.append(status);
  }
  if (notes.childNodes.length) contents.append(notes);
  list.replaceChildren(contents);
}

function makePanel(providers, settings, refresh) {
  const panel = element("section");
  panel.setAttribute(PANEL_ATTRIBUTE, "1.1.0");
  panel.setAttribute("aria-label", tr('services'));
  const card = element("div", "sud-card");
  card.tabIndex = 0;
  card.setAttribute("role", "region");
  card.setAttribute("aria-label", tr('panel'));
  card.append(element("div", "sud-providers"));
  const button = element('button', 'sud-refresh', '↻'); button.type = 'button';
  button.addEventListener('click', () => { void refresh(); });
  panel.append(card, button);
  renderProviders(panel, providers, Date.now(), settings);
  return panel;
}

function rootIsVisible(root) {
  if (root.closest('[inert], [data-app-shell-active-page="false"]')) return false;
  const content = root.closest("[data-slate-sidebar-content]");
  if (content && content.hasAttribute("data-sidebar-collapsed")) return false;
  return root.getClientRects().length > 0;
}

function findFooter(root) {
  // Normal-flow content grows the native footer's measured reserved space.
  return Array.from(root.querySelectorAll(FOOTER_SELECTOR)).find(footer =>
    footer.closest(ROOT_SELECTOR) === root &&
    !footer.closest('[inert], [data-app-shell-active-page="false"]')
  ) || null;
}

function hasVisibleRecoveryAlert(doc) {
  // Native recovery pages render their heading inside role=alert. A quoted
  // error in a conversation must never count as a failed application screen.
  return Array.from(doc.querySelectorAll('[role="alert"] h1, [role="alert"] h2')).some(heading =>
    heading.getClientRects().length > 0 &&
    !heading.closest('[inert], [hidden], [aria-hidden="true"]') &&
    (heading.closest('.bg-surface-recovery') !== null || /^ChatGPT hit a snag$/i.test(heading.textContent.trim()))
  );
}

function start(api) {
  stop();
  if (api && api.process === "main") {
    mainBridge = require("./main-bridge.cjs");
    return mainBridge.start(api);
  }
  if (api && api.process && api.process !== "renderer") return;
  const previous = globalThis[DIAGNOSTIC_KEY];
  if (previous && previous.id === TWEAK_ID && typeof previous.stop === "function") previous.stop();
  const state = {
    stopped: false, reconcileTimer: null, mounts: new Map(), observer: null, style: null,
    timer: null, inFlight: false, providers: initialProviders(), renderedMinute: Math.floor(Date.now() / 60000), nextDelayAt: Infinity,
    diagnosticsEnabled: false, lastReportAt: 0, reportsRemaining: 3, settings: viewSettings(), pending: new Set(), manual: false,
    lastResumeAt: 0
  };
  language = state.settings.language;
  current = state;
  const updateUi = createUpdateUi(api);
  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = CSS;
  state.style = style;
  (document.head || document.documentElement).append(style);

  function resizeMount(root, mount) {
    const rect = root.getBoundingClientRect();
    mount.panel.hidden = !rootIsVisible(root) || rect.width < 180 || rect.height < 220;
    mount.panel.toggleAttribute("data-compact", rect.height < 560);
    mount.panel.style.setProperty("--sud-max-height", `${Math.max(90, Math.min(180, Math.floor(rect.height * .36)))}px`);
  }
  function removeMount(root, mount) {
    mount.resizeObserver.disconnect();
    mount.panel.remove();
    state.mounts.delete(root);
  }
  function reconcile() {
    state.reconcileTimer = null;
    if (state.stopped) return;
    updateUi.reconcile();
    const available = new Map();
    for (const root of document.querySelectorAll(ROOT_SELECTOR)) {
      if (!rootIsVisible(root)) continue;
      const footer = findFooter(root);
      if (footer) available.set(root, footer);
    }
    for (const [root, mount] of state.mounts) {
      if (!root.isConnected || available.get(root) !== mount.footer) removeMount(root, mount);
    }
    for (const [root, footer] of available) {
      let mount = state.mounts.get(root);
      if (!mount) {
        const panel = makePanel(state.providers, state.settings, manualRefresh);
        mount = { panel, footer, resizeObserver: null };
        mount.resizeObserver = new ResizeObserver(() => resizeMount(root, mount));
        state.mounts.set(root, mount);
        state.reportsRemaining = 3;
        footer.prepend(panel);
        mount.resizeObserver.observe(root);
      } else if (mount.panel.parentNode !== footer) footer.prepend(mount.panel);
      resizeMount(root, mount);
    }
  }
  function schedule() {
    // Hidden Electron renderers suspend animation frames. A coalesced timer
    // still mounts a sidebar that becomes available while the app is behind.
    if (!state.stopped && state.reconcileTimer === null) {
      state.reconcileTimer = setTimeout(reconcile, 50);
    }
  }
  function reportUi(now) {
    if (!state.diagnosticsEnabled || !state.reportsRemaining || now - state.lastReportAt < 30000) return;
    // Guest/settings renderers must not overwrite the app shell's evidence.
    if (!document.querySelector(ROOT_SELECTOR)) return;
    state.lastReportAt = now;
    state.reportsRemaining--;
    const visible = Array.from(state.mounts).filter(([, m]) => !m.panel.hidden && m.panel.getBoundingClientRect().height > 0);
    const withinSidebar = visible.length > 0 && visible.every(([root, m]) => {
      const r = root.getBoundingClientRect(), p = m.panel.getBoundingClientRect();
      return p.left >= r.left - 1 && p.right <= r.right + 1 && p.top >= r.top - 1 && p.bottom <= r.bottom + 1;
    });
    const composerPresent = Array.from(document.querySelectorAll('textarea, [contenteditable="true"]'))
      .some(n => n.getBoundingClientRect().width > 0 && n.getBoundingClientRect().height > 0);
    const report = {
      detectorVersion: 2,
      mountedPanels: state.mounts.size, visiblePanels: visible.length, withinSidebar, composerPresent,
      hiddenBySettings: state.mounts.size > 0 && visible.length === 0 && [...state.mounts.values()].every(m => m.panel.hasAttribute('data-empty')),
      sidebarLinkCount: Array.from(state.mounts.keys()).reduce((n, root) => n + root.querySelectorAll('a[href]').length, 0),
      claudeRows: visible.reduce((n, [, m]) => n + Array.from(m.panel.querySelectorAll('[data-provider="claude"] [role="progressbar"][aria-valuenow]'))
        .filter(row => row.getClientRects().length > 0).length, 0),
      snagDetected: hasVisibleRecoveryAlert(document)
    };
    void api.ipc.invoke('usage:ui-report', report).catch(() => {});
  }
  function paint() {
    const now = Date.now();
    for (const mount of state.mounts.values()) renderProviders(mount.panel, state.providers, now, state.settings);
    state.renderedMinute = Math.floor(now / 60000);
    state.nextDelayAt = Math.min(Infinity, ...state.providers.filter(p => p.windows.length && p.checkedAt != null)
      .map(p => p.checkedAt + delayThresholdMs(p, state.settings)).filter(deadline => deadline > now));
  }
  function failedConnection() {
    state.providers = state.providers.map(p => p.disabled || p.status === 'disconnected' ? p : ({ ...p,
      status: p.windows.length ? 'stale' : 'unavailable', attemptedAt: Date.now(), errorCode: 'IPC_ERROR' }));
  }
  async function manualRefresh(reason = 'manual') {
    if (state.stopped || state.manual) return;
    state.manual = true;
    for (const mount of state.mounts.values()) mount.panel.querySelector('.sud-refresh').disabled = true;
    try {
      const result = await boundedInvoke(api, 'usage:refresh', state.pending, 10000, { reason });
      if (state.stopped) return;
      if (!result?.ok) throw new Error('refresh unavailable');
      void refresh();
    } catch {
      if (!state.stopped) { failedConnection(); paint(); }
    } finally {
      state.manual = false;
      if (!state.stopped) for (const mount of state.mounts.values()) mount.panel.querySelector('.sud-refresh').disabled = false;
    }
  }
  async function refresh() {
    if (state.stopped || state.inFlight) return;
    clearTimeout(state.timer); state.timer = null;
    state.inFlight = true;
    let changed = false;
    try {
      const snapshot = await boundedInvoke(api, 'usage:get', state.pending);
      if (state.stopped) return;
      state.diagnosticsEnabled = snapshot?.diagnosticsEnabled === true;
      const settings = viewSettings(snapshot?.usage);
      if (JSON.stringify(settings) !== JSON.stringify(state.settings)) { state.settings = settings; changed = true; }
      language = settings.language;
      updateUi.setState(snapshot?.appUpdate);
      const normalized = normalizeSnapshot(snapshot, state.providers);
      if (!normalized) throw new Error('invalid snapshot');
      // A reachable bridge can itself be stuck. Keep old percentages while
      // marking readings older than the configured polling allowance.
      for (const provider of normalized) {
        if (provider.status === 'ok' && isDelayed(provider, Date.now(), settings)) {
          provider.status = 'stale'; provider.errorCode = 'STALE_DATA';
        }
      }
      if (JSON.stringify(normalized) !== JSON.stringify(state.providers)) {
        state.providers = normalized;
        changed = true;
      }
    } catch (_) {
      if (!state.stopped) { failedConnection(); changed = true; }
    } finally {
      state.inFlight = false;
      if (!state.stopped) {
        const now = Date.now();
        const minute = Math.floor(now / 60000);
        if (changed || minute !== state.renderedMinute || now >= state.nextDelayAt) {
          paint();
        }
        reportUi(now);
        state.timer = setTimeout(refresh, document.hidden ? 15000 : 5000);
      }
    }
  }
  state.observer = new MutationObserver(records => {
    if (records.some(record => {
      const target = record.target.nodeType === 1 ? record.target : record.target.parentElement;
      if (!target || target.closest(`[${PANEL_ATTRIBUTE}], [data-usage-copy-update]`)) return false;
      if (record.type === 'attributes') return !!target.closest(ROOT_SELECTOR) || !!target.querySelector(ROOT_SELECTOR);
      if (target.closest(FOOTER_SELECTOR)) return true;
      // Chat streaming outside the footer cannot affect these mounts. Inspect
      // only added/removed shell roots; avoid layout reads for unrelated edits.
      return [...record.addedNodes, ...record.removedNodes].some(node => node.nodeType === 1 &&
        (node.matches(`${ROOT_SELECTOR}, ${FOOTER_SELECTOR}`) || node.querySelector(`${ROOT_SELECTOR}, ${FOOTER_SELECTOR}`)));
    })) schedule();
  });
  state.observer.observe(document.documentElement, {
    childList: true, subtree: true, attributes: true,
    attributeFilter: ["data-sidebar-collapsed", "inert", "data-app-shell-active-page"]
  });
  window.addEventListener("resize", schedule);
  function resume() {
    if (state.stopped || document.hidden || Date.now() - state.lastResumeAt < 10000) return;
    state.lastResumeAt = Date.now();
    void manualRefresh('resume'); schedule();
  }
  window.addEventListener('focus', resume);
  window.addEventListener('pageshow', resume);
  document.addEventListener('visibilitychange', resume);

  const diagnostic = {
    id: TWEAK_ID, version: "1.1.0", dataSource: "local-collector",
    getSnapshot() {
      return {
        running: !state.stopped,
        mountedPanels: state.mounts.size,
        providers: state.providers.map(provider => ({
          id: provider.id, status: provider.status, disabled: provider.disabled === true, checkedAt: provider.checkedAt,
          windows: provider.windows.map(window => ({ id: window.id, usedPercent: window.usedPercent, resetsAt: window.resetsAt }))
        })),
        panels: Array.from(state.mounts, ([root, mount]) => ({
          connected: mount.panel.isConnected, hidden: mount.panel.hidden,
          compact: mount.panel.hasAttribute("data-compact"),
          panelHeight: mount.panel.getBoundingClientRect().height,
          footerHeight: mount.footer.getBoundingClientRect().height,
          reservedFooterHeight: getComputedStyle(root).getPropertyValue("--sidebar-footer-height").trim()
        }))
      };
    },
    stop() {
      if (state.stopped) return;
      state.stopped = true;
      if (state.reconcileTimer !== null) clearTimeout(state.reconcileTimer);
      if (state.timer) clearTimeout(state.timer);
      for (const cancel of [...state.pending]) cancel();
      state.observer.disconnect();
      updateUi.stop();
      window.removeEventListener("resize", schedule);
      window.removeEventListener('focus', resume);
      window.removeEventListener('pageshow', resume);
      document.removeEventListener('visibilitychange', resume);
      for (const [root, mount] of state.mounts) removeMount(root, mount);
      state.style.remove();
      if (globalThis[DIAGNOSTIC_KEY] === diagnostic) delete globalThis[DIAGNOSTIC_KEY];
      if (current === state) current = null;
    }
  };
  state.stop = diagnostic.stop;
  globalThis[DIAGNOSTIC_KEY] = diagnostic;
  reconcile();
  void refresh();
}

function stop() {
  if (current && current.stop) current.stop();
  if (mainBridge) {
    const bridge = mainBridge;
    mainBridge = null;
    if (typeof bridge.stop === "function") return bridge.stop();
  }
}

module.exports = { start, stop, hasVisibleRecoveryAlert, normalizeSnapshot, initialProviders, displayWindowLabel, createUpdateUi, viewSettings, visibleProviders, boundedInvoke, isDelayed };
