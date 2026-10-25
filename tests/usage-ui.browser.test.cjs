'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const source = fs.readFileSync(path.resolve(__dirname, '../tweak/index.js'), 'utf8');
const output = path.resolve(__dirname, '../.local/test-results/usage-ui'); fs.mkdirSync(output, { recursive: true });
const html = `<html lang="en"><style>body{margin:0;font:13px Arial;color:#252525;background:#fff}*{box-sizing:border-box}.sidebar{width:300px;height:700px;position:relative;background:#f6f6f6}.absolute{position:absolute}.inset-x-0{left:0;right:0}.bottom-0{bottom:0}.chat{position:absolute;left:350px;top:0;height:200px;overflow:hidden}</style><aside class="sidebar" data-sidebar-navigation-root><a href="#fixture">Fixture session</a><div class="absolute inset-x-0 bottom-0 z-20"><button>Profile</button></div></aside><main class="chat"></main></html>`;
async function setup(page) {
  await page.setContent(html);
  await page.addScriptTag({ content: `(()=>{const module={exports:{}};${source}\nwindow.tweak=module.exports;
    window.mode='ok';window.value=42;window.calls=0;window.refreshes=0;window.late=[];
    window.snapshot=()=>({version:1,usage:{language:'en'},providers:[{id:'codex',status:'ok',checkedAt:new Date().toISOString(),windows:[{id:'week',label:'Codex · 7일',usedPercent:window.value,resetsAt:new Date(Date.now()+3600000).toISOString()}]},{id:'antigravity',status:'disconnected',disabled:true,windows:[]},{id:'claude',status:'disconnected',disabled:true,windows:[]}]});
    const timer=window.setTimeout.bind(window);window.realTimer=timer;window.setTimeout=(fn,ms,...args)=>timer(fn,ms===5000?35:ms===15000?45:ms===10000?90:ms,...args);
    window.api={process:'renderer',ipc:{invoke:name=>{if(name==='usage:refresh'){refreshes++;return Promise.resolve({ok:true})}if(name!=='usage:get')return Promise.resolve(true);calls++;if(mode==='reject')return Promise.reject(Error('private failure'));if(mode==='hang')return new Promise(resolve=>late.push(resolve));return Promise.resolve(snapshot())}}};tweak.start(api);
  })();` });
  await page.waitForFunction(() => window.__sidebarUsageDemo?.getSnapshot().providers[0].status === 'ok');
}

test('IPC reject and hangs preserve numbers, show stale, recover polling, discard late replies and dispose', async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage(); const errors = []; page.on('pageerror', e => errors.push(e.message)); await setup(page);
    await page.evaluate(() => { mode = 'reject'; });
    await page.waitForFunction(() => __sidebarUsageDemo.getSnapshot().providers[0].status === 'stale');
    assert.equal(await page.locator('[aria-valuenow="42"]').count(), 1);
    assert.match(await page.locator('.sud-provider').getAttribute('title'), /Collector connection failed/);
    const before = await page.evaluate(() => { mode = 'hang'; return calls; });
    await page.waitForFunction(n => calls >= n + 3, before);
    assert.equal(await page.locator('[aria-valuenow="42"]').count(), 1);
    await page.evaluate(() => { mode = 'ok'; value = 55; });
    await page.locator('[aria-valuenow="55"]').waitFor();
    await page.evaluate(() => { const old=snapshot();old.providers[0].windows[0].usedPercent=99;late.splice(0).forEach(resolve=>resolve(old)); });
    await page.evaluate(() => new Promise(resolve => realTimer(resolve, 150)));
    assert.equal(await page.locator('[aria-valuenow="99"]').count(), 0);
    await page.evaluate(() => { mode='hang'; }); await page.waitForFunction(() => late.length > 0);
    const stoppedCalls = await page.evaluate(() => { tweak.stop(); late.splice(0).forEach(resolve=>resolve(snapshot())); return calls; });
    await page.evaluate(() => new Promise(resolve => realTimer(resolve, 150)));
    assert.equal(await page.evaluate(() => calls), stoppedCalls); assert.equal(await page.locator('[data-sidebar-usage-demo]').count(), 0);
    assert.deepEqual(errors, []);
  } finally { await browser.close(); }
});

