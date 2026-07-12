# pandas — feasibility pass (2026-07-07)

**Result: Cython→WASM toolchain PROVEN; the compilation wall is small, bounded and
ONE-OFF (shared with numpy.random); the real challenge is structural (Cython assumes the
CPython memory layout, but the bridge = handles).** Tested target: pandas 2.2.3, module `byteswap`
(the simplest: 85 lines, cimports `libc` only).

---

## What is PROVEN (the chain works)

1. **Source**: `pandas-2.2.3.tar.gz` sdist fetched (direct PyPI — `pip download --no-binary`
   spirals into an overlong PEP 517 build).
2. **Cython transpiles**: `Cython==3.0.11` (installed `--target scratchpad/pytools`) transpiles
   `byteswap.pyx` (85 lines) → `byteswap.c` (**7903 lines**). ✅
3. **emcc compiles** the cythonized C against `wasthon.h` (through the `src/Python.h` shim) and
   reaches the C-API layer. ✅

## The wall: Cython's runtime bootstrap

Raw `byteswap.c` → **93 compile errors = ~22 DISTINCT items**. A
`cython_compat.h` shim (~55 lines) + Cython's "portable profile" macros (`-DCYTHON_*=0`)
bring **93 → ~5**. Breakdown:

| Category | Items | Effort |
|---|---|---|
| Trivial macros/typedefs | `PY_INT64_T`, `CO_OPTIMIZED/NEWLOCALS`, `Py_UNICODE`, `PyExceptionClass_Check`, `PyExceptionInstance_Check`, `PyTraceBack_Check`, legacy `PyUnicode_GET_SIZE/AS_UNICODE`, `PyCFunctionWithKeywords` | header one-liners ✅ |
| Stub structs | `PyCodeObject`(co_flags), `PyBaseExceptionObject`, `PyCMethodObject`(mm_class) | minimal struct ✅ |
| Recent/internal C-API functions (bridge contract) | `PyImport_AddModuleRef`, `PyImport_ImportModuleLevelObject`, `PyModule_NewObject`, `_PyObject_GetDictPtr`, `PyUnstable_Code_NewWithPosOnlyArgs`, `PyInterpreterState_GetID`, `PyTraceBack_Check` | ~7 bridge fns — most have cousins; the code-object/traceback ones = no-op stubs (cosmetic) |
| Missing header | `#include <compile.h>` | empty stub |

The "portable profile" macros that disable Cython's internal fast paths:
`-DCYTHON_FAST_THREAD_STATE=0 -DCYTHON_USE_EXC_INFO_STACK=0 -DCYTHON_USE_TYPE_SLOTS=0`
`-DCYTHON_USE_PYTYPE_LOOKUP=0 -DCYTHON_USE_UNICODE_INTERNALS=0 -DCYTHON_USE_PYLONG_INTERNALS=0`
`-DCYTHON_USE_PYLIST_INTERNALS=0 -DCYTHON_ASSUME_SAFE_MACROS=0 -DCYTHON_UNPACK_METHODS=0`.
→ they kill `current_exception` (tstate), `hash` (pylong/unicode internals), etc.

## ★ The real structural challenge: `ob_item` (memory layout vs handles)

After the shim, the emblematic residual error:
```
__Pyx_copy_object_array(src, ((PyListObject*)res)->ob_item, n);
   error: no member named 'ob_item' in 'struct _object'
```
`wasthon.h` **deliberately aliases `PyListObject` → `PyObject`** (no `ob_item` field): in
the bridge, a list is a **handle / JS array**, not a C struct with a contiguous `ob_item`
array. Cython generates **fast paths that assume the CPython memory layout** (`ob_item`,
int `ob_digit`, unicode internals…). Some can be disabled by macro
(`CYTHON_USE_PYLIST_INTERNALS=0`), **but not all** (`__Pyx_copy_object_array` uses one
unconditionally). Two ways out for a real port:
1. force Cython off those paths (additional patches/macros), OR
2. have the bridge **materialize** a real `ob_item` backing array for those accesses.

This is **THE** hard point shared by the entire Cython class (not pandas-specific).

## Scope — this wall is SHARED

`numpy.random` is Cython **too** → it would hit EXACTLY the same bootstrap.
Building the **Cython support layer** once — `cython_compat.h` (repo) + the ~7 bridge fns
+ the `ob_item`/list-internals decision + a `compile.h` stub + `Py_PYTHON_H` in `src/Python.h` —
**unblocks the whole Cython class**: pandas, numpy.random, and scikit-learn's Cython.

## pandas-specific scale (beyond the shim)

Much bigger than numpy.random:
- **41 `.pyx` modules** (vs 8 for random) — see the split core / `tslibs` (16, the datetime
  subsystem) / `window`.
- **Heavy import graph**: `import pandas` pulls most of the core `_libs` → **impossible
  to go module by module** as for random; a big block must be built together.
- **Own C to build**: parser (`tokenizer.c`, `io.c`), datetime (`pd_datetime.c`),
  vendored ujson (C JSON), **klib** (`khash_python.h`, header-only hashtable), vendored np_datetime.
- **27/41 modules `cimport numpy`** → needs the numpy C-API surface (largely acquired through
  `_core`).

## Verdict & next action

- **Toolchain: validated.** Cython + emcc + wasthon work together.
- **Compilation wall: small, bounded, one-off** (~22 items, ~55-line shim).
- **Real challenge: the memory layout** (`ob_item`/internals) — that is where the work is, and it
  is shared by ALL Cython.
- **Whole pandas = a big project** (41 modules + import graph + own C), bigger than random.

**Recommendation**: industrialize the **Cython support layer** first (promote
`cython_compat.h` into the repo, add `Py_PYTHON_H` to `src/Python.h`, implement the ~7 bridge
fns, settle `ob_item`), **validate it on numpy.random's `_mt19937`** (the smallest real
Cython module, see `NUMPY_RANDOM.md`), THEN attack pandas in blocks. The pass's shim lives
in `scratchpad/pdgen/cython_compat.h`.

---
Pointers: `NUMPY_RANDOM.md` (the other Cython lib), `NUMPY.md` (C-API surface acquired through
`_core`), core build `numpy-probe/probe.sh`.
