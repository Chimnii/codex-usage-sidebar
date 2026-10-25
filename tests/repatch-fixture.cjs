'use strict';

// Synthetic inputs only. No installed application or user profile is read here.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const workspace = path.resolve(__dirname, '..');
const defaultAsarModule = process.env.CODEX_USAGE_TEST_ASAR_MODULE || path.dirname(require.resolve('@electron/asar/package.json'));
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function write(root, relative, bytes) {
  const file = path.join(root, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return file;
}

function makePe(integrityHash, options = {}) {
  // One named INTEGRITY resource in a valid x64 PE32+ resource directory.
  // This is deliberately not executable program code and is never launched.
  const rawOffset = options.rawOffset || 0x200;
  const payload = Buffer.from(JSON.stringify([{ file: 'resources\\app.asar', alg: 'SHA256', value: integrityHash }]));
  const payloadOffset = 0xd0;
  const resourceSize = payloadOffset + payload.length;
  const rawSize = Math.ceil(resourceSize / 0x200) * 0x200;
  const pe = Buffer.alloc(rawOffset + rawSize + 37, 0);
  pe.write('MZ'); pe.writeUInt32LE(0x80, 0x3c);
  pe.write('PE\0\0', 0x80, 'binary');
  pe.writeUInt16LE(0x8664, 0x84); pe.writeUInt16LE(1, 0x86);
  pe.writeUInt16LE(240, 0x94); pe.writeUInt16LE(0x22, 0x96);
  const opt = 0x98;
  pe.writeUInt16LE(0x20b, opt); pe.writeUInt32LE(0x1000, opt + 32);
  pe.writeUInt32LE(0x200, opt + 36); pe.writeUInt32LE(0x2000, opt + 56);
  pe.writeUInt32LE(rawOffset, opt + 60); pe.writeUInt16LE(3, opt + 68);
  pe.writeUInt32LE(16, opt + 108);
  pe.writeUInt32LE(0x1000, opt + 112 + 16);
  pe.writeUInt32LE(resourceSize, opt + 112 + 20);
  const section = opt + 240;
  pe.write('.rsrc', section); pe.writeUInt32LE(resourceSize, section + 8);
  pe.writeUInt32LE(0x1000, section + 12); pe.writeUInt32LE(rawSize, section + 16);
  pe.writeUInt32LE(rawOffset, section + 20); pe.writeUInt32LE(0x40000040, section + 36);
  const r = rawOffset;
  pe.writeUInt16LE(1, r + 12);
  pe.writeUInt32LE(0x80000080, r + 16); pe.writeUInt32LE(0x80000020, r + 20);
  pe.writeUInt16LE(1, r + 32 + 12);
  pe.writeUInt32LE(0x800000a0, r + 48); pe.writeUInt32LE(0x80000040, r + 52);
  pe.writeUInt16LE(1, r + 64 + 14);
  pe.writeUInt32LE(0x409, r + 80); pe.writeUInt32LE(96, r + 84);
  pe.writeUInt32LE(0x1000 + payloadOffset, r + 96); pe.writeUInt32LE(payload.length, r + 100);
  pe.writeUInt16LE('INTEGRITY'.length, r + 128);
  pe.write('INTEGRITY', r + 130, 'utf16le');
  pe.writeUInt16LE('ELECTRONASAR'.length, r + 160);
  pe.write('ELECTRONASAR', r + 162, 'utf16le');
  payload.copy(pe, r + payloadOffset);
  pe.write('untouched overlay data', rawOffset + rawSize, 'ascii');
  return pe;
}

function hookSource(name = 'windowServices') {
  return `const ${name}=createServices({buildFlavor:"stable",allowDevtools:true,allowDebugMenu:false,allowInspectElement:true,globalState:{},getGlobalStateForHost(){},desktopRoot:"root",preloadPath:"preload",repoRoot:"repo",canHideLastLocalWindowToTray:false,disposables:[]});`;
}

async function createFixture(root, options = {}) {
  if (fs.existsSync(root)) throw new Error(`Fixture already exists: ${root}`);
  fs.mkdirSync(root, { recursive: true });
  const asarModule = options.asarModule || defaultAsarModule;
  const asar = require(asarModule);
  const appDir = path.join(root, 'clean app');
  const sourceDir = path.join(root, 'archive input');
  const layerRoot = path.join(root, 'layer runtime');
  const layerSourceRoot = path.join(root, 'layer source');
  const mainName = options.mainName || '.vite/build/main-fixtureA.js';
  const mainSource = options.mainSource === undefined
    ? `'use strict';function createServices(options){return options;}\n${hookSource()}\nmodule.exports={versionNote:${JSON.stringify(options.versionNote || 'unrelated application data v1')}};\n`
    : options.mainSource;
  const packageJson = { name: 'synthetic-codex-app', version: options.version || '1.2.3', main: mainName, customPreserved: { value: 'retain this' }, ...(options.packageOverrides || {}) };
  write(sourceDir, 'package.json', JSON.stringify(packageJson, null, 2) + '\n');
  write(sourceDir, mainName, mainSource);
  write(sourceDir, 'assets/unrelated.bin', Buffer.from([0, 1, 254, 255, 17, 0, 99]));
  write(sourceDir, 'native/example.node', Buffer.from('synthetic unpacked native payload\0\xff', 'binary'));
  for (const [relative, bytes] of Object.entries(options.extraEntries || {})) write(sourceDir, relative, bytes);
  const asarPath = path.join(appDir, 'resources/app.asar');
  fs.mkdirSync(path.dirname(asarPath), { recursive: true });
  await asar.createPackageWithOptions(sourceDir, asarPath, { unpack: '**/*.node', globOptions: { dot: true } });
  const raw = asar.getRawHeader(asarPath);
  const headerHash = sha256(raw.headerString);
  write(appDir, 'ChatGPT.exe', makePe(options.exeHash || headerHash, { rawOffset: options.rawOffset }));
  write(appDir, 'untouched-app-file.txt', 'unrelated external content\n');
  write(layerSourceRoot, 'package.json', JSON.stringify({ name: 'codex-plusplus', version: '1.1.4' }));
  write(layerSourceRoot, 'packages/loader/loader.cjs', `'use strict';\nconst pkg=require('./package.json');\nconst meta=pkg.__codexpp;\nconst originalMain=meta.originalMain;\nconst userRoot=meta.userRoot;\nrequire(originalMain);\n`);
  write(layerRoot, 'runtime/main.js', `'use strict';module.exports={start(){}};\n`);
  write(layerRoot, 'runtime/preload.js', `'use strict';\n`);
  write(layerRoot, 'runtime/renderer.js', `'use strict';\n`);
  write(layerRoot, 'package.json', JSON.stringify({ name: 'synthetic-layer-runtime', version: '1.1.4' }));
  return { root, appDir, asarPath, layerRoot, layerSourceRoot, asarModule, mainName, mainSource, headerHash, sourceDir };
}

function treeFingerprint(root) {
  if (!fs.existsSync(root)) return 'absent';
  const result = [];
  function visit(dir, rel = '') {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const name = rel ? `${rel}/${entry.name}` : entry.name;
      const full = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) result.push(`L:${name}:${fs.readlinkSync(full)}`);
      else if (entry.isDirectory()) { result.push(`D:${name}`); visit(full, name); }
      else result.push(`F:${name}:${sha256(fs.readFileSync(full))}`);
    }
  }
  visit(root);
  return result.join('\n');
}

module.exports = { workspace, defaultAsarModule, createFixture, makePe, hookSource, sha256, treeFingerprint, write };

if (require.main === module) {
  createFixture(path.resolve(process.argv[2])).then(f => {
    fs.writeFileSync(path.join(f.root, 'fixture-info.json'), JSON.stringify(f, null, 2));
    console.log(JSON.stringify(f));
  }).catch(error => { console.error(error.stack); process.exitCode = 1; });
}
