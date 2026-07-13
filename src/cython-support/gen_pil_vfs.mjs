#!/usr/bin/env node
// Build build/pil_vfs.js — Pillow's PIL/ Python package (pure Python, ~95
// files) as a Brython VFS. The three compiled modules (_imaging, _imagingmath,
// _imagingmorph) live in the nppil wasm; everything else the page imports
// (io, struct, warnings…) is brython_stdlib.
//
// Usage: gen_pil_vfs.mjs <PIL-pkg-dir>   (Pillow-src/src/PIL)
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
const require = createRequire(import.meta.url);
const fs = require('fs'), path = require('path');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const [PILPKG] = process.argv.slice(2);
if (!PILPKG) {
  console.error('usage: gen_pil_vfs.mjs <PIL-pkg-dir>');
  process.exit(1);
}
const OUT = path.join(ROOT, 'build', 'pil_vfs.js');

const scripts = { $timestamp: Date.now() };
let n = 0, bytes = 0;
function walk(dir, rootParent) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { walk(full, rootParent); continue; }
    if (!e.name.endsWith('.py')) continue;
    const rel = path.relative(rootParent, full);
    const isInit = e.name === '__init__.py';
    let mod = rel.replace(/\.py$/, '').replace(/[\/]/g, '.');
    if (isInit) mod = mod.replace(/\.__init__$/, '');
    let src = fs.readFileSync(full, 'utf8');
    if (mod === 'PIL._typing') {
      // CapsuleType (types, 3.13) and Buffer (collections.abc, 3.12) are
      // version-gated imports; Brython reports 3.14 but lacks both symbols.
      // Used only in annotations (PEP 563 strings, never evaluated), so the
      // module's own else-branch fallbacks are behaviourally identical —
      // force them to avoid an ImportError that would sink `import PIL.Image`.
      src = src
        .replace('    from types import CapsuleType', '    CapsuleType = object')
        .replace('    from collections.abc import Buffer', '    Buffer = Any');
    }
    scripts[mod] = ['.py', src, [], isInit];
    n++; bytes += src.length;
  }
}
walk(PILPKG, path.dirname(PILPKG));

const blob = ';(function(){\nif(typeof __BRYTHON__==="undefined"){throw new Error("load brython.js first")}\n__BRYTHON__.update_VFS(' + JSON.stringify(scripts) + ');\n})();\n';
fs.writeFileSync(OUT, blob);
console.log('PIL VFS: ' + n + ' modules, ' + (bytes / 1048576).toFixed(1) + ' MB src, blob ' + (blob.length / 1048576).toFixed(1) + ' MB -> ' + OUT);
