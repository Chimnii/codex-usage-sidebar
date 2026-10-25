'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createUpdateMenu, MENU_ID, CHECKING_LABEL } = require('../tweak/update-menu.cjs');
const { createUpdateController } = require('../tweak/update-bridge.cjs');

function fixture(check = async () => ({ ok: true, state: { status: 'current' } })) {
  const dialogs = [], nativeCalls = [], unrelated = [];
  const log = { info: () => {} }, builtin = { checkForUpdates: () => { nativeCalls.push('native'); } };
  function original() { log.info('Check for updates requested via menu.'); return builtin.checkForUpdates(); }
  function build(template) { return { items: template.map(item => ({ enabled: true, ...item,
    click: typeof item.click === 'function' ? function(...args) { return item.click(...args); } : undefined,
    submenu: Array.isArray(item.submenu) ? build(item.submenu) : item.submenu })) }; }
  const Menu = { current: null, buildFromTemplate: build,
    getApplicationMenu() { return this.current; }, setApplicationMenu(menu) { this.current = menu; } };
  const savedBuild = Menu.buildFromTemplate, savedSet = Menu.setApplicationMenu;
  const bridge = createUpdateMenu({ Menu, dialog: { showMessageBox: async (...args) => { dialogs.push(args.at(-1)); } }, updater: { check }, log });
  function install(label='업데이트 확인…') {
    const template = [{ id:'help', role:'help', label:'도움말', submenu:[
      {label:'Documentation',click:()=>unrelated.push('docs')},{label,click:original}
    ] }];
    const menu=Menu.buildFromTemplate(template);Menu.setApplicationMenu(menu);
    return { menu, item:menu.items[0].submenu.items[1], other:menu.items[0].submenu.items[0], template };
  }
  return { bridge, Menu, install, dialogs, nativeCalls, unrelated, original, savedBuild, savedSet };
}
test('native Help action is replaced before menu construction; labels and unrelated actions are preserved',async()=>{
  const x=fixture(),m=x.install();assert.equal(m.item.id,MENU_ID);assert.equal(m.template[0].submenu[1].id,undefined);
  await m.item.click();assert.equal(x.dialogs[0].message,'최신 버전입니다.');assert.equal(x.nativeCalls.length,0);
  m.other.click();assert.deepEqual(x.unrelated,['docs']);assert.equal(m.item.label,'업데이트 확인…');assert.equal(m.item.enabled,true);x.bridge.stop();
});
test('language changes and menu rebuilds keep one connected entry without duplicate handling',async()=>{
  const x=fixture();for(const label of ['Check for Updates…','업데이트 확인…','アップデートを確認…']) {
    const m=x.install(label);assert.equal(x.bridge.getPatchedCount(),1);await m.item.click();assert.equal(m.item.label,label);
  }
  assert.equal(x.dialogs.length,3);assert.equal(x.nativeCalls.length,0);x.bridge.stop();
});
test('a manual request disables the menu and coalesces repeated clicks and dialogs',async()=>{
  let finish,calls=0;const x=fixture(()=>{calls++;return new Promise(r=>finish=r)}),m=x.install();
  const a=m.item.click(),b=m.item.click();assert.equal(a,b);assert.equal(m.item.enabled,false);assert.equal(m.item.label,CHECKING_LABEL);
  await Promise.resolve();assert.equal(calls,1);const rebuilt=x.install('새 언어 메뉴');assert.equal(rebuilt.item.enabled,false);
  finish({ok:true,state:{status:'available',storeUpdateAvailable:true}});await a;
  assert.equal(x.dialogs.length,1);assert.equal(x.dialogs[0].message,'새 업데이트가 있습니다.');assert.equal(rebuilt.item.enabled,true);
  assert.equal(rebuilt.item.label,'새 언어 메뉴');assert.equal(x.nativeCalls.length,0);x.bridge.stop();
});
test('failure is shown as failure despite retained latest/available state; thrown errors also get an explanation',async()=>{
  for(const state of ['current','available','error']) {
    const x=fixture(async()=>({ok:false,reason:'check-failed',state:{status:state,stale:true}}));await x.install().item.click();
    assert.equal(x.dialogs[0].type,'warning');assert.match(x.dialogs[0].message,/확인하지 못했습니다/);assert.doesNotMatch(x.dialogs[0].message,/최신/);x.bridge.stop();
  }
  const x=fixture(async()=>{throw Error('credential-like raw stderr')});await x.install().item.click();
  assert.match(x.dialogs[0].message,/확인하지 못했습니다/);assert.doesNotMatch(JSON.stringify(x.dialogs),/credential/);x.bridge.stop();
});
test('already updated Store original produces a repatch notice without installing anything',async()=>{
  const x=fixture(async()=>({ok:true,state:{status:'available',copyUpdateRequired:true,storeUpdateAvailable:false}}));await x.install().item.click();
  assert.equal(x.dialogs[0].message,'원본 앱이 업데이트되었습니다.');assert.equal(x.nativeCalls.length,0);x.bridge.stop();
});
test('unload restores original menu handlers and suppresses a late result dialog',async()=>{
  let finish;const x=fixture(()=>new Promise(r=>finish=r)),m=x.install();const p=m.item.click();await Promise.resolve();x.bridge.stop();
  finish({ok:true,state:{status:'current'}});await p;assert.equal(x.dialogs.length,0);
  assert.equal(x.Menu.buildFromTemplate,x.savedBuild);assert.equal(x.Menu.setApplicationMenu,x.savedSet);
  assert.equal(m.item.enabled,true);assert.equal(m.item.label,'업데이트 확인…');m.item.click();assert.deepEqual(x.nativeCalls,['native']);
});
test('a manual Help click joins a background query and leaves one scheduled retry after failure',async()=>{
  let finish,calls=0;const timers=[];
  const updater=createUpdateController({projectRoot:'fixture',dataDir:'fixture',runningPackage:'fixture'}, {
    readFile:()=>{throw Error('no cache')},writeFile:()=>{},setTimeout:(fn,delay)=>{const t={fn,delay};timers.push(t);return t},clearTimeout:t=>{if(t)t.cancelled=true},
    query:()=>{calls++;return new Promise((resolve,reject)=>finish=reject)},spawn:()=>{throw Error('No process launch permitted')}
  });
  const pending=updater.check();await Promise.resolve();const x=fixture(()=>updater.check());const click=x.install().item.click();await Promise.resolve();
  assert.equal(calls,1);finish(Error('offline'));await pending;await click;assert.match(x.dialogs[0].message,/확인하지 못했습니다/);
  assert.equal(timers.filter(t=>!t.cancelled).length,1);x.bridge.stop();updater.stop();
});
