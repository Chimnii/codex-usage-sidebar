'use strict';

// Disposable project, app pair, and profile directories only. No auth data is copied.
const fs = require('node:fs');
const path = require('node:path');
const { createFixture, write, workspace, defaultAsarModule } = require('./repatch-fixture.cjs');

function copyTree(source, destination) {
  fs.mkdirSync(destination, { recursive: true });
  for (const item of fs.readdirSync(source, { withFileTypes: true })) {
    if (item.isSymbolicLink()) throw new Error('Fixture input must not be a link.');
    const from = path.join(source, item.name), to = path.join(destination, item.name);
    if (item.isDirectory()) copyTree(from, to);
    else fs.copyFileSync(from, to);
  }
}

async function createUsageFixture(root, userSid) {
  const fixture = await createFixture(root);
  const projectRoot = path.join(root, 'project 한글 spaces');
  fs.mkdirSync(projectRoot);
  for (const directory of ['patcher', 'scripts', 'tweak', 'collector']) {
    copyTree(path.join(workspace, directory), path.join(projectRoot, directory));
  }
  copyTree(fixture.layerSourceRoot, path.join(projectRoot, '.local/layer-source'));
  const runtime = path.join(projectRoot, '.local/layer-runtime');
  write(runtime, 'main.js', 'var CODEX_PLUSPLUS_VERSION = "1.1.4";\nvar CODEX_CONFIG_FILE = (0, import_node_path6.join)((0, import_node_os2.homedir)(), ".codex", "config.toml");\n');
  write(runtime, 'runtime-paths.js', 'exports.CODEX_CONFIG_FILE = (0, node_path_1.join)((0, node_os_1.homedir)(), ".codex", "config.toml");\n');
  write(runtime, 'LICENSE', 'Synthetic runtime fixture. No application code.\n');
  write(runtime, 'preload.js', 'module.exports = {};\n');
  write(runtime, 'renderer.js', 'module.exports = {};\n');
  const asar = path.join(projectRoot, '.local/dependencies/node_modules/@electron/asar');
  write(asar, 'package.json', JSON.stringify({ name: '@electron/asar', version: '3.4.1', main: 'index.js' }));
  write(asar, 'index.js', `module.exports = require(${JSON.stringify(defaultAsarModule)});\n`);
  write(fixture.appDir, 'resources/codex.exe', 'Synthetic fixture; never execute.\n');
  const profile = path.join(root, 'synthetic profile');
  const settings = {
    schemaVersion: 1, packageName: 'OpenAI.Codex', packageFamilyName: 'OpenAI.Codex_2p2nqsd0c76g0',
    nodePath: process.execPath, agyPath: write(profile, 'agy.exe', 'Synthetic fixture; never execute.\n'),
    codexHome: path.join(profile, '.codex'), userProfile: profile,
    localAppData: path.join(profile, 'AppData/Local'), appData: path.join(profile, 'AppData/Roaming'), userSid,
  };
  for (const key of ['codexHome', 'localAppData', 'appData']) fs.mkdirSync(settings[key], { recursive: true });
  write(settings.codexHome, 'config.toml', '# Synthetic user configuration: preserve byte-for-byte.\n');
  const settingsPath = write(projectRoot, '.local/settings.json', JSON.stringify(settings, null, 2));
  const result = { ...fixture, projectRoot, settingsPath, settings, runtimeSource: runtime };
  write(root, 'usage-fixture-info.json', JSON.stringify(result, null, 2));
  return result;
}

if (require.main === module) {
  createUsageFixture(path.resolve(process.argv[2]), process.argv[3]).then(f => console.log(JSON.stringify(f)))
    .catch(error => { console.error(error.stack); process.exitCode = 1; });
}
module.exports = { createUsageFixture };
