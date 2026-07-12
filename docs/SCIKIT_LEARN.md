# scikit-learn — feasibility recon (2026-07-07)

**Conclusion: scikit-learn sits ENTIRELY downstream of SciPy — at the Python level AND at the C level.
There is no "widening" toward sklearn without doing SciPy first (the Fortran monster ★★★★★).**
sklearn stacks EVERY wall already identified, plus the Fortran wall. Analyzed target: scikit-learn 1.5.2.

---

## Extension surface (bigger than pandas)

- **67 Cython modules**: 52 `.pyx` + 15 `.pyx.tp` (Tempita templates → `.pyx`). (`.pxd`: 23 + 8 `.pxd.tp`.)
- **Vendored C++**: libsvm (`svm.cpp`, `libsvm_template.cpp`) + liblinear (`tron.cpp`, `_liblinear`), + 12 `.cpp/.h`, 3 `.c`.
- Cython comparison: **numpy.random 8 | pandas 41 | scikit-learn 67**.

## THE blocking point: SciPy dependency at TWO levels

### 1. C level (the worst) — cimports Fortran BLAS/LAPACK through SciPy
`sklearn/utils/_cython_blas.pyx`:
```cython
from scipy.linalg.cython_blas cimport sdot, ddot, sgemv, dgemv, sscal, ...
```
These `cimport`s resolve, at compile time, to the **Fortran BLAS/LAPACK symbols** that SciPy
links from its own build (OpenBLAS/reference LAPACK). **10 modules** cimport `scipy.linalg.cython_blas`
/`cython_lapack`. So sklearn's compiled C **requires SciPy built with BLAS/LAPACK**.

### 2. Python level — `import sklearn` pulls SciPy immediately
`import sklearn` → `sklearn.utils.validation` → `import scipy.sparse as sp`. sklearn cannot be
imported without SciPy. **127 `.py` modules** of sklearn import scipy, across all of its big
subsystems:

| SciPy subsystem | sklearn modules using it | nature (the wall) |
|---|---:|---|
| scipy.sparse    | 69 | Cython + C++ |
| scipy.special   | 24 | Cython + C (cephes) |
| scipy.linalg    | 22 | **Fortran** (LAPACK/BLAS) |
| scipy.optimize  | 15 | **Fortran** (minpack, L-BFGS) |
| scipy.stats     | 14 | Python + Cython (depends on special) |

## The stacked walls (lightest to heaviest)

1. **Cython bootstrap** (shared with pandas/random) — small, bounded, `cython_compat.h`. See `PANDAS.md`.
2. **Memory layout / handles** (wasthon-specific) — the Cython fast paths (`ob_item`, typed
   memoryviews, fused types) assume the CPython memory layout; sklearn abuses them (perf-critical).
   See `PANDAS.md` § `ob_item`.
3. **OpenMP / `prange`** — **21 modules** parallelize through OpenMP. WASM = no threads by default
   (pthreads + SharedArrayBuffer + cross-origin isolation); a single-threaded fallback is required.
4. **C++** (libsvm/liblinear) — emscripten handles C++, extra surface.
5. ★★★★★ **SciPy = the Fortran wall**: BLAS/LAPACK (`linalg`), minpack (`optimize`), cephes
   (`special`), + SciPy's own whole Cython/C++/Fortran surface (~1 order of magnitude
   more than sklearn).

## Existence proof vs the wasthon reality

- **Pyodide does ship SciPy AND scikit-learn as WASM** → the **Fortran + build side IS solvable**
  (Fortran→WASM toolchain: patched LAPACK + f2c/flang-wasm). That is the proof it is not
  theoretically impossible.
- **BUT Pyodide = real CPython compiled to WASM.** It has **real** CPython objects (`ob_item`,
  actual layouts) → it does **NOT** have wall #2 (layout/handles), which is specific to the wasthon
  bridge (Brython + objects = handles). So wasthon carries an **EXTRA challenge** Pyodide does not.

## Verdict

- sklearn is **not a "next library"**: it is the **top of a pyramid** whose base is
  SciPy. sklearn difficulty ≈ SciPy difficulty **+** its own large surface (67 modules + C++ +
  OpenMP + layout).
- **The real gating target for the whole ML/stats side = SciPy**, and its core = the **Fortran**
  (BLAS/LAPACK/minpack/cephes).
- Realistic order for "widening the CPython-based" scientific side:
  1. **Cython support layer** (`cython_compat.h` + ~7 bridge fns + settle `ob_item`) — shared,
     validatable on numpy.random's `_mt19937`.
  2. **SciPy** — first the **Fortran→WASM toolchain (BLAS/LAPACK)**, then `special`/`sparse`.
  3. **scikit-learn** — only after (1) and (2), + single-threaded OpenMP + C++.

**Recommendation**: do not attack sklearn head-on. If the goal is ML, the structuring investment
is **SciPy / the Fortran wall** (Pyodide proves it is feasible), on top of the shared Cython
layer. sklearn then falls "almost for free" on the algorithm side (but not on the memory-layout
side — the wasthon-specific challenge remains).

---
Pointers: `PANDAS.md` (Cython bootstrap + `ob_item`), `NUMPY_RANDOM.md` (smallest real Cython),
`NUMPY.md` (C-API surface acquired through `_core`).
