'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const output=path.resolve(__dirname,'../.local/test-results/update-ui');fs.mkdirSync(output,{recursive:true});
const indexSource=fs.readFileSync(path.resolve(__dirname,'../tweak/index.js'),'utf8');
const uiSource=indexSource;
const fixture=`<html lang="ko"><style>
body{margin:0;font:13px Arial;background:#202123;color:#eee}*{box-sizing:border-box}
.sidebar{position:relative;width:300px;height:720px;background:#171819;--color-chart-blue:#2778df}
.absolute{position:absolute}.inset-x-0{left:0;right:0}.bottom-0{bottom:0}.flex{display:flex}.items-center{align-items:center}.h-toolbar{height:48px;padding:0 12px;gap:8px}.grow{flex:1;min-width:0}
.native-slot{gap:4px}button{color:inherit;background:none;border:0;padding:5px;cursor:pointer}.bg-chart-blue{background:#2778df}.body{padding:16px}.chat{position:absolute;left:320px;top:20px}.usage-placeholder{margin:8px 12px;padding:12px;border:1px solid #444;border-radius:9px}
</style><body><aside class="sidebar" data-sidebar-navigation-root><div class="body">새 채팅<br><br>프로젝트<br><br>사용량 표시 툴<br><br>진행 중인 작업</div><div class="absolute inset-x-0 bottom-0 z-20"><div class="usage-placeholder">GPT 7D ━━━━━━━━━ 42%</div><div class="h-toolbar flex items-center"><div class="grow"><button id="profile">사용자 · Pro</button></div><div class="native-slot flex items-center empty:hidden"><button class="bg-chart-blue" id="native-update">Update</button><button id="other-action">⋯</button></div></div></div></aside><main class="chat"><h2>대화 화면</h2><button class="bg-chart-blue" id="chat-update">대화 안의 업데이트 예시</button></main></body></html>`;
test('native footer slot: hidden/current/available/waiting, deduplication, remount and cleanup',async()=>{
  const browser=await chromium.launch({channel:'msedge',headless:true});
  try{
    const page=await browser.newPage({viewport:{width:850,height:740}});await page.setContent(fixture);
    await page.addScriptTag({content:`(()=>{const module={exports:{}};${uiSource}\nwindow.calls=[];window.fail=false;window.ui=module.exports.createUpdateUi({ipc:{invoke:async name=>{calls.push(name);return {ok:!window.fail}}}});})();`});
    await page.evaluate(()=>ui.setState({status:'current'}));assert.equal(await page.locator('[data-usage-copy-update]').count(),0);
    await page.evaluate(()=>{ui.setState({status:'available'});ui.reconcile();ui.reconcile();});
    assert.equal(await page.locator('[data-usage-copy-update]').count(),1);
    assert.equal(await page.locator('#native-update').isVisible(),false);assert.equal(await page.locator('#other-action').isVisible(),true);assert.equal(await page.locator('#chat-update').isVisible(),true);
    for(const width of [300,200]){
      await page.locator('.sidebar').evaluate((n,w)=>n.style.width=w+'px',width);
      const button=await page.locator('[data-usage-copy-update]').boundingBox();const root=await page.locator('.sidebar').boundingBox();
      assert.ok(button.x+button.width<=root.x+root.width);assert.ok(button.y+button.height<=root.y+root.height);
      await page.screenshot({path:path.join(output,`footer-${width}.png`)});
    }
    await page.locator('[data-usage-copy-update]').click();assert.deepEqual(await page.evaluate(()=>calls),['update:launch']);
    assert.equal(await page.locator('[data-usage-copy-update]').textContent(),'종료 후 업데이트');assert.equal(await page.locator('[data-usage-copy-update]').isDisabled(),true);
    await page.evaluate(()=>{ui.setState({status:'available',waiting:false});window.fail=true;});await page.locator('[data-usage-copy-update]').click();
    assert.match(await page.locator('[data-usage-copy-update]').getAttribute('title'),/열지 못했습니다/);
    await page.evaluate(()=>{const old=document.querySelector('.native-slot');const copy=old.cloneNode(true);copy.querySelector('[data-usage-copy-update]').remove();copy.querySelector('#native-update').removeAttribute('data-usage-copy-native-update');old.replaceWith(copy);ui.reconcile();});
    assert.equal(await page.locator('[data-usage-copy-update]').count(),1);
    await page.evaluate(()=>ui.setState({status:'current'}));assert.equal(await page.locator('[data-usage-copy-update]').count(),0);assert.equal(await page.locator('#native-update').isVisible(),true);
    await page.evaluate(()=>{ui.setState({status:'available'});ui.stop();});assert.equal(await page.locator('[data-usage-copy-update]').count(),0);assert.equal(await page.locator('#native-update').isVisible(),true);
  }finally{await browser.close();}
});
test('full usage tweak mounts quota and update action together without duplicate renders',async()=>{
  const browser=await chromium.launch({channel:'msedge',headless:true});
  try{
    const page=await browser.newPage({viewport:{width:850,height:740}});const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.setContent(fixture);await page.locator('.usage-placeholder').evaluate(n=>n.remove());
    // Same sandbox constraint as Layer: no require, no filesystem, one entry.
    await page.addScriptTag({content:`(()=>{const module={exports:{}};${indexSource}\nwindow.tweak=module.exports;window.testApi={process:'renderer',ipc:{invoke:async name=>name==='usage:get'?{version:1,providers:[{id:'codex',status:'ok',windows:[{id:'week',label:'Codex · 7일',usedPercent:42,resetsAt:'2026-10-30T00:00:00Z'}]},{id:'antigravity',status:'ok',windows:[{id:'gemini',label:'Gemini Models · 5시간',usedPercent:31,resetsAt:'2026-10-24T05:00:00Z'}]},{id:'claude',status:'ok',windows:[{id:'claude5',label:'Claude · 5시간',usedPercent:9,resetsAt:'2026-10-24T04:00:00Z'}]}],appUpdate:{status:'available'}}:{ok:true}}};tweak.start(testApi);})();`});
    await page.locator('[data-sidebar-usage-demo] [role="progressbar"][aria-valuenow="42"]').waitFor();await page.locator('[data-usage-copy-update]').waitFor();
    assert.equal(await page.locator('[data-sidebar-usage-demo]').count(),1);assert.equal(await page.locator('[data-usage-copy-update]').count(),1);
    await page.evaluate(()=>tweak.start(testApi));await page.locator('[data-usage-copy-update]').waitFor();
    assert.equal(await page.locator('[data-sidebar-usage-demo]').count(),1);assert.equal(await page.locator('[data-usage-copy-update]').count(),1);
    await page.screenshot({path:path.join(output,'integrated.png')});await page.evaluate(()=>tweak.stop());
    assert.equal(await page.locator('[data-sidebar-usage-demo]').count(),0);assert.equal(await page.locator('[data-usage-copy-update]').count(),0);assert.deepEqual(errors,[]);
  }finally{await browser.close();}
});
