'use strict';

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { createFixture, hookSource, sha256, treeFingerprint, workspace } = require('./repatch-fixture.cjs');
const toolDir = path.join(__dirname, '../patcher');
const cli = path.join(toolDir, 'repatch/cli.cjs');
const fixtureRoot = path.join(workspace, '.local/test-work/repatch-fixture-tests', `node-${new Date().toISOString().replace(/[:.]/g, '-')}-${process.pid}`);
fs.mkdirSync(fixtureRoot, { recursive: true });
const results = [];
let counter = 0;

async function fixture(name, options) {
  return createFixture(path.join(fixtureRoot, `${String(++counter).padStart(2, '0')}-${name}`), options);
}
function invoke(f, mode, additions = []) {
  const args = [cli, mode, '--original-app-dir', f.appDir, '--layer-root', f.layerRoot, '--layer-source-root', f.layerSourceRoot, '--asar-module', f.asarModule, ...additions];
  return spawnSync(process.execPath, args, { encoding: 'utf8', windowsHide: true, timeout: 120000 });
}
function success(result) {
  assert.equal(result.status, 0, `Command failed: ${result.error || result.stderr || result.stdout}`);
  return JSON.parse(result.stdout);
}
function failure(result) {
  assert.notEqual(result.status, 0, 'Command unexpectedly succeeded');
  assert(!result.error, `Process infrastructure failed: ${result.error}`);
  return (result.stderr || result.stdout).trim();
}
function prepare(f, out = path.join(f.root, 'prepared app')) {
  return { result: success(invoke(f, 'prepare', ['--output-app-dir', out])), out };
}
function member(asar, archive, name) { return asar.extractFile(archive, path.normalize(name)); }
function archiveEntries(asar, file) {
  asar.uncache(file);
  const entries = new Map();
  function visit(node, prefix = '') {
    for (const [name, value] of Object.entries(node.files || {})) {
      const relative = prefix ? `${prefix}/${name}` : name;
      if (value.files) visit(value, relative);
      else entries.set(relative, value);
    }
  }
  visit(asar.getRawHeader(file).header);
  return entries;
}
async function test(name, fn) {
  const began = Date.now();
  try {
    const detail = await fn();
    results.push({ name, status: 'passed', durationMs: Date.now() - began, detail });
    console.log(`PASS ${name}`);
  } catch (error) {
    results.push({ name, status: 'failed', durationMs: Date.now() - began, error: error.stack });
    console.log(`FAIL ${name}: ${error.message}`);
  }
}

