# The NumBry build — architecture and pitfalls

Cross-cutting notes on `build.sh` and the per-package recipes: what the
per-package docs (`NUMPY.md`, `PANDAS.md`, `SCIPY.md`, `MATPLOTLIB.md`,
`NUMPY_RANDOM.md`) don't cover — the phase structure, the two-Cython
matrix, the relink rules, the page wiring and the VFS gotchas. Every item
here was paid for at least once.

## Phase structure

`build.sh` is a strict pipeline; each phase's output feeds the next:

| Phase | Recipe | Produces |
|---|---|---|
| clone wasthon@main | — | bridge `src/wasthon.*`, Brython, generic `cython-support/` |
| emsdk 5.0.7 | — | `emcc` on PATH (source `emsdk_env.sh` **before** any `cd`: it may chdir) |
| pins | `pin()` | exact source trees (numpy v2.5.1, pandas v2.2.3, scipy v1.14.1, mpl v3.9.2, seaborn v0.13.2, kiwi 1.4.7, two Cythons) |
| bridge | — | `build/wasthon.o` |
| numpy core | `numpy-probe/probe.sh` | codegen + ~90 objects |
| numpy.linalg | `numpy-probe/linalg.sh` | f2c'd lapack_lite objects |
| numpy.random | `cython-support/nprnd.sh` | 9 Cython modules → `nprnd.mjs` |
| dashboard relink | inline in build.sh | `numpy_multiarray_umath.mjs`, `nprnd.mjs` **with linalg** |
| pandas | `pdbuild.sh` | 43 extensions → `nppd.mjs` |
| scipy.ndimage | `ndbuild.sh` | `_nd_image`/`_ni_label` + numpy.fft pocketfft → `npnd.mjs` |
| matplotlib | `mplbuild.sh` | Agg + FreeType + kiwisolver → `npmpl.mjs` |
| seaborn | `sblink.sh` | ONE combined numpy+pandas+mpl wasm → `npsb.mjs` |
| VFS | `gen_*_vfs.mjs` | the pure-Python layers as Brython VFS blobs |
| collect | — | everything into `build/` + `loader/brython/` + `loader/data/` |

**Why combined modules**: a Cython/C++ extension that `import_array()`s
needs numpy's C-API capsule (`_ARRAY_API`) to hold pointers valid in *its*
memory — so every consumer links **with the numpy core objects** into one
wasm (one shared linear memory). There is no cross-module linking; "using
numpy from pandas" means "pandas and numpy are the same wasm".

## The two-Cython matrix (do not "simplify" this)

The recipes were validated against **different Cython versions** and both
are pinned:

- **Cython 3.0.11 (upstream)** — numpy.random (bit-exact MT19937) and
  pandas. Cython 3.3 **crashes on pandas' fused types**
  (`KeyError: FusedType('numeric_t')` in `specialize_fused_types`,
  groupby + window.aggregations). The perl patches in `pdbuild.sh` are
  calibrated on 3.0.11 output.
- **fork fgallaire/cython @ `1fcb9f4c…` (3.3 + ArgsSlice fastcall fix)** —
  scipy.ndimage.

`build.sh` passes `CYTHON_PYTHONPATH` per phase. Similarly exact:
**pybind11 == 2.13.6** (mplbuild's header seds are calibrated on it; 3.x
moved `function_record` and the seds silently stop matching).

## Source-tree traps

- A **git tag clone ≠ the sdist**: numpy's tag lacks the vendored
  submodules the sdist embeds — `pythoncapi-compat`, `highway`, and
  `numpy/fft/pocketfft` (the header-only C++ backend of numpy.fft).
  `build.sh` inits exactly those three.
- A tag tree also lacks the **meson-generated modules** the boot imports:
  `numpy/version.py` (regenerated via `gitversion.py --write`),
  `numpy/__config__.py` (stub), `pandas._version_meson` (stub injected by
  `gen_pandas_vfs.mjs` — without it versioneer shells out to git and the
  boot dies in `posix.pipe`).
- pocketfft compiles as **C++17 with its own flag set**, not the C
  `$CFLAGS` of the recipe (which force-include C-only shims).

## Relink rules

- Emscripten's `.mjs` references its `.wasm` **by output basename**. Link
  with `-o npnd.mjs` directly; renaming `npnd_fft.mjs → npnd.mjs`
  afterwards leaves a dangling wasm reference → `abort` at
  `instantiateArrayBuffer`.
- The bridge (`src/wasthon.js`) is inlined at link time → **any bridge
  change requires relinking every module** (`numpy_multiarray_umath`,
  `nprnd`, `nppd`, `npnd`, `npmpl`, `npsb`). Vendored Brython fixes need
  no relink — but `loader/brython/` here is a **copy** collected from the
  wasthon clone: resync it after any vendored fix before trusting a local
  run.
- Rerunning **one phase** locally: copy the changed file into `.wasthon/`
  and invoke that recipe directly
  (`CYTHON_PYTHONPATH=… bash $W/cython-support/<recipe>.sh <args>`).

## Page wiring

Each test page owns a map `{'pkg.mod._cext': '_PyInit__cext'}` and hooks
`$B.$__import__`: when Brython's import machinery asks for a C extension
(absolute, relative `from ._x import…`, or via a from-list), the hook calls
the exported `PyInit_*`, then `wasthon_module_create`, registers the module
in `$B.imported` and sets it as an attribute of its parent package. Points
that bite:

- the module-def **name must be patched** to the full dotted name before
  `wasthon_module_create` (Cython defs carry the short name);
- from-list entries that are themselves **VFS submodules** must be
  force-imported (Brython doesn't resolve bare submodule names in a
  from-list);
- `test-*-all.html` dashboards delegate to the single-module runner via
  iframes — wire a new C module in the *runner*, not the dashboard.

## VFS gotchas

- **Load order**: `mpl_vfs.js` **before** `pandas_vfs.js` on any page with
  both (`test-seaborn.html`). Both ship dateutil; pandas' lazy
  `dateutil.zoneinfo` override must win.
- **Zoneinfo is untarred at build time** into
  `dateutil_zoneinfo_data.js` (`window.DATEUTIL_ZONEINFO`, lazy-parsed).
  Letting dateutil tar-walk the 619-member tarball under Brython's pure-
  Python tarfile costs **127 s of import time** (measured; the gunzip is
  innocent, the tar walk + tzfile parses are the cost).
- **pytz LazyList/LazySet iterate as empty** under Brython (methods
  rebound by setattr on the class) — `gen_pandas_vfs.mjs` rewrites them to
  eager `list(`/`set(` at generation time.
- `linecache` must be neutralized in VFS pages (pyparsing's
  `_trim_arity` → `extract_stack` → `tokenize.open` → XHR → "I/O operation
  on closed file").
- PEP 562 module `__getattr__` doesn't fire under Brython — anything like
  `__version__` must be set eagerly by the generator.
- **Data files**: tests that XHR relative paths need the files under
  `loader/data/` (numpy.random's test vectors are copied by `build.sh`).
  scipy's `test_measurements` data files are the open item — copying alone
  does not resolve their `open()` path.

## Local dev loop

Node harnesses (no browser, no selenium) exist per module family — a
`.mjs` + the page's import-hook logic replayed in node — and are the fast
path for repros and bisection. Instrumentation note: patch the **built**
`.mjs` (log unconditionally on a small input, then revert); the bridge
source isn't consulted at runtime. In the browser, hard-refresh
(Ctrl+Shift+R) after any relink — modules are cached aggressively by URL.
