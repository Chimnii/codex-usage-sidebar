'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {auditFile,listPublicFiles}=require('../scripts/package-release.cjs');
const {collect}=require('../collector/collector.cjs');
const {sanitizeSnapshot,mergeSnapshots,initialSnapshot}=require('../tweak/main-bridge.cjs');
test('release selection excludes local state and application binaries',()=>{
  for(const file of listPublicFiles())auditFile(file,fs.readFileSync(path.join(__dirname,'..',file),'utf8'));
  assert.throws(()=>auditFile('.local/settings.json','{}'));
  assert.throws(()=>auditFile('app.exe','data'));
  assert.throws(()=>auditFile('README.md',process.env.USERPROFILE||process.cwd()));
});
test('GPT-only collection never invokes either optional provider and clears disabled history',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'sidebar-optional-'));let calls=0;
  const c={codexHome:dir,userProfile:dir,appData:dir,localAppData:dir,workDir:dir,cachePath:path.join(dir,'cache.json'),codexPath:path.join(dir,'codex.exe'),agyPath:null,claudeCredentialsPath:null};
  try {
    const result=await collect(c,{runProcessImpl:async(exe)=>{calls++;assert.equal(exe,c.codexPath);return[{id:'codex:weekly',label:'7일',usedPercent:12,resetsAt:null}]},claudeRequestImpl:()=>{throw Error('Unexpected request')}});
    assert.equal(calls,1);assert.equal(result.providers[1].status,'disconnected');assert.equal(result.providers[2].status,'disconnected');
    const previous=initialSnapshot();previous.providers.find(p=>p.id==='antigravity').windows=[{id:'old',label:'old',usedPercent:30,resetsAt:null}];
    const merged=mergeSnapshots(previous,sanitizeSnapshot(result));assert.deepEqual(merged.providers.find(p=>p.id==='antigravity').windows,[]);
  } finally {fs.rmSync(dir,{recursive:true,force:true});}
});
