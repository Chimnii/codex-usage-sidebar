'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { installWindowIdentity, displayTitle, DISPLAY_NAME, APP_ID } = require('../patcher/repatch/copy-bootstrap.cjs');

test('display titles preserve conversation names and do not duplicate the app suffix', () => {
  for (const title of ['', 'ChatGPT', 'Codex', 'ChatGPT with Usage']) assert.equal(displayTitle(title), DISPLAY_NAME);
  assert.equal(displayTitle('Planning'), 'Planning — ' + DISPLAY_NAME);
  assert.equal(displayTitle('Planning — ChatGPT'), 'Planning — ' + DISPLAY_NAME);
  assert.equal(displayTitle(displayTitle('Planning')), 'Planning — ' + DISPLAY_NAME);
});

test('window identity uses original themed icons, persists across title changes and leaves profile identity alone', async () => {
  const root = path.resolve('test-only', 'copy active');
  const app = new EventEmitter();
  app.whenReady = () => Promise.resolve();
  app.getName = () => 'Codex';
  app.setName = app.setPath = () => { throw Error('Profile identity must not change'); };
  const nativeTheme = new EventEmitter();
  nativeTheme.shouldUseDarkColorsForSystemIntegratedUI = true;
  nativeTheme.shouldUseDarkColors = false;
  const win = new EventEmitter();
  let title = 'ChatGPT', details, icon;
  win.getTitle = () => title;
  win.setTitle = value => { title = value; };
  win.setAppDetails = value => { details = value; };
  win.setIcon = value => { icon = value; };
  win.isDestroyed = () => false;
  const windows = [win];
  installWindowIdentity({ app, nativeTheme, BrowserWindow: { getAllWindows: () => windows } }, root, { existsFile: () => true });
  app.emit('browser-window-created', {}, win);
  await Promise.resolve();
  assert.equal(title, DISPLAY_NAME);
  assert.equal(win.listenerCount('page-title-updated'), 1);
  assert.deepEqual(details, { appId: APP_ID, relaunchCommand: '"' + path.join(root, 'app/ChatGPT.exe') + '"',
    relaunchDisplayName: DISPLAY_NAME, appIconPath: path.join(root, 'app/resources/chatgpt-app-dark.ico'), appIconIndex: 0 });
  assert.equal(icon, details.appIconPath);
  win.setTitle('Existing conversation');
  assert.equal(title, 'Existing conversation — ' + DISPLAY_NAME);
  let prevented = false;
  win.emit('page-title-updated', { preventDefault: () => { prevented = true; } }, 'Other conversation');
  assert.ok(prevented);
  assert.equal(title, 'Other conversation — ' + DISPLAY_NAME);
  nativeTheme.shouldUseDarkColorsForSystemIntegratedUI = false;
  nativeTheme.emit('updated');
  assert.equal(icon, path.join(root, 'app/resources/chatgpt-app-light.ico'));
  assert.equal(app.getName(), 'Codex');
  win.isDestroyed = () => true;
  win.setIcon = () => { throw Error('Destroyed window accessed'); };
  nativeTheme.emit('updated');
  app.emit('will-quit');
  assert.equal(nativeTheme.listenerCount('updated'), 0);
});

test('missing optional icon or window methods do not prevent startup', () => {
  const app = new EventEmitter(), win = new EventEmitter();
  let details;
  win.setAppDetails = value => { details = value; };
  installWindowIdentity({ app }, path.resolve('test-only'), { existsFile: () => false });
  app.emit('browser-window-created', {}, win);
  assert.equal(details.relaunchDisplayName, DISPLAY_NAME);
  assert.equal(details.appIconPath, undefined);
});

test('an unsupported shell-metadata setter does not stop window creation or icon updates', () => {
  const app = new EventEmitter(), warnings = [];
  let icon;
  const win = { setAppDetails: () => { throw Error('Not implemented'); }, setIcon: value => { icon = value; } };
  installWindowIdentity({ app }, path.resolve('test-only'), { existsFile: () => true, warn: (...args) => warnings.push(args) });
  assert.doesNotThrow(() => app.emit('browser-window-created', {}, win));
  assert.equal(warnings.length, 1);
  assert.ok(icon.endsWith('chatgpt-app-light.ico'));
});

test('Owl fallback is hidden, bounded and only repeated when the icon changes', async () => {
  const app = new EventEmitter(), theme = new EventEmitter(), calls = [];
  app.whenReady = () => Promise.resolve();
  theme.shouldUseDarkColorsForSystemIntegratedUI = true;
  const handle = Buffer.alloc(8); handle.writeBigUInt64LE(0x123456789n);
  const win = { getNativeWindowHandle: () => handle };
  const root = path.resolve('copy root'), projectRoot = path.resolve('project root');
  installWindowIdentity({ app, nativeTheme: theme, BrowserWindow: { getAllWindows: () => [win] } }, root, {
    projectRoot, existsFile: () => true,
    spawn: (command, args, options) => { calls.push({command,args,options}); const child=new EventEmitter(); child.unref=()=>{}; return child; }
  });
  app.emit('browser-window-created', {}, win);
  await Promise.resolve();
  theme.emit('updated');
  assert.equal(calls.length, 1);
  assert.ok(calls[0].args.includes('4886718345'));
  assert.ok(calls[0].args.includes(path.join(projectRoot, 'scripts/Set-UsageWindowIdentity.ps1')));
  assert.equal(calls[0].options.windowsHide, true);
  assert.equal(calls[0].options.timeout, 15000);
  theme.shouldUseDarkColorsForSystemIntegratedUI = false;
  theme.emit('updated');
  assert.equal(calls.length, 2);
});
