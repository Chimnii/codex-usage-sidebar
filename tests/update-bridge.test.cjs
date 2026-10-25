'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { createUpdateController, sanitizeStatus, INTERVAL, RETRY } = require('../tweak/update-bridge.cjs');
const NOW = Date.parse('2026-10-24T01:00:00Z');
function status(available = false) { return { schemaVersion: 1, status: available ? 'available' : 'current',
  checkedAt: new Date(NOW).toISOString(), installedPackage: 'OpenAI.Codex_26.1016.8120.0_x64__2p2nqsd0c76g0',
  installedVersion: '26.1016.8120.0', storeUpdateAvailable: available, copyUpdateRequired: false }; }
function setup(overrides = {}) {
  const timers = [], launches = [], writes = [];
  const child = new EventEmitter(); child.unref = () => {}; child.kill = () => { child.killed = true; };
  const controller = createUpdateController({ projectRoot: 'D:\\project spaces 한글', dataDir: 'D:\\cache',
    runningPackage: status().installedPackage }, {
    now: () => NOW, readFile: () => { throw Error('missing'); }, writeFile: (file, data) => writes.push(JSON.parse(data)),
    setTimeout: (fn, delay) => { const timer = { fn, delay }; timers.push(timer); return timer; }, clearTimeout: t => { if(t) t.cancelled=true; },
    query: async () => status(), spawn: (exe, args, options) => { launches.push({exe,args,options}); setImmediate(() => child.emit('spawn')); return child; }, ...overrides
  });
  return { controller, timers, launches, writes, child };
}
test('startup delay, six-hour checks, and no automatic install or helper launch', async () => {
  const x = setup(); assert.equal(x.timers[0].delay, 10000);
  await x.timers[0].fn(); assert.equal(x.controller.getState().status, 'current');
  assert.equal(x.timers.at(-1).delay, INTERVAL); assert.equal(x.launches.length, 0);
  assert.equal(x.writes.length, 1); x.controller.stop();
});
test('failed check keeps previous available status and retries in one hour', async () => {
  let fail = false; const x=setup({ query: async()=>{ if(fail)throw Error('offline'); return status(true); } });
  await x.controller.check(); fail=true; await x.controller.check();
  assert.equal(x.controller.getState().status,'available'); assert.equal(x.controller.getState().stale,true);
  assert.equal(x.timers.at(-1).delay,RETRY); assert.equal(x.writes.length,1); x.controller.stop();
});
test('first failure stays unknown/error, and cannot launch an updater', async()=>{
  const x=setup({ query:async()=>({schemaVersion:1,status:'error',error:'failed'}) });
  await x.controller.check(); assert.equal(x.controller.getState().status,'error');
  assert.equal((await x.controller.launch()).ok,false); assert.equal(x.launches.length,0);x.controller.stop();
});
test('button launches only the fixed wait-for-exit helper once; app stop keeps it alive',async()=>{
  const x=setup({query:async()=>status(true)});await x.controller.check();
  assert.equal((await x.controller.launch('untrusted argument')).ok,true);
  assert.equal((await x.controller.launch()).ok,true);assert.equal(x.launches.length,1);
  assert.ok(x.launches[0].args.some(a=>a.endsWith('Run-UsageUpdateHelper.ps1')));
  assert.ok(!x.launches[0].args.includes('--apply'));assert.equal(x.launches[0].options.detached,true);
  assert.equal(x.controller.getState().waiting,true);x.controller.stop();assert.notEqual(x.child.killed,true);
});
test('cancelling helper allows another attempt; spawn failures do not leave waiting state',async()=>{
  const x=setup({query:async()=>status(true)});await x.controller.check();await x.controller.launch();
  x.child.emit('exit',1);assert.equal(x.controller.getState().waiting,false);
  x.controller.stop();
  const y=setup({query:async()=>status(true),spawn:()=>{throw Error('failed');}});await y.controller.check();
  assert.equal((await y.controller.launch()).ok,false);assert.equal(y.controller.getState().waiting,false);y.controller.stop();
});
test('concurrent checks coalesce and stop discards late result',async()=>{
  let finish,calls=0;const x=setup({query:()=>{calls++;return new Promise(r=>finish=r);}});
  const pending=x.controller.check();const joined=x.controller.check();assert.equal(joined,pending);await Promise.resolve();assert.equal(calls,1);x.controller.stop();
  finish(status(true));await pending;assert.equal(x.writes.length,0);assert.equal(x.controller.getState().status,'unknown');
});
test('recent cache defers polling and sanitization rejects false/malformed availability',()=>{
  const x=setup({readFile:()=>JSON.stringify(status(true))});assert.equal(x.timers[0].delay,INTERVAL);
  assert.equal(x.controller.getState().status,'available');x.controller.stop();
  for(const bad of [{...status(),status:'available'}, {...status(),storeUpdateAvailable:'false'}, {...status(),installedPackage:'other'}]) {
    assert.throws(()=>sanitizeStatus(bad));
  }
});
test('repeated manual checks cancel the old timer and leave exactly one six-hour schedule', async()=>{
  const x=setup({readFile:()=>JSON.stringify(status())}); const old=x.timers[0];
  for(let i=0;i<5;i++) { const result=await x.controller.check(); assert.equal(result.ok,true); }
  assert.equal(x.timers.filter(t=>!t.cancelled).length,1);
  const writes=x.writes.length; await old.fn(); assert.equal(x.writes.length,writes);
  x.controller.stop(); assert.equal(x.timers.filter(t=>!t.cancelled).length,0);
});
test('failed manual request returns failure even when retained state says current or available',async()=>{
  for(const available of [false,true]) {
    const x=setup({readFile:()=>JSON.stringify(status(available)),query:async()=>{throw Error('private raw error');}});
    const result=await x.controller.check(); assert.equal(result.ok,false);assert.equal(result.reason,'check-failed');
    assert.equal(result.state.status,available?'available':'current');assert.equal(result.state.stale,true);
    assert.equal(result.state.checking,false);assert.equal(x.writes.length,0);
    assert.equal(x.timers.filter(t=>!t.cancelled).length,1);assert.equal(x.timers.at(-1).delay,RETRY);x.controller.stop();
  }
});
test('background and manual callers await the same fresh result',async()=>{
  let resolve;const x=setup({query:()=>new Promise(r=>resolve=r)});
  const first=x.controller.check(),second=x.controller.check(); assert.equal(first,second);
  assert.equal(x.controller.getState().checking,true);await Promise.resolve();resolve(status(true));
  assert.equal((await first).ok,true);assert.equal((await second).state.status,'available');
  assert.equal(x.timers.filter(t=>!t.cancelled).length,1);x.controller.stop();
});
test('stopping before the query microtask does not launch a process or schedule another query',async()=>{
  let calls=0;const x=setup({query:async()=>{calls++;return status();}});
  const pending=x.controller.check();x.controller.stop();assert.equal((await pending).reason,'stopped');
  assert.equal(calls,0);assert.equal(x.timers.filter(t=>!t.cancelled).length,0);
});

