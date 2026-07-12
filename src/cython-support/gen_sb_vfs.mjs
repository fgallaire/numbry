#!/usr/bin/env node
// Build the data file loader/test-seaborn.html loads:
//   build/sb_vfs.js — seaborn's source tree (pure Python, zero C) as a
//                     Brython VFS. Everything else the page needs (numpy,
//                     pandas, matplotlib layers + assets) comes from the
//                     numpy/pandas/mpl VFS blobs it also loads.
//
// Usage: gen_sb_vfs.mjs <seaborn-pkg-dir>
//   <seaborn-pkg-dir>  the seaborn/ package directory (seaborn-src/seaborn)
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
const require = createRequire(import.meta.url);
const fs = require('fs'), path = require('path');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const [SBPKG] = process.argv.slice(2);
if (!SBPKG) {
  console.error('usage: gen_sb_vfs.mjs <seaborn-pkg-dir>');
  process.exit(1);
}
const OUT = path.join(ROOT, 'build', 'sb_vfs.js');

const scripts = { $timestamp: Date.now() };
let n = 0, bytes = 0;
function walk(dir, rootParent, skip) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (skip && skip.includes(e.name)) continue;
      walk(full, rootParent, skip); continue;
    }
    if (!e.name.endsWith('.py')) continue;
    const rel = path.relative(rootParent, full);
    const isInit = e.name === '__init__.py';
    let mod = rel.replace(/\.py$/, '').replace(/[\/]/g, '.');
    if (isInit) mod = mod.replace(/\.__init__$/, '');
    const src = fs.readFileSync(full, 'utf8');
    scripts[mod] = ['.py', src, [], isInit];
    n++; bytes += src.length;
  }
}
walk(SBPKG, path.dirname(SBPKG), ['tests']);

const blob = ';(function(){\nif(typeof __BRYTHON__==="undefined"){throw new Error("load brython.js first")}\n__BRYTHON__.update_VFS(' + JSON.stringify(scripts) + ');\n})();\n';
fs.writeFileSync(OUT, blob);
console.log('seaborn VFS: ' + n + ' modules, ' + (bytes / 1048576).toFixed(1) + ' MB src, blob ' + (blob.length / 1048576).toFixed(1) + ' MB -> ' + OUT);
