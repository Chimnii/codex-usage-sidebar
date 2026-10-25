'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const archiveTools = require('./asar-edit.cjs');
const { findHooks, patchHook, MARKER, parserVersion } = require('./javascript-hook.cjs');
const { locateIntegrity, patchIntegrity } = require('./pe-integrity.cjs');
const { sha, readArchive, readMember, validateRelative, rebuild, hashFile } = archiveTools;
const ENGINE_VERSION = '1.0.0';
const LOADER = 'codex-plusplus-loader.cjs';

function safePath(value, expected) {
  if (typeof value !== 'string' || !value.trim()) throw Error('A path argument is required');
  const result = path.resolve(value);
  if (process.platform === 'win32') {
    if (result.startsWith('\\\\') || /[<>"|?*]/.test(result) || result.slice(3).includes(':')) throw Error(`Unsupported Windows path: ${result}`);
    for (const part of result.slice(path.parse(result).root.length).split(path.sep)) {
      if (/[. ]$/.test(part) || /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part)) throw Error(`Unsafe Windows path component: ${part}`);
    }
  }
  let cursor = result;
  while (true) {
    if (fs.existsSync(cursor)) {
      const info = fs.lstatSync(cursor);
      if (info.isSymbolicLink()) throw Error(`Reparse/symlink path is not supported: ${cursor}`);
    }
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  if (expected) {
    const info = fs.statSync(result);
    if (expected === 'file' ? !info.isFile() : !info.isDirectory()) throw Error(`Expected ${expected}: ${result}`);
  }
  return result;
}

function isWithin(a, b) {
  const rel = path.relative(b, a);
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel));
}

function resolveAsar(options) {
  let resolved;
  if (options.asarModule) resolved = require.resolve(safePath(options.asarModule));
  else {
    try { resolved = require.resolve('@electron/asar', { paths: [options.layerSourceRoot, options.layerRoot, process.cwd(), __dirname] }); }
    catch { throw Error('Local @electron/asar 3.4.1 required; supply --asar-module PACKAGE_DIRECTORY (no automatic download)'); }
  }
  safePath(resolved, 'file');
  let root = path.dirname(resolved), manifest;
  while (root !== path.dirname(root)) {
    const candidate = path.join(root, 'package.json');
    if (fs.existsSync(candidate)) {
      const p = JSON.parse(fs.readFileSync(candidate, 'utf8'));
      if (p.name === '@electron/asar') { manifest = p; break; }
    }
    root = path.dirname(root);
  }
  if (!manifest || manifest.version !== '3.4.1') throw Error('Unsupported ASAR dependency: engine 1.0.0 requires @electron/asar 3.4.1');
  const asar = require(resolved);
  if (typeof asar.getRawHeader !== 'function') throw Error('ASAR dependency API missing');
  return { asar, metadata: { name: manifest.name, version: manifest.version, modulePath: resolved, entrySha256: sha(fs.readFileSync(resolved)) } };
}