(async () => {
  await test('inspect performs no filesystem writes', async () => {
    const f = await fixture('inspect');
    const before = treeFingerprint(f.root);
    const report = success(invoke(f, 'inspect'));
    assert.equal(treeFingerprint(f.root), before);
    return { report, fixture: f.root };
  });

  await test('prepare changes only package entry, one main hook, loader, and EXE header hash', async () => {
    const f = await fixture('minimal-patch');
    const sourceBefore = treeFingerprint(f.appDir);
    const runtimeBefore = treeFingerprint(f.layerRoot);
    const { result, out } = prepare(f);
    const asar = require(f.asarModule);
    const patchedArchive = path.join(out, 'resources/app.asar');
    const before = archiveEntries(asar, f.asarPath);
    const after = archiveEntries(asar, patchedArchive);
    const pkg = JSON.parse(member(asar, patchedArchive, 'package.json'));
    assert.equal(pkg.__codexpp.originalMain, f.mainName);
    assert.equal(path.resolve(pkg.__codexpp.userRoot), path.resolve(f.layerRoot));
    assert.equal(pkg.main, 'codex-plusplus-loader.cjs');
    assert.deepEqual(pkg.customPreserved, { value: 'retain this' });
    assert.equal(after.size, before.size + 1);
    for (const [name, entry] of before) {
      if (['package.json', f.mainName].includes(name)) continue;
      assert.deepEqual(after.get(name), entry, `Unrelated metadata changed: ${name}`);
      if (!entry.unpacked && !entry.link) assert.deepEqual(member(asar, patchedArchive, name), member(asar, f.asarPath, name));
    }
    const main = member(asar, patchedArchive, f.mainName).toString();
    assert.equal(main.split('globalThis.__codexpp_window_services__=').length - 1, 1);
    assert(main.includes('unrelated application data v1'));
    assert.equal(main.replace(/;globalThis\.__codexpp_window_services__=[A-Za-z_$][\w$]*;/, ''), f.mainSource);
    const oldExe = fs.readFileSync(path.join(f.appDir, 'ChatGPT.exe'));
    const newExe = fs.readFileSync(path.join(out, 'ChatGPT.exe'));
    const oldHashOffset = oldExe.indexOf(Buffer.from(f.headerHash));
    const newHeaderHash = sha256(asar.getRawHeader(patchedArchive).headerString);
    assert(oldHashOffset >= 0);
    assert.equal(newExe.length, oldExe.length);
    assert.deepEqual(newExe.subarray(0, oldHashOffset), oldExe.subarray(0, oldHashOffset));
    assert.deepEqual(newExe.subarray(oldHashOffset + 64), oldExe.subarray(oldHashOffset + 64));
    assert.equal(newExe.subarray(oldHashOffset, oldHashOffset + 64).toString(), newHeaderHash);
    assert.equal(treeFingerprint(f.appDir), sourceBefore);
    assert.equal(treeFingerprint(f.layerRoot), runtimeBefore);
    return { report: result, originalUnpackedEntryPreserved: true, exeHashOffset: oldHashOffset };
  });

  await test('managed copy preserves the payload and unrelated members without repeated payload hashing', async () => {
    const f = await fixture('managed-copy');
    const before = treeFingerprint(f.appDir);
    assert.match(failure(invoke(f, 'prepare', ['--output-app-dir', path.join(f.root, 'rejected'), '--managed-copy', 'true'])), /portable/i);
    const out = path.join(f.root, 'managed');
    const report = success(invoke(f, 'prepare', ['--output-app-dir', out, '--portable-copy', 'true', '--managed-copy', 'true']));
    assert.equal(report.archive.payloadVerification, 'stream-copy-and-member-validation');
    assert.equal(report.archive.originalPayloadSha256, undefined);
    const asar = require(f.asarModule);
    const archive = path.join(out, 'resources/app.asar');
    const entries = archiveEntries(asar, f.asarPath), patched = archiveEntries(asar, archive);
    for (const [name, entry] of entries) {
      if (['package.json', f.mainName].includes(name)) continue;
      assert.deepEqual(patched.get(name), entry);
      if (!entry.unpacked && !entry.link) assert.deepEqual(member(asar, archive, name), member(asar, f.asarPath, name));
    }
    const { readArchive } = require('../patcher/repatch/asar-edit.cjs');
    const sourceInfo = readArchive(f.asarPath, asar), targetInfo = readArchive(archive, asar);
    const sourceBytes = fs.readFileSync(f.asarPath), targetBytes = fs.readFileSync(archive);
    assert.deepEqual(targetBytes.subarray(targetInfo.dataOffset, targetInfo.dataOffset + sourceBytes.length - sourceInfo.dataOffset), sourceBytes.subarray(sourceInfo.dataOffset));
    assert.equal(treeFingerprint(f.appDir), before);
  });

  await test('renamed main, changed app version/content, shifted PE resource still repatch', async () => {
    const f = await fixture('minor-update', { mainName: '.vite/build/main-newHashB.js', version: '1.2.4', versionNote: 'new unrelated application data v2', rawOffset: 0x800 });
    const { out } = prepare(f);
    const asar = require(f.asarModule);
    const patchedArchive = path.join(out, 'resources/app.asar');
    const pkg = JSON.parse(member(asar, patchedArchive, 'package.json'));
    assert.equal(pkg.version, '1.2.4');
    assert.equal(pkg.__codexpp.originalMain, f.mainName);
    assert(member(asar, patchedArchive, f.mainName).toString().includes('new unrelated application data v2'));
    const exe = fs.readFileSync(path.join(out, 'ChatGPT.exe'));
    const newHash = sha256(asar.getRawHeader(patchedArchive).headerString);
    assert(exe.indexOf(Buffer.from(newHash)) > 0x800);
  });

  await test('comment and string hook lookalikes are ignored', async () => {
    const source = `// ${hookSource('commentDecoy')}\nconst text=${JSON.stringify(hookSource('stringDecoy'))};\nfunction createServices(o){return o;}\n${hookSource()}\nmodule.exports=text;`;
    const f = await fixture('lexer-decoys', { mainSource: source });
    const { out } = prepare(f);
    const patched = member(require(f.asarModule), path.join(out, 'resources/app.asar'), f.mainName).toString();
    assert.equal(patched.replace(/;globalThis\.__codexpp_window_services__=[A-Za-z_$][\w$]*;/, ''), source);
    assert(patched.includes('globalThis.__codexpp_window_services__=windowServices;'));
  });

  await test('separate bootstrap and renamed minified service identifiers are supported', async () => {
    const source = `function q(o){return o;}\n${hookSource('$a').replace('createServices', 'q')}\nmodule.exports=$a;`;
    const f = await fixture('bootstrap-minified', { mainSource: source, mainName: '.vite/build/main-renamedHash.js', packageOverrides: { main: 'early-bootstrap.js' }, extraEntries: { 'early-bootstrap.js': `require('./.vite/build/main-renamedHash.js');` } });
    const { out } = prepare(f);
    const asar = require(f.asarModule);
    const archive = path.join(out, 'resources/app.asar');
    assert.equal(JSON.parse(member(asar, archive, 'package.json')).__codexpp.originalMain, 'early-bootstrap.js');
    assert(member(asar, archive, f.mainName).toString().includes('globalThis.__codexpp_window_services__=$a;'));
    assert.equal(member(asar, archive, 'early-bootstrap.js').toString(), `require('./.vite/build/main-renamedHash.js');`);
  });

  await test('lifecycle fingerprint fallback captures its actual service variable', async () => {
    const source = `const x={};function register(o){return o;}register({windows:x,ensureHostWindow:x.ensureHostWindow,hotkeyWindowLifecycleManager:x.hotkeyWindowLifecycleManager,globalDictationLifecycleManager:x.globalDictationLifecycleManager,flushAndDisposeContexts:null,appEvent:null,errorReporter:null});module.exports=x;`;
    const f = await fixture('lifecycle-fallback', { mainSource: source });
    const { out } = prepare(f);
    const changed = member(require(f.asarModule), path.join(out, 'resources/app.asar'), f.mainName).toString();
    assert(changed.includes('globalThis.__codexpp_window_services__=x;'));
    assert.equal(changed.replace(';globalThis.__codexpp_window_services__=x;', ''), source);
  });

  await test('unreferenced JavaScript hook lookalike is not selected', async () => {
    const f = await fixture('orphan-hook', { extraEntries: { '.vite/build/orphan.js': `function createServices(o){return o;}\n${hookSource('orphan')}` } });
    const { out } = prepare(f);
    const asar = require(f.asarModule);
    const archive = path.join(out, 'resources/app.asar');
    assert(member(asar, archive, f.mainName).toString().includes('globalThis.__codexpp_window_services__=windowServices;'));
    assert.equal(member(asar, archive, '.vite/build/orphan.js').toString(), `function createServices(o){return o;}\n${hookSource('orphan')}`);
  });

  for (const [name, options] of [
    ['absent-hook', { mainSource: `'use strict';module.exports={ordinary:true};` }],
    ['ambiguous-hook', { mainSource: `function createServices(o){return o;}\n${hookSource('first')}\n${hookSource('second')}` }],
    ['ambiguous-hook-in-other-file', { mainSource: `require('./other.js');function createServices(o){return o;}\n${hookSource()}`, extraEntries: { '.vite/build/other.js': `function createServices(o){return o;}\n${hookSource('other')}` } }],
    ['lazy-arrow-assignment', { mainSource: `let s;const start=()=>${hookSource('s').replace('const s=', 's=')}` }],
    ['return-lifecycle', { mainSource: `function start(){const x={};return register({windows:x,ensureHostWindow:x.ensureHostWindow,hotkeyWindowLifecycleManager:x.hotkeyWindowLifecycleManager,flushAndDisposeContexts:null,appEvent:null});}` }],
    ['regex-hook-decoy', { mainSource: `if(false)/;let x=f({buildFlavor:0,allowDevtools:1,allowDebugMenu:1,allowInspectElement:1,globalState:1,desktopRoot:1,preloadPath:1});z/.test("");` }],
    ['stale-exe-integrity', { exeHash: 'a'.repeat(64) }],
    ['already-layer-metadata', { packageOverrides: { __codexpp: { originalMain: '.vite/build/main-fixtureA.js' } } }],
    ['existing-hook-marker', { mainSource: `function createServices(o){return o;}\n${hookSource()}\nglobalThis.__codexpp_window_services__=windowServices;` }],
    ['existing-loader-file', { extraEntries: { 'codex-plusplus-loader.cjs': 'module.exports={};' } }],
  ]) {
    await test(`${name} is rejected without writes`, async () => {
      const f = await fixture(name, options);
      const before = treeFingerprint(f.root);
      const reason = failure(invoke(f, 'prepare', ['--output-app-dir', path.join(f.root, 'never created')]));
      assert.equal(treeFingerprint(f.root), before);
      return reason;
    });
  }

  await test('prepare rejects source/output overlap', async () => {
    const f = await fixture('overlap');
    const before = treeFingerprint(f.root);
    const reason = failure(invoke(f, 'prepare', ['--output-app-dir', path.join(f.appDir, 'nested-output')]));
    assert.equal(treeFingerprint(f.root), before);
    return reason;
  });

  await test('prepare refuses an existing destination without writes', async () => {
    const f = await fixture('existing-output');
    const out = path.join(f.root, 'existing-output');
    fs.mkdirSync(out);
    fs.writeFileSync(path.join(out, 'do-not-touch'), 'existing user content');
    const before = treeFingerprint(f.root);
    const reason = failure(invoke(f, 'prepare', ['--output-app-dir', out]));
    assert.equal(treeFingerprint(f.root), before);
    return reason;
  });

  await test('source junction is rejected without writes', async () => {
    const f = await fixture('junction');
    const alias = path.join(f.root, 'junction app');
    fs.symlinkSync(f.appDir, alias, 'junction');
    const before = treeFingerprint(f.root);
    const reason = failure(invoke({ ...f, appDir: alias }, 'inspect'));
    assert.equal(treeFingerprint(f.root), before);
    return reason;
  });

  await test('invalid executable format is rejected without writes', async () => {
    const f = await fixture('non-pe');
    fs.writeFileSync(path.join(f.appDir, 'ChatGPT.exe'), 'not a PE file');
    const before = treeFingerprint(f.root);
    const reason = failure(invoke(f, 'prepare', ['--output-app-dir', path.join(f.root, 'never created')]));
    assert.equal(treeFingerprint(f.root), before);
    return reason;
  });

  await test('ambiguous PE integrity resource is rejected without writes', async () => {
    const f = await fixture('duplicate-pe-resource');
    const exePath = path.join(f.appDir, 'ChatGPT.exe');
    const exe = fs.readFileSync(exePath);
    exe.writeUInt16LE(2, 0x200 + 12);
    exe.copy(exe, 0x200 + 24, 0x200 + 16, 0x200 + 24);
    fs.writeFileSync(exePath, exe);
    const before = treeFingerprint(f.root);
    const reason = failure(invoke(f, 'prepare', ['--output-app-dir', path.join(f.root, 'never created')]));
    assert.equal(treeFingerprint(f.root), before);
    return reason;
  });

  await test('matching hash outside integrity resource stays unchanged', async () => {
    const f = await fixture('unrelated-digest');
    const exePath = path.join(f.appDir, 'ChatGPT.exe');
    fs.appendFileSync(exePath, Buffer.from(f.headerHash));
    const before = fs.readFileSync(exePath);
    const { out } = prepare(f);
    const after = fs.readFileSync(path.join(out, 'ChatGPT.exe'));
    assert.equal(after.subarray(-64).toString(), f.headerHash);
    assert.equal(after.length, before.length);
  });

  const evidence = { schemaVersion: 1, createdAt: new Date().toISOString(), nodeVersion: process.version, fixtureRoot, passed: results.filter(r => r.status === 'passed').length, failed: results.filter(r => r.status === 'failed').length, tests: results };
  const evidencePath = path.join(workspace, '.local/test-results/repatch-engine-test-results.json');
  fs.mkdirSync(path.dirname(evidencePath), { recursive: true });
  fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2) + '\n');
  console.log(JSON.stringify({ evidencePath, passed: evidence.passed, failed: evidence.failed }));
  process.exitCode = evidence.failed ? 1 : 0;
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
