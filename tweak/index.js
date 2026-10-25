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

const CSS = `
[data-sidebar-usage-demo] {
  box-sizing: border-box; position: relative; display: flow-root;
  width: 100%; min-width: 0; max-width: 100%; flex: none; padding: 7px 12px 8px;
  color: inherit; font-family: inherit; font-size: 11px; line-height: 1.4;
  -webkit-app-region: no-drag;
}
[data-sidebar-usage-demo][hidden] { display: none !important; }
[data-sidebar-usage-demo] * { box-sizing: border-box; }
[data-sidebar-usage-demo] .sud-card {
  min-width: 0; padding: 6px 8px; max-height: var(--sud-max-height, 180px);
  overflow-y: auto; overflow-x: hidden; overscroll-behavior: contain; scrollbar-width: thin;
  border: 1px solid color-mix(in srgb, currentColor 12%, transparent);
  border-radius: 10px; background: color-mix(in srgb, currentColor 3%, transparent);
}
[data-sidebar-usage-demo] .sud-row {
  display: flex; align-items: center; gap: 6px; min-width: 0; height: 20px;
}
[data-sidebar-usage-demo] .sud-label {
  flex: 0 0 62px; min-width: 0; max-width: calc(100% - 116px);
  overflow: hidden; text-overflow: ellipsis;
  white-space: nowrap; opacity: .8;
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
            const result = await api.ipc.invoke('update:launch');
            if (stopped) return;
            if (result?.ok) state = { ...state, waiting: true };
            else launchError = '도우미를 열지 못했습니다. Update.cmd를 직접 실행해 주세요.';
          } catch { launchError = '도우미 연결에 실패했습니다. Update.cmd를 직접 실행해 주세요.'; }
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
      const label = state.waiting ? '종료 후 업데이트' : launching ? '도우미 여는 중' : '업데이트';
      if (mount.button.textContent !== label) mount.button.textContent = label;
      mount.button.disabled = launching || state.waiting === true;
      mount.button.setAttribute('aria-label', state.waiting ? '앱을 종료하면 업데이트를 시작합니다' : '업데이트 도우미 실행');
      mount.button.title = launchError || (state.waiting ? '작업을 마치고 앱을 완전히 종료하면 업데이트와 재실행이 이어집니다. 도우미 창을 닫으면 취소됩니다.'
        : `${state.copyUpdateRequired ? '원본이 업데이트되었습니다. 복사본 재패치' : '새 버전 업데이트'} 도우미를 엽니다.${state.stale ? ' 마지막 조회 결과입니다.' : ''}`);
    }
  }
  return {
    reconcile,
    setState(next) { if (next && ['unknown','current','available','error'].includes(next.status)) { state = { ...next }; reconcile(); } },
    stop() { stopped = true; for (const [slot, mount] of mounts) remove(slot, mount); style.remove(); }
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
  return new Date(time).toLocaleString("ko-KR", {
    month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit"
  });
}

function formatRelativeTime(time, now) {
  if (time === null) return "—";
  const remaining = time - now;
  if (remaining <= 0) return "초기화 대기";
  if (remaining >= 86400000) return `${Math.ceil(remaining / 86400000)}일 후`;
  if (remaining >= 3600000) return `${Math.ceil(remaining / 3600000)}시간 후`;
  return `${Math.max(1, Math.ceil(remaining / 60000))}분 후`;
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
        id: typeof window.id === "string" ? window.id.slice(0, 100) : String(index),
        label: typeof window.label === "string" && window.label.trim() ? window.label.slice(0, 80) : "사용량",
        usedPercent: Math.min(100, Math.max(0, window.usedPercent)),
        resetsAt: dateValue(window.resetsAt)
      }));
    const status = ["ok", "stale", "unavailable", "disconnected"].includes(incoming.status)
      ? incoming.status : "unavailable";
    const hasHistory = last.windows.length > 0;
    if (status === 'disconnected' && incoming.disabled === true) return { ...provider, status, checkedAt: null, attemptedAt: null, windows: [] };
    return {
      ...provider,
      status: windows.length ? (status === "ok" ? "ok" : "stale") : (hasHistory ? "stale" : status === "disconnected" ? "disconnected" : "unavailable"),
      checkedAt: dateValue(incoming.checkedAt) || last.checkedAt,
      attemptedAt: dateValue(incoming.attemptedAt),
      windows: windows.length ? windows : last.windows
    };
  });
}

function displayPeriod(period) {
  if (/^(?:7\s*일|주간)$/.test(period)) return "7D";
  if (/^5\s*시간$/.test(period)) return "5H";
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
  const state = provider.status === "stale" ? "갱신 지연"
    : provider.status === "ok" ? "사용률"
    : provider.status === "disconnected" ? "미연결"
    : provider.attemptedAt ? "조회 불가" : "조회 대기";
  return `${provider.label} · ${state}${provider.checkedAt !== null ? `\n마지막 조회 성공: ${formatTime(provider.checkedAt)}` : ""}`;
}

function makeRow(provider, window, now) {
  const row = element("div", "sud-row");
  const percent = window ? Math.round(window.usedPercent * 10) / 10 : null;
  const displayLabel = window ? displayWindowLabel(provider, window) : provider.id === "antigravity" ? "Gemini" : provider.label;
  const sourceLabel = window ? window.label : provider.label;
  const resetsAt = window ? window.resetsAt : null;
  const tooltip = `${providerTooltip(provider)}\n${sourceLabel}${resetsAt !== null ? `\n${formatTime(resetsAt)} 초기화 예정` : ""}`;
  const label = element("span", "sud-label", displayLabel);
  label.title = tooltip;
  row.title = tooltip;
  const track = element("div", "sud-track");
  track.setAttribute("role", "progressbar");
  track.setAttribute("aria-label", `${provider.label} ${displayLabel} 사용량`);
  track.setAttribute("aria-valuemin", "0");
  track.setAttribute("aria-valuemax", "100");
  if (percent !== null) {
    track.setAttribute("aria-valuenow", String(percent));
    track.setAttribute("aria-valuetext", `${percent}% 사용`);
    const fill = element("span", "sud-fill");
    fill.style.width = `${percent}%`;
    track.append(fill);
  } else {
    track.setAttribute("aria-valuetext", "사용량 정보 없음");
  }
  const reset = element("span", "sud-reset", formatRelativeTime(resetsAt, now));
  reset.title = tooltip;
  row.append(label, track, element("span", "sud-value", percent !== null ? `${percent}%` : "—"), reset);
  return row;
}

function renderProviders(panel, providers, now = Date.now()) {
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
    if (!provider.windows.length) section.append(makeRow(provider, null, now));
    // Three rows keep distinct Antigravity Gemini buckets visible by default.
    for (const window of provider.windows.slice(0, 3)) section.append(makeRow(provider, window, now));
    if (provider.windows.length > 3) {
      const details = element("details", "sud-more");
      details.dataset.provider = provider.id;
      details.open = expanded.has(provider.id);
      details.append(element("summary", "", `추가 한도 ${provider.windows.length - 3}개`));
      for (const window of provider.windows.slice(3)) details.append(makeRow(provider, window, now));
      section.append(details);
    }
    contents.append(section);
  }
  const notes = element("div", "sud-notes");
  for (const provider of providers.filter(provider => provider.status === "disconnected" && !provider.windows.length)) {
    const note = element("span", `sud-${provider.id}`, `${provider.label} 미연결`);
    note.dataset.provider = provider.id;
    note.dataset.status = "disconnected";
    note.title = `${provider.label} · 미연결`;
    notes.append(note);
  }
  const delayed = providers.filter(provider => provider.status === "stale");
  const unavailable = providers.filter(provider => provider.status === "unavailable");
  const statusText = delayed.length ? "갱신 지연" : unavailable.length
    ? (unavailable.some(provider => provider.attemptedAt) ? "조회 불가" : "조회 대기") : "";
  if (statusText) {
    const status = element("span", "sud-status", statusText);
    status.title = [...delayed, ...unavailable].map(providerTooltip).join("\n\n");
    notes.append(status);
  }
  if (notes.childNodes.length) contents.append(notes);
  list.replaceChildren(contents);
}

function makePanel(providers) {
  const panel = element("section");
  panel.setAttribute(PANEL_ATTRIBUTE, "1.0.0");
  panel.setAttribute("aria-label", "서비스 사용량");
  const card = element("div", "sud-card");
  card.tabIndex = 0;
  card.setAttribute("role", "region");
  card.setAttribute("aria-label", "사용량 패널");
  card.append(element("div", "sud-providers"));
  panel.append(card);
  renderProviders(panel, providers);
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
    timer: null, inFlight: false, providers: initialProviders(), renderedMinute: Math.floor(Date.now() / 60000),
    diagnosticsEnabled: false, lastReportAt: 0
  };
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
        const panel = makePanel(state.providers);
        mount = { panel, footer, resizeObserver: null };
        mount.resizeObserver = new ResizeObserver(() => resizeMount(root, mount));
        state.mounts.set(root, mount);
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
    if (!state.diagnosticsEnabled || now - state.lastReportAt < 30000) return;
    // Guest/settings renderers must not overwrite the app shell's evidence.
    if (!document.querySelector(ROOT_SELECTOR)) return;
    state.lastReportAt = now;
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
      sidebarLinkCount: Array.from(state.mounts.keys()).reduce((n, root) => n + root.querySelectorAll('a[href]').length, 0),
      claudeRows: visible.reduce((n, [, m]) => n + Array.from(m.panel.querySelectorAll('[data-provider="claude"] [role="progressbar"][aria-valuenow]'))
        .filter(row => row.getClientRects().length > 0).length, 0),
      snagDetected: hasVisibleRecoveryAlert(document)
    };
    void api.ipc.invoke('usage:ui-report', report).catch(() => {});
  }
  async function refresh() {
    if (state.stopped || state.inFlight) return;
    state.inFlight = true;
    let changed = false;
    try {
      const snapshot = await api.ipc.invoke("usage:get");
      if (state.stopped) return;
      state.diagnosticsEnabled = snapshot?.diagnosticsEnabled === true;
      updateUi.setState(snapshot?.appUpdate);
      const normalized = normalizeSnapshot(snapshot, state.providers);
      if (normalized && JSON.stringify(normalized) !== JSON.stringify(state.providers)) {
        state.providers = normalized;
        changed = true;
      }
    } catch (_) {
      // IPC failure keeps the last display, or the initial blank values.
    } finally {
      state.inFlight = false;
      if (!state.stopped) {
        const now = Date.now();
        const minute = Math.floor(now / 60000);
        if (changed || minute !== state.renderedMinute) {
          for (const mount of state.mounts.values()) renderProviders(mount.panel, state.providers, now);
          state.renderedMinute = minute;
        }
        reportUi(now);
        state.timer = setTimeout(refresh, 5000);
      }
    }
  }
  state.observer = new MutationObserver(records => {
    if (records.some(record => {
      const target = record.target.nodeType === 1 ? record.target : record.target.parentElement;
      return !target || (!target.closest(`[${PANEL_ATTRIBUTE}]`) && !target.closest('[data-usage-copy-update]'));
    })) schedule();
  });
  state.observer.observe(document.documentElement, {
    childList: true, subtree: true, attributes: true,
    attributeFilter: ["data-sidebar-collapsed", "inert", "data-app-shell-active-page"]
  });
  window.addEventListener("resize", schedule);

  const diagnostic = {
    id: TWEAK_ID, version: "1.0.0", dataSource: "local-collector",
    getSnapshot() {
      return {
        running: !state.stopped,
        mountedPanels: state.mounts.size,
        providers: state.providers.map(provider => ({
          id: provider.id, status: provider.status, checkedAt: provider.checkedAt,
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
      state.observer.disconnect();
      updateUi.stop();
      window.removeEventListener("resize", schedule);
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

module.exports = { start, stop, hasVisibleRecoveryAlert, normalizeSnapshot, initialProviders, displayWindowLabel, createUpdateUi };
