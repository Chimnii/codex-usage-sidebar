'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { initialize, originalAppRunning, APP_ID } = require('../patcher/repatch/copy-bootstrap.cjs');
const original = 'C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.1021.3705.0_x64__2p2nqsd0c76g0\\app';
const config = { sourceAppDir: original };

test('original detection accepts the installed source and newer Store versions, not unrelated copies', () => {
  const detected = paths => originalAppRunning(config, { listExecutablePaths: () => paths });
  assert.equal(detected([original + '\\ChatGPT.exe']), true);
  assert.equal(detected([original.replace('26.1021.3705.0', '26.1026.1.0') + '\\ChatGPT.exe']), true);
  assert.equal(detected(['D:\\work\\project\\.local\\copy\\active\\app\\ChatGPT.exe']), false);
  assert.equal(detected(['C:\\Other\\ChatGPT.exe', 'C:\\WindowsApps\\OpenAI.Other_1.2.3.4_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe', null]), false);
  assert.equal(detected([]), false);
});

test('process discovery is bounded and hidden; lookup failure does not prevent normal startup', () => {
  const warnings = [];
  assert.equal(originalAppRunning(config, { process: { env: {SystemRoot:'C:\\Windows'} }, execFileSync: (file, args, options) => {
    assert.match(file, /powershell\.exe$/i);
    assert.equal(options.windowsHide, true);
    assert.equal(options.timeout, 3000);
    assert.equal(options.maxBuffer, 65536);
    assert(args.includes('-NonInteractive'));
    return JSON.stringify([original+'\\ChatGPT.exe']);
  } }), true);
  assert.equal(originalAppRunning(config, { listExecutablePaths: () => { throw Error('timeout'); }, warn: (...args) => warnings.push(args) }), false);
  assert.equal(warnings.length, 1);
});

for (const locale of ['en-US', 'ko-KR']) test(`direct EXE warns in ${locale} before changing profiles or loading Layer`, () => {
  const root = path.resolve('fixture-project/.local/copy/active');
  const env = { CODEX_HOME: 'untouched', NODE_OPTIONS: 'untouched' }, calls = [];
  const result = initialize(path.join(root, 'app/resources/app.asar'), {
    process: { platform:'win32', env }, listExecutablePaths: () => [original+'\\ChatGPT.exe'],
    readFile: () => JSON.stringify({ ...config, schemaVersion:1, appUserModelId:APP_ID, packageFullName:'fixture' }),
    require: name => {
      assert.equal(name, 'electron');
      return { app: { getLocale:()=>locale, exit: code=>calls.push(['exit',code]) },
        dialog: { showErrorBox: (...args)=>calls.push(['message',...args]) } };
    }
  });
  assert.equal(result.reason, 'original-running');
  assert.equal(result.blocked, true);
  assert.deepEqual(env, {CODEX_HOME:'untouched',NODE_OPTIONS:'untouched'});
  assert.match(calls[0][2], locale === 'ko-KR' ? /원본 ChatGPT가 실행 중/ : /original ChatGPT app is running/);
  assert.deepEqual(calls[1], ['exit',0]);
});
