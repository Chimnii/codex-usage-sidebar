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
    assert.equal(await page.locator('.sud-delay').count(), 0, 'a brief failure does not add a delay mark');
    assert.equal(await page.locator('.sud-notes').count(), 0, 'cached data does not add a status footer');
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

test('delayed providers get spinning circles after labels without moving usage columns', async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 600, height: 740 } }); await setup(page);
    await page.evaluate(() => {
      window.age = 120000;
      const fixedNow = Date.now(), s = snapshot();
      s.providers[1] = { id: 'antigravity', status: 'ok', checkedAt: new Date(fixedNow).toISOString(), windows: [{ id: 'gemini', label: 'Gemini Models · 7일', usedPercent: 9.5, resetsAt: new Date(fixedNow+86400000).toISOString() }] };
      s.providers[2] = { id: 'claude', status: 'stale', errorCode: 'TIMEOUT', windows: [
        { id: 'five', label: 'Claude · 5시간', usedPercent: 12, resetsAt: new Date(fixedNow+3600000).toISOString() },
        { id: 'week', label: 'Claude · 7일', usedPercent: 25, resetsAt: new Date(fixedNow+86400000).toISOString() }
      ] };
      window.snapshot = () => {
        Object.assign(s.providers[0], { status: age === 0 ? 'ok' : 'stale', checkedAt: new Date(fixedNow - age).toISOString(), errorCode: 'RPC_ERROR' });
        s.providers[2].status = s.providers[0].status;
        s.providers[2].checkedAt = s.providers[0].checkedAt;
        return s;
      };
    });
    await page.locator('[aria-valuenow="9.5"]').waitFor();
    const columns = () => page.locator('.sud-row').evaluateAll(rows => rows.map(row => {
      const result = {};
      for (const name of ['label', 'label-text', 'indicator-slot', 'track', 'value', 'reset']) {
        const r = row.querySelector('.sud-' + name).getBoundingClientRect();
        result[name] = { x: r.x, width: r.width };
      }
      return result;
    }));
    const assertAligned = (rows, context) => {
      assert.equal(rows.length, 4);
      for (const name of ['track', 'value', 'reset']) {
        assert.ok(rows.every(row => row[name].x === rows[0][name].x && row[name].width === rows[0][name].width), `${name} columns align across all providers ${context}`);
      }
    };
    for (const [width, zoom] of [[300, 1], [200, 1], [200, 1.25]]) {
      await page.evaluate(([w,z]) => { document.querySelector('.sidebar').style.width = w + 'px'; document.body.style.zoom = String(z); }, [width, zoom]);
      await page.evaluate(() => { age = 120000; });
      await page.waitForFunction(() => document.querySelectorAll('.sud-delay').length === 0);
      await page.locator('.sud-row').first().waitFor({ state: 'visible' });
      assert.equal(await page.locator('.sud-indicator-slot').count(), 4, 'every row reserves a marker slot before a delay');
      const before = await columns();
      const card = await page.locator('.sud-card').boundingBox();
      assertAligned(before, `before delay at ${width}px and zoom ${zoom}`);
      await page.evaluate(() => { age = 181000; });
      await page.waitForFunction(() => document.querySelectorAll('.sud-delay').length === 3);
      const delayed = await columns();
      assertAligned(delayed, `with mixed statuses at ${width}px and zoom ${zoom}`);
      assert.deepEqual(delayed, before, `adding spinners keeps column positions and widths at ${width}px and zoom ${zoom}`);
      assert.equal((await page.locator('.sud-card').boundingBox()).height, card.height);
      assert.equal(await page.locator('.sud-notes').count(), 0);
      assert.deepEqual(await page.locator('.sud-label').allTextContents(), ['GPT 7D', 'Gemini 7D', 'Claude 5H', 'Claude 7D']);
      assert.equal(await page.locator('[data-provider="antigravity"] .sud-delay').count(), 0);
      const marker = page.locator('.sud-delay').first();
      assert.equal(await marker.getAttribute('role'), 'img');
      assert.match(await marker.getAttribute('aria-label'), /GPT · Delayed\nLast successful check:.*\nUsage request failed/s);
      assert.equal(await marker.getAttribute('title'), await marker.getAttribute('aria-label'));
      assert.equal(await page.locator('.sud-label > .sud-indicator-slot').count(), 4, 'the reserved spinner slots belong to the labels');
      assert.equal(await page.locator('.sud-row > .sud-indicator-slot').count(), 0);
      const spinner = await marker.evaluate(async node => {
        const style = getComputedStyle(node), transform = style.transform;
        const result = { width: node.offsetWidth, height: node.offsetHeight, radius: style.borderRadius, borderWidth: parseFloat(style.borderTopWidth), borderStyle: style.borderTopStyle, hasArc: style.borderTopColor !== style.borderRightColor, animation: style.animationName, duration: style.animationDuration, iterations: style.animationIterationCount, state: style.animationPlayState };
        await new Promise(resolve => realTimer(resolve, 120));
        return { ...result, rotates: getComputedStyle(node).transform !== transform };
      });
      assert.equal(spinner.width, 8);
      assert.equal(spinner.height, 8);
      assert.equal(spinner.radius, '50%');
      assert.ok(spinner.borderWidth > 0 && spinner.hasArc, 'the spinner has a visible ring with a distinct leading arc');
      assert.equal(spinner.borderStyle, 'solid');
      assert.notEqual(spinner.animation, 'none');
      assert.equal(spinner.duration, '0.9s');
      assert.equal(spinner.iterations, 'infinite');
      assert.equal(spinner.state, 'running');
      assert.ok(spinner.rotates, 'the circle actually rotates over time');
      const inside = await page.locator('.sud-row').evaluateAll(rows => rows.every(row => {
        const r = row.getBoundingClientRect();
        return [...row.children].every(n => { const c = n.getBoundingClientRect(); return c.width > 0 && c.left >= r.left - 1 && c.right <= r.right + 1; });
      }));
      assert.ok(inside, `row children stay inside at ${width}px and zoom ${zoom}`);
      if (width === 300) {
        assert.ok(await page.locator('.sud-label-text').evaluateAll(nodes => nodes.every(n => n.scrollWidth <= n.clientWidth)), 'normal-width labels remain fully visible');
        for (const row of delayed) {
          assert.equal(row['indicator-slot'].x - row['label-text'].x - row['label-text'].width, 3, 'the spinner slot immediately follows its text with a 3px gap');
        }
        assert.notEqual(delayed[0]['indicator-slot'].x, delayed[1]['indicator-slot'].x, 'spinner positions follow text length rather than the gauge edge');
        await page.locator('[data-sidebar-usage-demo]').screenshot({ path: path.resolve(output, '../delay-marker-preview.png') });
        const darkTheme = await page.addStyleTag({ content: 'body{color:#ededed;background:#202020}.sidebar{background:#202020}' });
        await page.locator('[data-sidebar-usage-demo]').screenshot({ path: path.resolve(output, '../delay-marker-preview-dark.png') });
        await darkTheme.evaluate(node => node.remove());
        await page.emulateMedia({ reducedMotion: 'reduce' });
        assert.equal(await marker.evaluate(node => getComputedStyle(node).animationName), 'none', 'reduced motion keeps a static delayed circle');
        assert.deepEqual(await columns(), delayed, 'reduced motion preserves the usage columns');
        await page.emulateMedia({ reducedMotion: 'no-preference' });
      }
      await page.evaluate(() => { age = 0; });
      await page.waitForFunction(() => document.querySelectorAll('.sud-delay').length === 0);
      const recovered = await columns();
      assertAligned(recovered, `after recovery at ${width}px and zoom ${zoom}`);
      assert.deepEqual(recovered, before, `removing spinners keeps column positions and widths at ${width}px and zoom ${zoom}`);
      assert.equal(await page.locator('.sud-indicator-slot').count(), 4, 'marker slots remain after recovery');
    }
    assert.equal(await page.locator('[aria-valuenow="42"]').count(), 1);
    await page.evaluate(() => tweak.stop());
  } finally { await browser.close(); }
});

test('unchanged stale snapshots gain their mark at the threshold without waiting for the next minute', async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage(); await setup(page);
    await page.evaluate(() => {
      const fixed = snapshot();
      window.clock = Date.parse('2026-10-27T00:10:29.999Z');
      Date.now = () => clock;
      Object.assign(fixed.providers[0], { status: 'stale', checkedAt: '2026-10-27T00:07:30.000Z', errorCode: 'RPC_ERROR' });
      window.snapshot = () => fixed;
    });
    await page.waitForFunction(() => __sidebarUsageDemo.getSnapshot().providers[0].status === 'stale');
    assert.equal(await page.locator('.sud-delay').count(), 0);
    await page.evaluate(() => { clock++; });
    await page.locator('.sud-delay').waitFor();
    assert.equal(await page.locator('.sud-notes').count(), 0);
    await page.evaluate(() => tweak.stop());
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
