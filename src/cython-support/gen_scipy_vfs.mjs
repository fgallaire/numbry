#!/usr/bin/env node
// Build build/scipy_ndimage_vfs.js — the pure-Python layer that
// loader/test-scipy-ndimage.html needs to `import scipy.ndimage`, as a
// Brython VFS. Pairs with build/npnd.mjs (numpy core + numpy.random +
// scipy.ndimage's _nd_image/_ni_label + scipy._lib._ccallback_c) and the
// numpy Python layer from build/numpy_vfs.js.
//
// Usage: gen_scipy_vfs.mjs <scipy-1.14.1-src>
//
// Only the subtrees `import scipy.ndimage` touches are packaged: scipy/_lib,
// scipy/ndimage, plus scipy's top-level bootstrap modules. Two meson-generated
// files (version, __config__) are absent from the sdist → stubbed inline; the
// vendored array_api_compat lives one directory too deep in the sdist (the
// meson install hoists it) → remapped; ctypes is a browser stub (scipy only
// touches it for LowLevelCallable, which ndimage never exercises here).
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
const require = createRequire(import.meta.url);
const fs = require('fs'), path = require('path');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SC = process.argv[2];
if (!SC) { console.error('usage: gen_scipy_vfs.mjs <scipy-1.14.1-src>'); process.exit(1); }
const OUT = path.join(ROOT, 'build', 'scipy_ndimage_vfs.js');

const scripts = { $timestamp: Date.now() };
let n = 0, bytes = 0;

// Per-module source patches: Brython gives a VFS package `__path__` the string
// "<stdlib>", not a filesystem list, so scipy code that indexes __path__[0]
// (a module-level editable-install probe) raises IndexError at import.
const PATCH = {
  'scipy._lib._testutils': (s) => s.replace(
    "IS_EDITABLE = 'editable' in scipy.__path__[0]", 'IS_EDITABLE = False'),
};

function add(mod, src, isInit) {
  if (PATCH[mod]) src = PATCH[mod](src);
  // array_api_compat copies docstrings onto its wrapper functions at import
  // (`asarray.__doc__ = …`); the bridge rejects setting __doc__ on those
  // function objects. The assignments are cosmetic — neutralise them.
  if (mod.includes('array_api_compat')) {
    src = src.replace(/^(\s*)([\w.]+\.__doc__\s*=)/gm, '$1_ = ');
  }
  scripts[mod] = ['.py', src, [], !!isInit];
  n++; bytes += src.length;
}

// Walk a directory, mapping files to modules under `prefix`. Skips tests/.
function walk(dir, prefix) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (e.name === 'tests' || e.name === '__pycache__') continue;
      walk(path.join(dir, e.name), prefix + '.' + e.name);
      continue;
    }
    if (!e.name.endsWith('.py')) continue;
    const isInit = e.name === '__init__.py';
    const mod = isInit ? prefix : prefix + '.' + e.name.replace(/\.py$/, '');
    add(mod, fs.readFileSync(path.join(dir, e.name), 'utf8'), isInit);
  }
}

// scipy._lib (minus the vendored array_api_compat, remapped below) + ndimage.
for (const e of fs.readdirSync(path.join(SC, 'scipy', '_lib'), { withFileTypes: true })) {
  if (e.isDirectory()) {
    if (e.name === 'tests' || e.name === '__pycache__' || e.name === 'array_api_compat') continue;
    walk(path.join(SC, 'scipy', '_lib', e.name), 'scipy._lib.' + e.name);
  } else if (e.name.endsWith('.py')) {
    const isInit = e.name === '__init__.py';
    add(isInit ? 'scipy._lib' : 'scipy._lib.' + e.name.replace(/\.py$/, ''),
        fs.readFileSync(path.join(SC, 'scipy', '_lib', e.name), 'utf8'), isInit);
  }
}
walk(path.join(SC, 'scipy', 'ndimage'), 'scipy.ndimage');
// scipy.ndimage's OWN test suite (classic pytest + numpy.testing, no array-api
// fixtures in 1.14.1) — the dashboard (test-scipy-all.html) runs it against
// the pytest shim shipped in numpy_vfs.js. walk() skips tests/ by design, so
// pull this one in explicitly. The data/ dir (PNG) isn't packaged: the two
// tests that read it fail visibly rather than silently.
walk(path.join(SC, 'scipy', 'ndimage', 'tests'), 'scipy.ndimage.tests');

