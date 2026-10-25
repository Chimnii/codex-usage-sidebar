'use strict';

// Local compatibility correction for ChatGPT Layer v1.1.4 (MIT, Copyright 2026 Bennett).
// Upstream: https://github.com/LightHaru/chatgpt-layer/tree/v1.1.4
// Source equivalents: runtime-paths.ts and tweak-main-host.ts.
// Respect CODEX_HOME and disable the unused MCP sync into the shared profile.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');

function plainPath(value) {
  const full = path.resolve(value);
  let cursor = path.parse(full).root;
  for (const part of full.slice(cursor.length).split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, part);
    if (fs.lstatSync(cursor).isSymbolicLink()) throw new Error(`Reparse/symlink path is unsupported: ${cursor}`);
  }
  return full;
}

function prepare(runtimeRoot) {
  const root = plainPath(runtimeRoot);
  const variants = [
    {
      name: 'main.js',
      edits: [
        {
          before: 'var CODEX_CONFIG_FILE = (0, import_node_path6.join)((0, import_node_os2.homedir)(), ".codex", "config.toml");',
          after: 'var CODEX_CONFIG_FILE = (0, import_node_path6.join)(process.env.CODEX_HOME || (0, import_node_path6.join)((0, import_node_os2.homedir)(), ".codex"), "config.toml");',
        },
        {
          before: '  syncMcpServersFromEnabledTweaks();',
          after: '  // Usage Sidebar: MCP sync disabled; preserve the shared user configuration.',
        },
      ],
    },
    {
      name: 'runtime-paths.js',
      edits: [{
        before: 'exports.CODEX_CONFIG_FILE = (0, node_path_1.join)((0, node_os_1.homedir)(), ".codex", "config.toml");',
        after: 'exports.CODEX_CONFIG_FILE = (0, node_path_1.join)(process.env.CODEX_HOME || (0, node_path_1.join)((0, node_os_1.homedir)(), ".codex"), "config.toml");',
      }],
    },
  ];
  const sha = value => crypto.createHash('sha256').update(value).digest('hex');
  return variants.map(({ name, edits }) => {
    const file = plainPath(path.join(root, name));
    const original = fs.readFileSync(file, 'utf8');
    if (name === 'main.js' && !original.includes('var CODEX_PLUSPLUS_VERSION = "1.1.4";')) {
      throw new Error('Expected ChatGPT Layer 1.1.4 runtime.');
    }
    let updated = original;
    for (const { before, after } of edits) {
      const oldCount = updated.split(before).length - 1;
      const fixedCount = updated.split(after).length - 1;
      if (!((oldCount === 1 && fixedCount === 0) || (oldCount === 0 && fixedCount === 1))) {
        throw new Error(`Unsupported or ambiguous Layer compatibility hook in ${name}; no files changed.`);
      }
      if (oldCount) updated = updated.replace(before, after);
    }
    new vm.Script(updated, { filename: file });
    return { file, name, original, updated, changed: original !== updated, beforeSha256: sha(original), afterSha256: sha(updated) };
  });
}

function main(args = process.argv.slice(2)) {
  if (Number(process.versions.node.split('.')[0]) < 20) throw new Error('Node.js 20 or newer is required.');
  if (args.length < 2 || args.length > 3 || args[0] !== '--runtime-root' || (args[2] && args[2] !== '--check')) {
    throw new Error('Usage: node patch-layer-runtime.cjs --runtime-root <directory> [--check]');
  }
  const plan = prepare(args[1]); // Validate both files before writing either.
  if (args[2] !== '--check') {
    for (const item of plan) if (item.changed) fs.writeFileSync(item.file, item.updated, 'utf8');
  }
  return {
    status: args[2] === '--check' ? 'validated' : 'prepared',
    layerVersion: '1.1.4', correction: 'CODEX_HOME-aware config path; MCP synchronization disabled',
    files: plan.map(({ name, changed, beforeSha256, afterSha256 }) => ({ name, changed, beforeSha256, afterSha256 })),
  };
}

if (require.main === module) {
  try { process.stdout.write(JSON.stringify(main()) + '\n'); }
  catch (error) { process.stderr.write(error.message + '\n'); process.exitCode = 1; }
}
module.exports = { prepare, main };