function processQuery() {
  const x=setup({query:undefined});
  x.child.stdout=new PassThrough();x.child.stderr=new PassThrough();
  return x;
}
test('real process adapter uses read-only Store query and parses its result',async()=>{
  const x=processQuery(), pending=x.controller.check();await Promise.resolve();
  assert.equal(x.launches.length,1);assert(x.launches[0].args.includes('-CheckOnly'));
  assert(!x.launches[0].args.includes('--apply'));assert.equal(x.launches[0].options.windowsHide,true);
  x.child.stdout.write('\uFEFF'+JSON.stringify(status()));x.child.emit('close',0);
  assert.equal((await pending).ok,true);assert.equal(x.timers.filter(t=>!t.cancelled).length,1);
  x.controller.stop();
});
test('query timeout settles without child close and ignores a late successful result',async()=>{
  const x=processQuery(), pending=x.controller.check();await Promise.resolve();
  x.timers.find(t=>t.delay===200000).fn();assert.equal((await pending).ok,false);
  assert.equal(x.child.killed,true);assert.equal(x.controller.getState().checking,false);
  x.child.stdout.write(JSON.stringify(status()));x.child.emit('close',0);x.child.emit('error',Error('late'));
  assert.equal(x.writes.length,0);assert.equal(x.timers.filter(t=>!t.cancelled).length,1);
  assert.equal(x.timers.at(-1).delay,RETRY);x.controller.stop();
});
test('stop aborts the owned Store checker without leaving a pending request or retry',async()=>{
  const x=processQuery(), pending=x.controller.check();await Promise.resolve();x.controller.stop();
  assert.equal((await pending).reason,'stopped');assert.equal(x.child.killed,true);
  assert.equal(x.timers.filter(t=>!t.cancelled).length,0);assert.equal(x.writes.length,0);
});
