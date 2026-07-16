// Generate build/numpy_vfs.js — numpy's Python layer (every numpy/**/*.py) as a
// Brython VFS blob, plus the LAPACK stub, so loader/numpy.html can `import numpy`
// entirely from memory (Brython's own VFSFinder loads numpy.* — only the C
// extension `numpy._core._multiarray_umath` is hooked separately in the page).
//
// Usage:
//   node numpy-probe/gen_numpy_vfs.mjs <numpy-2.5.1/numpy dir> [out=build/numpy_vfs.js]
//
// VFS entry shape (see $B.VFS / VFSFinder in brython.js):
//   $B.VFS["numpy.foo.bar"] = [ext, source, imports, is_package]
//     ext=".py", imports=[] (eager-load hints, unused here), is_package=bool.
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const fs = require('fs'), path = require('path');

const HERE = path.dirname(new URL(import.meta.url).pathname);
const NP = process.argv[2];
const OUT = process.argv[3] || path.join(HERE, '..', 'build', 'numpy_vfs.js');
const STUB = path.join(HERE, '_umath_linalg_stub.py');
const PYTEST_SHIM = path.join(HERE, 'pytest_shim.py');
if (!NP || !fs.existsSync(path.join(NP, '__init__.py'))) {
  console.error('usage: node gen_numpy_vfs.mjs <numpy-2.5.1/numpy dir> [out]');
  process.exit(1);
}

const scripts = { $timestamp: Date.now() };
let n = 0, bytes = 0;
(function walk(dir){
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { walk(full); continue; }
    if (!e.name.endsWith('.py')) continue;
    const rel = path.relative(path.dirname(NP), full);          // numpy/foo/bar.py
    const isInit = e.name === '__init__.py';
    let mod = rel.replace(/\.py$/, '').replace(/[\/\\]/g, '.');  // numpy.foo.bar
    if (isInit) mod = mod.replace(/\.__init__$/, '');            // numpy.foo (package)
    let src = fs.readFileSync(full, 'utf8');
    // CPython's float64 DUAL_INHERITs float, so fromhex is inherited; the
    // bridge keeps float out of float64's bases on purpose (canonicalising
    // broke PyFloat_AsDouble and the random C init) — graft the constructor
    // classmethod at import time instead (test_dragon4 builds its exact
    // doubles with np.float64.fromhex).
    if (mod === 'numpy') {
      src += `
try:
    float64.fromhex = classmethod(lambda _cls, _s: _cls(float.fromhex(_s)))
except Exception:
    pass
`;
    }
    scripts[mod] = ['.py', src, [], isInit];
    n++; bytes += src.length;
  }
})(NP);

// The LAPACK C extension isn't built for WASM — ship a pure-Python stub so
// numpy.linalg (and the whole import) resolves; its gufuncs raise at call time.
scripts['numpy.linalg._umath_linalg'] = ['.py', fs.readFileSync(STUB, 'utf8'), [], false];
n++;

// Minimal ctypes stand-in: prepare_ctypes (BitGenerator.ctypes) builds its
// interface from c_void_p/cast/CFUNCTYPE over real wasm addresses; only the
// C call machinery is stubbed (test_direct's test_ctypes never calls).
scripts['ctypes'] = ['.py', fs.readFileSync(path.join(HERE, 'ctypes_stub.py'), 'utf8'), [], false];
n++;

// A minimal `pytest` shim so numpy's own test modules (numpy/**/tests/test_*.py,
// already walked above) import and run under test-numpy.html — real pytest isn't
// portable. Ships in the VFS so `import pytest` resolves via Brython's VFSFinder.
scripts['pytest'] = ['.py', fs.readFileSync(PYTEST_SHIM, 'utf8'), [], false];
n++;

// Brython perf: scalar fast path for assert_allclose. The stock path (full
// np.isclose + errstate + suppress_warnings machinery) costs ~3 ms per call
// under Brython; scipy.special's multi-complex-arg cython_special cases do a
// cartesian product of test points (elliprj: 16^4 = 65536 scalar asserts in
// ONE test case), blowing the browser's slow-script budget. Decide ONLY the
// clean scalar pass here with numpy's own formula; every other outcome
// (arrays, failures, nan/inf edges, exotic kwargs) falls through to the
// original, so failure messages and semantics stay bit-identical.
{
  const key = 'numpy.testing._private.utils';
  if (!scripts[key]) throw new Error('numpy.testing._private.utils not walked');
  scripts[key][1] += `

# --- wasthon: Brython fast path for scalar assert_allclose (see gen_numpy_vfs)
_wasthon_assert_allclose = assert_allclose

def _wasthon_cnan(z):
    return (z.real != z.real) or (z.imag != z.imag)

def assert_allclose(actual, desired, rtol=1e-7, atol=0, equal_nan=True,
                    err_msg='', verbose=True, **kw):
    if not kw and getattr(actual, 'shape', ()) == () \\
            and getattr(desired, 'shape', ()) == ():
        try:
            # NOT complex(x): the bridge's complex() on a np.complex128
            # falls back to __float__ and silently DROPS the imaginary part
            # (bridge bug, tracked separately). The .real/.imag getsets are
            # exact — and exist on every numeric type, builtin or numpy.
            a = complex(float(actual.real), float(actual.imag))
            d = complex(float(desired.real), float(desired.imag))
            if a == d or abs(a - d) <= atol + rtol * abs(d):
                return
            # numpy's isclose treats a nan-vs-nan pair as equal under
            # equal_nan (complex: nan in EITHER component) — the dominant
            # outcome on invalid-argument test points, so it must stay on
            # the fast path too.
            if equal_nan and _wasthon_cnan(a) and _wasthon_cnan(d):
                return
        except Exception:
            pass
    _wasthon_assert_allclose(actual, desired, rtol=rtol, atol=atol,
                             equal_nan=equal_nan, err_msg=err_msg,
                             verbose=verbose, **kw)
`;
}

// Some dirs are namespace packages with no __init__.py (e.g. numpy/_core/tests),
// so no package entry was emitted for them and Brython's VFSFinder can't resolve
// `import numpy._core.tests.test_x`. Synthesize an empty package for every parent
// prefix that's missing one (the disk finder tolerated this; the VFS doesn't).
for (const mod of Object.keys(scripts)) {
  if (mod === '$timestamp') continue;
  const parts = mod.split('.');
  for (let i = 1; i < parts.length; i++) {
    const pkg = parts.slice(0, i).join('.');
    if (scripts[pkg] === undefined) { scripts[pkg] = ['.py', '', [], true]; n++; }
  }
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
const blob = ';(function(){\n' +
  'if(typeof __BRYTHON__==="undefined"){throw new Error("load brython.js before numpy_vfs.js")}\n' +
  '__BRYTHON__.update_VFS(' + JSON.stringify(scripts) + ');\n})();\n';
fs.writeFileSync(OUT, blob);
console.log('numpy VFS: ' + n + ' modules, ' + (bytes / 1048576).toFixed(1) +
  ' MB source -> ' + OUT + ' (' + (blob.length / 1048576).toFixed(1) + ' MB)');