async function preflight(input) {
  if (Number(process.versions.node.split('.')[0]) < 20) throw Error('Node.js 20 or newer required');
  const options = {
    ...input,
    originalAppDir: safePath(input.originalAppDir, 'directory'),
    layerRoot: safePath(input.layerRoot, 'directory'),
    layerSourceRoot: safePath(input.layerSourceRoot, 'directory'),
  };
  if (input.outputAppDir) {
    options.outputAppDir = safePath(input.outputAppDir);
    if (fs.existsSync(options.outputAppDir)) throw Error('OutputAppDir must not exist; a new prepared pair is required');
    for (const root of [options.originalAppDir, options.layerRoot, options.layerSourceRoot]) {
      if (isWithin(options.outputAppDir, root) || isWithin(root, options.outputAppDir)) throw Error('Output and source/runtime paths must not overlap');
    }
    safePath(path.dirname(options.outputAppDir), 'directory');
  }
  if (isWithin(options.layerRoot, options.originalAppDir)) throw Error('Layer runtime must live outside app directory');
  const asarPath = safePath(path.join(options.originalAppDir, 'resources', 'app.asar'), 'file');
  const exePath = safePath(path.join(options.originalAppDir, 'ChatGPT.exe'), 'file');
  const runtimeMain = safePath(path.join(options.layerRoot, 'runtime', 'main.js'), 'file');
  const sourcePackage = safePath(path.join(options.layerSourceRoot, 'package.json'), 'file');
  const layerPackage = JSON.parse(fs.readFileSync(sourcePackage, 'utf8'));
  if (layerPackage.version !== '1.1.4') throw Error('Engine adapter supports supplied Layer source version 1.1.4 only');
  const loaderCandidates = ['assets/loader.cjs', 'packages/loader/loader.cjs', 'packages/installer/assets/loader.cjs'];
  const loaderRelative = loaderCandidates.find(p => fs.existsSync(path.join(options.layerSourceRoot, p)));
  if (!loaderRelative) throw Error('Layer 1.1.4 loader.cjs asset missing');
  const loaderPath = safePath(path.join(options.layerSourceRoot, loaderRelative), 'file');
  const loader = fs.readFileSync(loaderPath);
  const loaderText = loader.toString('utf8');
  for (const marker of ['__codexpp', 'originalMain', 'userRoot']) if (!loaderText.includes(marker)) throw Error(`Unsupported Layer loader: missing ${marker}`);
  new vm.Script(loaderText, { filename: loaderPath });
  const dependency = resolveAsar(options);
  const archive = readArchive(asarPath, dependency.asar);
  const pkg = JSON.parse(readMember(archive, 'package.json').toString('utf8'));
  if (Object.prototype.hasOwnProperty.call(pkg, '__codexpp') || pkg.main === LOADER || archive.files.some(e => e.path === LOADER)) throw Error('Input app is already Layer patched; use a clean updated app or verified backup');
  const originalMain = validateRelative(pkg.main);
  if (!/\.(?:c?js)$/.test(originalMain)) throw Error('Unsupported package.main type');
  readMember(archive, originalMain);
  const factories = [], lifecycle = [], scanned = [], visited = new Set(), pending = [originalMain];
  const members = new Map(archive.files.map(e => [e.path, e]));
  while (pending.length) {
    const p = pending.pop();
    if (visited.has(p)) continue;
    visited.add(p);
    const entry = members.get(p);
    if (!entry || !/\.(?:c?js)$/.test(p) || entry.node.unpacked || entry.node.link || p.split('/').includes('node_modules') || p.startsWith('webview/')) continue;
    const source = readMember(archive, p).toString('utf8');
    if (source.includes(MARKER)) throw Error(`Input contains existing Layer window hook: ${p}`);
    const found = findHooks(source);
    scanned.push(p);
    for (const hook of found.factories) factories.push({ ...hook, path: p, source });
    for (const hook of found.lifecycle) lifecycle.push({ ...hook, path: p, source });
    for (const dep of found.dependencies) {
      const relative = path.posix.normalize(path.posix.join(path.posix.dirname(p), dep));
      validateRelative(relative);
      const resolved = [relative, `${relative}.js`, `${relative}.cjs`, `${relative}/index.js`].filter(name => members.has(name));
      if (resolved.length > 1) throw Error(`Ambiguous local module dependency: ${p} -> ${dep}`);
      if (resolved.length === 1) pending.push(resolved[0]);
    }
  }
  const candidates = factories.length ? factories : lifecycle;
  if (candidates.length !== 1) throw Error(`Window-services hook missing or ambiguous (${candidates.length} eligible ${factories.length ? 'factory' : 'lifecycle'} hooks)`);
  if (factories.length && lifecycle.some(h => h.path !== factories[0].path || h.serviceVar !== factories[0].serviceVar)) throw Error('Factory and lifecycle window-services evidence conflicts');
  const hook = candidates[0], patchedMain = Buffer.from(patchHook(hook.source, hook, hook.path));
  const exe = fs.readFileSync(exePath);
  const pe = locateIntegrity(exe, archive.headerHash);
  const originalFiles = [
    { path: 'resources/app.asar', original: { sha256: await hashFile(asarPath), length: archive.size } },
    { path: 'ChatGPT.exe', original: { sha256: sha(exe), length: exe.length } },
  ];
  const patchedPackage = { ...pkg, main: LOADER, __codexpp: { originalMain, userRoot: options.layerRoot, loader: LOADER } };
  const replacements = new Map([
    ['package.json', Buffer.from(`${JSON.stringify(patchedPackage, null, 2)}\n`)],
    [hook.path, patchedMain],
    [LOADER, loader],
  ]);
  if (options.portableCopy === true || options.portableCopy === 'true') {
    // The managed copy can move between staging, active and previous without
    // embedding the staging path or altering the original Store install adapter.
    const bootstrap = fs.readFileSync(path.join(__dirname, 'copy-bootstrap.cjs'));
    new vm.Script(bootstrap.toString('utf8'));
    patchedPackage.__codexpp.userRoot = '../../../layer-data';
    replacements.set('package.json', Buffer.from(`${JSON.stringify(patchedPackage, null, 2)}\n`));
    replacements.set('usage-copy-bootstrap.cjs', bootstrap);
    replacements.set(LOADER, Buffer.concat([Buffer.from("require('./usage-copy-bootstrap.cjs').initialize(__dirname);\n"), loader]));
  } else if (options.portableCopy) throw Error('Invalid portable-copy option');
  const report = {
    schemaVersion: 1, engineVersion: ENGINE_VERSION, status: 'compatible',
    originalAppDir: options.originalAppDir, layerRoot: options.layerRoot,
    appVersion: pkg.version || null, originalMain,
    layer: { version: layerPackage.version, sourceRoot: options.layerSourceRoot, loaderPath, loaderSha256: sha(loader), runtimeMainSha256: await hashFile(runtimeMain) },
    dependency: dependency.metadata, parser: { name: 'acorn', version: parserVersion, vendored: true },
    hooks: { windowServices: { path: hook.path, strategy: hook.strategy, serviceVar: hook.serviceVar, fingerprints: hook.fingerprints, insertionOffset: hook.insertionOffset }, candidatesScanned: scanned, exeIntegrity: pe },
    archive: { originalHeaderSha256: archive.headerHash, originalPayloadLength: archive.payloadLength, packedFiles: archive.files.filter(e => !e.node.unpacked && !e.node.link).length, unpackedFiles: archive.files.filter(e => e.node.unpacked).length, mode: 'preserve-original-payload-and-append-changed-members' },
    changedArchiveMembers: [...replacements.keys()], files: originalFiles,
    guarantees: { inputFilesReadOnly: true, unpackedMetadataPreserved: true, electronFusesUnchanged: true },
    limitations: ['Prepared output contains only the ASAR/EXE pair; target must retain its matching original resources/app.asar.unpacked tree.', 'Modified EXE publisher signature is not valid; package signing/Windows Store installation are outside this engine.', 'Structural matching supports the implemented Layer 1.1.4 adapter; unknown or ambiguous structures stop preparation.'],
  };
  return { options, dependency, archive, exe, pe, replacements, report, asarPath, exePath };
}

