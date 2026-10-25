'use strict';
const acorn = require('./vendor/acorn/package/dist/acorn.js');
const vm = require('node:vm');
const MARKER = '__codexpp_window_services__';
const FINGERPRINTS = ['allowDevtools', 'allowDebugMenu', 'allowInspectElement', 'globalState', 'getGlobalStateForHost', 'desktopRoot', 'preloadPath', 'repoRoot', 'canHideLastLocalWindowToTray', 'canHideLastWindowToTray', 'disposables'];

function propertyName(prop) {
  if (prop.type !== 'Property' || prop.computed || prop.method || prop.kind !== 'init') return null;
  return prop.key.type === 'Identifier' ? prop.key.name : typeof prop.key.value === 'string' ? prop.key.value : null;
}

function properties(object) {
  const result = new Map();
  for (const prop of object.properties) {
    const name = propertyName(prop);
    if (name) {
      if (result.has(name)) return null;
      result.set(name, prop.value);
    }
  }
  return result;
}

function staticString(node) {
  if (node?.type === 'Literal' && typeof node.value === 'string') return node.value;
  if (node?.type === 'TemplateLiteral' && !node.expressions.length) return node.quasis[0].value.cooked;
  return null;
}

function findHooks(source) {
  if (source.includes(MARKER)) throw Error('Already patched window-services marker');
  const ast = acorn.parse(source, { ecmaVersion: 'latest', sourceType: 'script', allowHashBang: true });
  const factories = [], lifecycle = [], dependencies = new Set();
  const stack = [{ node: ast, parent: null }];
  while (stack.length) {
    const { node, parent } = stack.pop();
    if (node.type === 'CallExpression' && node.callee.type === 'Identifier' && node.callee.name === 'require' && node.arguments.length === 1) {
      const dep = staticString(node.arguments[0]); if (dep?.startsWith('.')) dependencies.add(dep);
    }
    if (node.type === 'ImportExpression') { const dep = staticString(node.source); if (dep?.startsWith('.')) dependencies.add(dep); }
    const directStatement = parent && ['Program', 'BlockStatement'].includes(parent.type);
    if (node.type === 'VariableDeclaration' && directStatement) {
      for (const declaration of node.declarations) {
        const call = declaration.init;
        if (declaration.id.type !== 'Identifier' || call?.type !== 'CallExpression' || call.optional || call.callee.type !== 'Identifier' || call.arguments.length !== 1 || call.arguments[0].type !== 'ObjectExpression') continue;
        const props = properties(call.arguments[0]); if (!props) continue;
        const fingerprints = FINGERPRINTS.filter(key => props.has(key));
        if (props.has('buildFlavor') && fingerprints.length >= 5) factories.push({ strategy: 'service-factory-fingerprint', serviceVar: declaration.id.name, insertionOffset: node.end, fingerprints: ['buildFlavor', ...fingerprints] });
      }
    }
    if (node.type === 'ExpressionStatement' && directStatement) {
      const call = node.expression;
      if (call.type === 'CallExpression' && !call.optional && call.callee.type === 'Identifier' && call.arguments.length === 1 && call.arguments[0].type === 'ObjectExpression') {
        const props = properties(call.arguments[0]);
        const windows = props?.get('windows');
        if (windows?.type === 'Identifier') {
          const serviceVar = windows.name;
          const refs = ['ensureHostWindow', 'hotkeyWindowLifecycleManager', 'globalDictationLifecycleManager'].filter(key => {
            const value = props.get(key);
            return value?.type === 'MemberExpression' && !value.computed && value.object.type === 'Identifier' && value.object.name === serviceVar && value.property.type === 'Identifier' && value.property.name === key;
          });
          const other = ['flushAndDisposeContexts', 'appEvent', 'errorReporter'].filter(key => props.has(key));
          if (refs.length >= 2 && other.length >= 2) lifecycle.push({ strategy: 'lifecycle-registration-fingerprint', serviceVar, insertionOffset: node.end, fingerprints: ['windows', ...refs, ...other] });
        }
      }
    }
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) { for (const child of value) if (child && typeof child.type === 'string') stack.push({ node: child, parent: node }); }
      else if (value && typeof value.type === 'string') stack.push({ node: value, parent: node });
    }
  }
  return { factories, lifecycle, dependencies: [...dependencies] };
}

function patchHook(source, hook, filename) {
  const insertion = `;globalThis.${MARKER}=${hook.serviceVar};`;
  const patched = source.slice(0, hook.insertionOffset) + insertion + source.slice(hook.insertionOffset);
  acorn.parse(patched, { ecmaVersion: 'latest', sourceType: 'script', allowHashBang: true });
  new vm.Script(patched, { filename });
  return patched;
}

module.exports = { findHooks, patchHook, MARKER, parserVersion: acorn.version };