// array_api_compat (the vendored multi-backend shim) monkeypatches numpy at
// import and reaches deep import chains that Brython's strict VFS import can't
// tolerate the way the node loader does. scipy.ndimage only ever resolves it to
// the numpy backend, so replace the whole package with a numpy-only stub
// exposing exactly what scipy._lib._array_api reads.
add('scipy._lib.array_api_compat',
  'import numpy\n' +
  'def is_array_api_obj(x):\n' +
  '    return isinstance(x, numpy.ndarray) or hasattr(x, "__array_namespace__")\n' +
  'def size(x):\n' +
  '    shp = getattr(x, "shape", None)\n' +
  '    if shp is None or any(d is None for d in shp):\n' +
  '        return None\n' +
  '    n = 1\n' +
  '    for d in shp:\n' +
  '        n *= d\n' +
  '    return n\n' +
  'def device(x, /):\n' +
  '    return "cpu"\n' +
  'def array_namespace(*arrays):\n' +
  '    return numpy\n' +
  'def is_numpy_namespace(xp):\n' +
  '    return xp is numpy\n', false);

// scipy.special: ndimage._interpolation imports it at module level but only
// uses cosdg/sindg (degree-argument cos/sin) inside rotate(). The full module
// (cephes/xsf) isn't built for this smoke — stub those two. Like cephes, the
// stubs are EXACT at multiples of 90 (reduce in degrees first): a plain
// sin(deg2rad(180)) = 1.22e-16 made rotate(180)'s matrix inexact, smearing
// one boundary element (test_rotate_exact_180).
add('scipy.special',
  'import numpy as _np\n' +
  'def sindg(x):\n' +
  '    r = _np.remainder(x, 360.0)\n' +
  '    if r == 0.0:\n        return 0.0\n' +
  '    if r == 90.0:\n        return 1.0\n' +
  '    if r == 180.0:\n        return 0.0\n' +
  '    if r == 270.0:\n        return -1.0\n' +
  '    return _np.sin(_np.deg2rad(x))\n' +
  'def cosdg(x):\n    return sindg(x + 90.0)\n', true);

// scipy bootstrap: real __init__ / _distributor_init, stubbed generated files.
add('scipy', fs.readFileSync(path.join(SC, 'scipy', '__init__.py'), 'utf8'), true);
add('scipy._distributor_init', fs.readFileSync(path.join(SC, 'scipy', '_distributor_init.py'), 'utf8'), false);
add('scipy.version', 'version = "1.14.1"\nfull_version = "1.14.1"\ngit_revision = ""\nrelease = True\n', false);
add('scipy.__config__',
  'CONFIG = {}\n' +
  'def show(mode="stdout"):\n' +
  '    return CONFIG if mode == "dicts" else ""\n', false);

// ctypes stub: scipy._lib._ccallback(_c) builds a few CFUNCTYPE test callbacks
// at import (used only by scipy's own tests). Real ctypes is a CPython
// C-interface module absent from the bridge.
add('ctypes',
  'def WinError(*a, **k):\n    raise OSError("ctypes.WinError is not available")\n' +
  'class _CFuncPtr: pass\n' +
  'def CFUNCTYPE(*a, **k):\n    return type("CFunctionType", (_CFuncPtr,), {})\n' +
  'class c_void_p:\n    def __init__(self, *a, **k):\n        self.value = 0\n' +
  'class c_double: pass\n' +
  'class c_float: pass\n' +
  'class c_int: pass\n' +
  'class c_long: pass\n' +
  'class c_size_t: pass\n' +
  'class py_object: pass\n' +
  'class _Ptr: pass\n' +
  'def POINTER(*a, **k):\n    return _Ptr\n' +
  'class _CastResult:\n    def __init__(self):\n        self.value = 0\n' +
  'def cast(*a, **k):\n    return _CastResult()\n', false);

const blob = ';(function(){\nif(typeof __BRYTHON__==="undefined"){throw new Error("load brython.js first")}\n__BRYTHON__.update_VFS(' + JSON.stringify(scripts) + ');\n})();\n';
fs.writeFileSync(OUT, blob);
console.log('scipy.ndimage VFS: ' + n + ' modules, ' + (bytes / 1048576).toFixed(1) + ' MB src, blob ' + (blob.length / 1048576).toFixed(1) + ' MB -> ' + OUT);
