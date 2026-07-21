#!/usr/bin/env node
// Build build/sympy_vfs.js — sympy + mpmath (both 100% pure Python) as a
// Brython VFS. sympy is torch's symbolic-shapes dependency
// (torch.fx.experimental.symbolic_shapes, torch.utils._sympy) and a
// first-class scientific library for Jubryter notebooks; loading the real
// thing replaces any eager stubbing. The tests/benchmarks subtrees are
// excluded (a third of the source; nothing imports them at runtime).
//
// Usage: gen_sympy_vfs.mjs <src-dir containing sympy/ and mpmath/> <out-file>
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
const require = createRequire(import.meta.url);
const fs = require('fs'), path = require('path');
const SRC = process.argv[2];
const OUT = process.argv[3];
if (!SRC || !OUT) {
  console.error('usage: gen_sympy_vfs.mjs <src-dir> <out-file>'); process.exit(1);
}

let scripts = { $timestamp: Date.now() };
let n = 0, bytes = 0;

const SKIP_DIRS = new Set(['tests', 'benchmarks', '__pycache__']);

function add(mod, src, isInit) {
  scripts[mod] = ['.py', src, [], !!isInit];
  n++; bytes += src.length;
}

function walk(dir, prefix) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      walk(path.join(dir, e.name), prefix + '.' + e.name);
      continue;
    }
    if (!e.name.endsWith('.py')) continue;
    const mod = e.name === '__init__.py'
      ? prefix : prefix + '.' + e.name.slice(0, -3);
    add(mod, fs.readFileSync(path.join(dir, e.name), 'utf8'),
        e.name === '__init__.py');
  }
}

walk(path.join(SRC, 'sympy'), 'sympy');
walk(path.join(SRC, 'mpmath'), 'mpmath');

const blob = ';(function(){\nif(typeof __BRYTHON__==="undefined"){throw new Error("load brython.js first")}\n__BRYTHON__.update_VFS(' + JSON.stringify(scripts) + ');\n})();\n';
fs.writeFileSync(OUT, blob);
console.log('sympy VFS: ' + n + ' modules, ' + (bytes / 1048576).toFixed(1) + ' MB src, blob ' + (blob.length / 1048576).toFixed(1) + ' MB -> ' + OUT);