async function inspect(input) { return (await preflight(input)).report; }

async function prepare(input) {
  if (!input.outputAppDir) throw Error('outputAppDir is required for prepare');
  const context = await preflight(input);
  const { options, dependency, archive, exe, pe, replacements, report, asarPath, exePath } = context;
  // Recheck original bytes immediately before output construction. Nothing in
  // this engine writes into the input or runtime paths.
  if (await hashFile(asarPath) !== report.files[0].original.sha256 || await hashFile(exePath) !== report.files[1].original.sha256) throw Error('Input pair changed during preflight');
  const output = options.outputAppDir, outputAsar = path.join(output, 'resources', 'app.asar'), outputExe = path.join(output, 'ChatGPT.exe');
  fs.mkdirSync(output);
  fs.mkdirSync(path.join(output, 'resources'));
  try {
    const built = await rebuild(archive, replacements, outputAsar);
    const newExe = patchIntegrity(exe, pe, built.headerHash);
    fs.writeFileSync(outputExe, newExe, { flag: 'wx' });
    const check = readArchive(outputAsar, dependency.asar);
    const checkMembers = new Map(check.files.map(e => [e.path, e]));
    if (check.headerHash !== built.headerHash) throw Error('Generated ASAR header verification failed');
    for (const [name, value] of replacements) if (!readMember(check, name).equals(value)) throw Error(`Generated member verification failed: ${name}`);
    const changed = new Set(replacements.keys());
    for (const entry of archive.files) {
      if (changed.has(entry.path)) continue;
      const outputEntry = checkMembers.get(entry.path);
      if (!outputEntry || JSON.stringify(outputEntry.node) !== JSON.stringify(entry.node)) throw Error(`Unrelated ASAR metadata changed: ${entry.path}`);
    }
    const oldPayloadHash = archive.payloadLength ? await hashFile(asarPath, archive.dataOffset, archive.size - 1) : sha(Buffer.alloc(0));
    const newPayloadHash = archive.payloadLength ? await hashFile(outputAsar, check.dataOffset, check.dataOffset + archive.payloadLength - 1) : sha(Buffer.alloc(0));
    if (oldPayloadHash !== newPayloadHash) throw Error('Original ASAR payload preservation failed');
    if (await hashFile(asarPath) !== report.files[0].original.sha256 || await hashFile(exePath) !== report.files[1].original.sha256) throw Error('Input pair changed during build; generated output cannot be applied');
    report.status = 'prepared'; report.outputAppDir = output;
    report.archive.patchedHeaderSha256 = built.headerHash;
    report.archive.originalPayloadSha256 = oldPayloadHash;
    report.archive.originalPayloadPreserved = true;
    report.files[0].patched = { sha256: await hashFile(outputAsar), length: fs.statSync(outputAsar).size };
    report.files[1].patched = { sha256: sha(newExe), length: newExe.length };
    fs.writeFileSync(path.join(output, 'repatch-report.json'), `${JSON.stringify(report, null, 2)}\n`, { flag: 'wx' });
    return report;
  } catch (error) {
    // Retain failed artifacts for diagnosis. No recursive removal, no input
    // rollback is necessary because inputs have never been opened for write.
    try { fs.writeFileSync(path.join(output, 'FAILED.txt'), `Preparation failed; do not apply this directory.\n${error.message}\n`, { flag: 'wx' }); } catch {}
    throw error;
  }
}

module.exports = { inspect, prepare, safePath, isWithin, ENGINE_VERSION };
