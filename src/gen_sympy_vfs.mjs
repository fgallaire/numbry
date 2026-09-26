#!/usr/bin/env node
// Build build/sympy_vfs.js — sympy + mpmath (both 100% pure Python) as a
// Brython VFS. sympy is torch's symbolic-shapes dependency
// (torch.fx.experimental.symbolic_shapes, torch.utils._sympy) and a
// first-class scientific library for Jubryter notebooks; loading the real
// thing replaces any eager stubbing.
//
// The tests/ subtrees ARE included, the way torch_vfs.js ships 152 test
// modules and numpy_vfs.js 249: a library we ship is proved by its own
// upstream suite, and the suite has to be reachable from the dashboard page.
// sympy/testing/ (the runner) was already here. Cost: 612 files, 12543 tests,
// 1.8 MB gzipped. benchmarks/ stays out -- nothing runs it.
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

const SKIP_DIRS = new Set(['benchmarks', '__pycache__']);

function add(mod, src, isInit) {
  scripts[mod] = ['.py', src, [], !!isInit];
  n++; bytes += src.length;
}

function walk(dir, prefix) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  // mpmath/tests/ is an implicit namespace package: no __init__.py on disk.
  // CPython imports it anyway, the VFS needs the entry spelled out.
  if (!entries.some(e => e.name === '__init__.py') &&
      entries.some(e => e.isFile() && e.name.endsWith('.py'))) {
    add(prefix, '', true);
  }
  for (const e of entries) {
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

// Two stdlib gaps sympy walks into under Brython, both already written for the
// numpy VFS and reused here rather than copied: ctypes (sympy.external.gmpy
// reads sizeof(c_long) to pick its integer width) and pytest (several mpmath
// test modules import it directly; sympy's own tests do not).
const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROBE = path.join(HERE, 'numpy-probe');
for (const [mod, file] of [['ctypes', 'ctypes_stub.py'], ['pytest', 'pytest_shim.py']]) {
  add(mod, fs.readFileSync(path.join(PROBE, file), 'utf8'), false);
}

// pycosat is sympy.logic's optional SAT solver, a C extension around picosat.
// sympy calls import_module('pycosat') on EVERY satisfiable() -- thousands of
// times inside refine/satask -- and nothing memoises the failure. In CPython a
// missing module costs a filesystem lookup; in the browser Brython tries eight
// URLs, each a synchronous XHR ending in 404. Answering "absent" from the VFS
// gives sympy the None it already handles ("Silently fall back to dpll2"),
// at no network cost.
add('pycosat', 'raise ImportError("pycosat is a C extension; not available in the browser")\n', false);

// sympy.printing.mathml builds a DOM through xml.dom.minidom, which Brython
// does not ship. The REAL package from the pinned CPython Lib goes in rather
// than a stub: what sympy uses of it (Document, Text) is pure Python.
const EXT = path.join(HERE, '..', '.wasthon', 'external');
const cpy = fs.existsSync(EXT)
  ? fs.readdirSync(EXT).filter(d => d.startsWith('Python-')).sort().pop() : null;
if (cpy) {
  const XML = path.join(EXT, cpy, 'Lib', 'xml');
  if (fs.existsSync(XML)) walk(XML, 'xml');
} else {
  console.error('WARNING: no CPython Lib found, xml.dom.minidom will be absent');
}

const blob = ';(function(){\nif(typeof __BRYTHON__==="undefined"){throw new Error("load brython.js first")}\n__BRYTHON__.update_VFS(' + JSON.stringify(scripts) + ');\n})();\n';
fs.writeFileSync(OUT, blob);
console.log('sympy VFS: ' + n + ' modules, ' + (bytes / 1048576).toFixed(1) + ' MB src, blob ' + (blob.length / 1048576).toFixed(1) + ' MB -> ' + OUT);
