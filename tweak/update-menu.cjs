'use strict';
const MENU_ID = 'usage-sidebar-check-for-updates';
const CHECKING_LABEL = '업데이트 확인 중…';

function isNativeUpdateClick(click) {
  if (typeof click !== 'function') return false;
  const source = Function.prototype.toString.call(click);
  // Match the app's action, independent of translated labels or menu position.
  return source.includes('Check for updates requested via menu.') && source.includes('.checkForUpdates(');
}

function createUpdateMenu({ Menu, dialog, BrowserWindow, updater, log }) {
  if (typeof Menu?.buildFromTemplate !== 'function' || typeof Menu?.setApplicationMenu !== 'function') throw new Error('Menu API unavailable');
  const build = Menu.buildFromTemplate, set = Menu.setApplicationMenu;
  const entries = new Map();
  let stopped = false, manual = null;
  function busy(value) {
    for (const [item, saved] of entries) {
      item.enabled = value ? false : saved.enabled;
      item.label = value ? CHECKING_LABEL : saved.label;
    }
  }
  async function showResult(result) {
    if (stopped || result?.reason === 'stopped') return;
    let message, detail, type = 'info';
    if (!result?.ok) {
      type = 'warning'; message = '업데이트를 확인하지 못했습니다.';
      detail = '잠시 후 다시 확인해 주세요. 이전에 확인한 업데이트 정보는 유지됩니다.';
    } else if (result.state.status === 'available') {
      message = result.state.copyUpdateRequired && !result.state.storeUpdateAvailable
        ? '원본 앱이 업데이트되었습니다.' : '새 업데이트가 있습니다.';
      detail = '사이드바 아래의 업데이트 버튼으로 진행할 수 있습니다. 이 확인만으로 설치하거나 앱을 종료하지 않습니다.';
    } else {
      message = '최신 버전입니다.';
      detail = 'Microsoft Store에 현재 설치할 수 있는 새 업데이트가 없고, 복사본도 설치된 원본과 같은 버전입니다.';
    }
    const options = { type, title: '업데이트 확인', message, detail, buttons: ['확인'], noLink: true };
    const owner = BrowserWindow?.getFocusedWindow?.();
    if (owner && !owner.isDestroyed()) await dialog.showMessageBox(owner, options);
    else await dialog.showMessageBox(options);
  }
  function onClick() {
    if (stopped) return Promise.resolve();
    if (manual) return manual;
    busy(true);
    manual = Promise.resolve().then(() => stopped ? { ok: false, reason: 'stopped' } : updater.check())
      .catch(() => ({ ok: false, reason: 'check-failed' })).then(showResult)
      .catch(() => { if (!stopped) log?.warn?.('Manual update check could not display its result.'); })
      .finally(() => { manual = null; if (!stopped) busy(false); });
    return manual;
  }
  function wire(menu, originals = new Map()) {
    for (const item of menu?.items || []) {
      const original = originals.get(item.id);
      if (original || entries.has(item) || isNativeUpdateClick(item.click)) {
        if (!entries.has(item)) entries.set(item, { click: original?.click || item.click, label: item.label, enabled: item.enabled });
        item.click = onClick;
        if (manual) { item.enabled = false; item.label = CHECKING_LABEL; }
      }
      if (item.submenu) wire(item.submenu, originals);
    }
  }
  function buildWrapped(template, ...args) {
    const originals = new Map();
    function transform(items) {
      return items.map(item => {
        let next = item;
        if (Array.isArray(item.submenu)) next = { ...next, submenu: transform(item.submenu) };
        if (isNativeUpdateClick(item.click)) {
          const id = item.id || MENU_ID;
          originals.set(id, { click: item.click });
          next = { ...next, id, click: onClick };
        }
        return next;
      });
    }
    const menu = build.call(Menu, transform(template), ...args);
    wire(menu, originals);
    return menu;
  }
  function setWrapped(menu, ...args) {
    wire(menu);
    const live = new Set();
    function visit(m) { for (const item of m?.items || []) { live.add(item); visit(item.submenu); } }
    visit(menu);
    for (const [item, saved] of entries) if (!live.has(item)) {
      if (item.click === onClick) { item.click = saved.click; item.label = saved.label; item.enabled = saved.enabled; }
      entries.delete(item);
    }
    return set.call(Menu, menu, ...args);
  }
  try {
    Menu.buildFromTemplate = buildWrapped;
    Menu.setApplicationMenu = setWrapped;
    wire(Menu.getApplicationMenu?.());
  } catch (error) {
    if (Menu.buildFromTemplate === buildWrapped) Menu.buildFromTemplate = build;
    if (Menu.setApplicationMenu === setWrapped) Menu.setApplicationMenu = set;
    for (const [item, saved] of entries) if (item.click === onClick) {
      item.click = saved.click; item.label = saved.label; item.enabled = saved.enabled;
    }
    throw error;
  }
  return { check: onClick, getPatchedCount: () => entries.size,
    stop() {
      stopped = true;
      if (Menu.buildFromTemplate === buildWrapped) Menu.buildFromTemplate = build;
      if (Menu.setApplicationMenu === setWrapped) Menu.setApplicationMenu = set;
      for (const [item, saved] of entries) if (item.click === onClick) {
        item.click = saved.click; item.label = saved.label; item.enabled = saved.enabled;
      }
      entries.clear();
    }
  };
}
module.exports = { createUpdateMenu, isNativeUpdateClick, MENU_ID, CHECKING_LABEL };