test('compact preferences, disabled providers, light theme, narrow width, zoom and keyboard refresh', async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 850, height: 950 } }); await setup(page);
    await page.evaluate(() => {
      const original=snapshot;window.snapshot=()=>{const s=original();s.usage.windowOrder={codex:['five','week']};s.usage.hiddenWindows={codex:['review']};
      s.providers[0].windows.push({id:'five',label:'Codex · 5시간',usedPercent:9,resetsAt:new Date(Date.now()+3600000).toISOString()},{id:'review',label:'Code review · 7일',usedPercent:2,resetsAt:null});return s;};
    });
    await page.locator('[aria-valuenow="9"]').waitFor();
    assert.deepEqual(await page.locator('.sud-label').allTextContents(), ['GPT 5H', 'GPT 7D']);
    assert.equal(await page.locator('[data-provider="claude"]').count(), 0); assert.equal(await page.locator('[data-provider="antigravity"]').count(), 0);
    for (const [width, zoom] of [[300,1], [200,1], [200,1.25]]) {
      await page.evaluate(([w,z])=>{document.querySelector('.sidebar').style.width=w+'px';document.body.style.zoom=String(z);}, [width,zoom]);
      await page.evaluate(() => new Promise(resolve => realTimer(resolve, 80)));
      const sizes = await page.evaluate(() => {const panel=document.querySelector('[data-sidebar-usage-demo]').getBoundingClientRect();return [...document.querySelectorAll('.sud-row > *')].map(n=>{const r=n.getBoundingClientRect();return {left:r.left,right:r.right,width:r.width,panelLeft:panel.left,panelRight:panel.right}})});
      assert.ok(sizes.every(r => r.width > 0 && r.left >= r.panelLeft && r.right <= r.panelRight+1));
      await page.screenshot({ path: path.join(output, `light-${width}-${zoom}.png`) });
    }
    const refresh = page.getByRole('button', { name: 'Refresh usage' }); await refresh.focus(); await page.keyboard.press('Enter');
    await page.waitForFunction(() => refreshes >= 1); assert.equal(await refresh.isDisabled(), false);
    await page.evaluate(() => {
      const original=snapshot;window.snapshot=()=>{const s=original();s.diagnosticsEnabled=true;s.usage.hiddenProviders=['codex'];return s;};
      const invoke=api.ipc.invoke;api.ipc.invoke=(name,report)=>{if(name==='usage:ui-report')window.report=report;return invoke(name,report);};
    });
    await page.waitForFunction(() => window.report?.hiddenBySettings === true);
    assert.equal(await page.evaluate(() => report.visiblePanels), 0); assert.equal(await page.evaluate(() => report.mountedPanels), 1);
    await page.evaluate(() => tweak.stop());
  } finally { await browser.close(); }
});

test('chat stream mutations do not remeasure sidebar, while replacing a sidebar still remounts', async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage(); await setup(page);
    await page.evaluate(() => new Promise(resolve => realTimer(resolve, 350)));
    await page.evaluate(() => { const root=document.querySelector('.sidebar'),read=root.getBoundingClientRect.bind(root);window.measurements=0;window.traces=[];root.getBoundingClientRect=()=>{measurements++;traces.push(new Error().stack);return read()};
      for(let i=0;i<100;i++){const p=document.createElement('p');p.textContent='Synthetic stream';document.querySelector('.chat').append(p);} });
    await page.evaluate(() => new Promise(resolve => realTimer(resolve, 150)));
    assert.equal(await page.evaluate(() => measurements), 0, JSON.stringify(await page.evaluate(() => traces)));
    await page.evaluate(() => { const old=document.querySelector('.sidebar'), replacement=old.cloneNode(true);replacement.querySelector('[data-sidebar-usage-demo]').remove();old.replaceWith(replacement); });
    await page.waitForFunction(() => document.querySelector('.sidebar [data-sidebar-usage-demo]') !== null);
    assert.equal(await page.locator('[data-sidebar-usage-demo]').count(), 1); await page.evaluate(() => tweak.stop());
  } finally { await browser.close(); }
});
