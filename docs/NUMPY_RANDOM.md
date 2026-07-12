# numpy.random — why it is missing, and how to build it

**Status: BUILT and scripted (2026-07-08).** The build chain described here is implemented
in **`cython-support/nprnd.sh <numpy-src>`** (after `numpy-probe/probe.sh <numpy-src>`) →
`build/nprnd.{mjs,wasm}`, the combined wasm loaded by `loader/numpy.html`,
`test-numpy-random.html` and the numpy.random rows of `test-numpy-all.html`.
Reproduced from a fresh checkout: probe 135/135, link 0-undefined, browser smoke 38/38.
The document below remains the original inventory (2026-07-07): why the module
was missing, and the build-chain analysis. Numbers measured on the `numpy-2.5.1` tree.

---

## 1. How many tests we are missing

**10 test modules, ~672 `def test_` functions** (before `@pytest.mark.parametrize` expansion):

| test module                             | `test_` fns | parametrize |
|-----------------------------------------|:-----------:|:-----------:|
| test_generator_mt19937.py               | 213         | 27          |
| test_randomstate.py                     | 164         | 1           |
| test_random.py                          | 135         | 3           |
| test_smoke.py                           | 70          | 3           |
| test_direct.py                          | 32          | 0           |
| test_randomstate_regression.py          | 21          | 0           |
| test_generator_mt19937_regressions.py   | 19          | 0           |
| test_regression.py                      | 12          | 1           |
| test_extending.py                       | 3           | 0           |
| test_seed_sequence.py                   | 3           | 0           |
| **TOTAL**                               | **672**     |             |

After `parametrize` expansion (often over lists of dtypes / sizes / bit generators),
the true number of sub-cases is on the order of **several thousand**. It is **the biggest
block of numpy tests we do not run**: the current dashboard = 26 modules / ~1900 runnable
(see the browser dashboard `loader/test-numpy-all.html`); `numpy.random` alone would add a
comparable volume.

## 2. Why we do not have it

`numpy.random` **is not pure Python**: it is a set of **Cython extensions** sitting on
a C library of RNG algorithms.

### 8 extension modules to produce (source: `numpy/random/meson.build`)
| WASM module      | `.pyx` source         | + direct C sources                           | libs   |
|------------------|-----------------------|----------------------------------------------|--------|
| `_common`        | `_common.pyx`         | —                                            | npyrandom |
| `bit_generator`  | `bit_generator.pyx`   | —                                            | npyrandom |
| `_mt19937`       | `_mt19937.pyx`        | `src/mt19937/mt19937.c` + `mt19937-jump.c`   | npyrandom |
| `_philox`        | `_philox.pyx`         | `src/philox/philox.c`                        | npyrandom |
| `_pcg64`         | `_pcg64.pyx`          | `src/pcg64/pcg64.c` (`-U__GNUC_GNU_INLINE__`)| npyrandom |
| `_sfc64`         | `_sfc64.pyx`          | `src/sfc64/sfc64.c`                          | npyrandom |
| `_generator`     | `_generator.pyx`      | —                                            | npyrandom, npymath |
| `mtrand`         | `mtrand.pyx`          | — (legacy `RandomState`)                     | npyrandom, npymath |

Total `.pyx`: **13,162 lines** of Cython.

### The C library `npyrandom` (the algorithms) — `numpy/random/src/`
- `distributions/distributions.c` (the big one: normal/gamma/binomial/… distributions)
- `distributions/logfactorial.c`, `random_hypergeometric.c`, `random_mvhg_count.c`, `random_mvhg_marginals.c`
- `legacy/legacy-distributions.c` (for `RandomState`)
- `mt19937/mt19937.c` (+ `mt19937-jump.c`), `pcg64/pcg64.c`, `philox/philox.c`, `sfc64/sfc64.c`, `splitmix64/splitmix64.c`
- (the `*-benchmark.c`, `*-test-data-gen.c`, `*.orig.c` are OUTSIDE the build — tools/bench.)

### What concretely blocks
1. **Our build (`numpy-probe/probe.sh`) compiles ONLY `numpy/_core`** (the multiarray
   + umath core). `numpy/random` is never touched.
2. **No `.c` is pre-generated** from the `.pyx` (the sdist does not ship them transpiled).
3. **Cython is not even installed** in the build environment
   (`python3 -c "import Cython"` → `ModuleNotFoundError`).

→ **random's Python layer IS already served by the VFS** (`build/numpy_vfs.js` contains
`numpy/random/*.py`). ONLY the C is missing. `import numpy.random` breaks because the
extension modules `_generator` / `mtrand` / `_mt19937` / … do not exist on the WASM side.

## 3. How to get it — build chain to add

**Medium-large** effort (not a quick harvest). Steps:

1. **`pip install Cython`.**
2. **Cythonize** the 8 `.pyx` → 8 `.c` (with the `.pxd`: `_common.pxd`, `bit_generator.pxd`,
   `c_distributions.pxd`, `__init__.pxd`, + the numpy headers already generated in `numpy-probe/gen/`).
3. **Compile** the `npyrandom` lib (~8 algorithm `.c`) + the 8 Cython `.c` to `.o` with `emcc`
   (same flags as `_core`: `-O1 -DNDEBUG -DNPY_INTERNAL_BUILD …`, numpy includes).
4. **Link 8 WASM modules**, each exporting its `PyInit_<mod>`, with the same
   `--js-library src/wasthon.js` and `build/wasthon.o` (like the core).
5. **Hook their `__import__`** in the loader (exactly like `numpy._core._multiarray_umath`
   in `loader/numpy.html` / `test-numpy.html` / `numpy-probe/boot8.mjs`); the Python layer is
   already in the VFS, nothing to add on the `.py` side.
6. **Fill the bridge gaps** revealed by the cythonized C.

### The hard point (step 6)
- **Cross-module PyCapsule**: each BitGenerator exposes its RNG state (a `bitgen_t` struct) via a
  **`PyCapsule` named `"BitGenerator"`** that `_generator` (`Generator`) and `mtrand`
  (`RandomState`) **consume** to draw numbers. It is the pivot of the whole random
  architecture. We already have `PyCapsule` (implemented for `from_dlpack`, see
  [[wasthon-numpy-path]] / `CHANGELOG` PyCapsule_IsValid) — to be validated on this name + pointer pattern.
- **Buffer protocol / dense memoryviews**: Cython-generated C makes heavy use of typed
  `memoryview`s (filling output arrays). Well advanced thanks to `_core`, but
  to re-verify under Cython C.
- **Vectorcall / fastcall**: Cython C calls a lot through the fast call protocols
  (already largely covered by the bridge).

## 4. Verdict & possible next action

It is **the biggest untapped test deposit** (~672 fns + an actually usable `np.random`),
but a full **project**, not an easy fix — comparable to porting a non-trivial
C module, over several iterations.

**Recommended feasibility pass** (before committing): install Cython, cythonize +
compile + link **a single module — `_mt19937`** (the simplest bit generator: just
`mt19937.c` + `_mt19937.pyx`, depends on `_common`/`bit_generator`). See how far it goes before the
first bridge wall → that yields a **firm estimate** for the remaining 8 modules.

---

Pointers: core build = `numpy-probe/probe.sh`; node harness = `numpy-probe/boot8.mjs`;
dashboard = `loader/test-numpy-all.html`; overall numpy status = `NUMPY.md`; hard bugs =
`NUMPY_HARD_BUG.md`.
