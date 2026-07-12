# NUMPY — Phase 0: the C-API inventory (2026-07-06, corrected v2)

Method: the UNRESOLVED `Py*` symbols of numpy's compiled `.so` files (= what the
linker demands from CPython, the authoritative list) diffed against what the bridge
provides (functions from `src/wasthon.js` — the Emscripten library, 700+ entries —,
functions/data from `src/wasthon.c`, macros/inlines from the shim headers).
Tool: `numpy_inventory.py`, replayable on any version.

⚠ LESSON (v1 → v2): the first inventory ran on the `src/` of the
wasthong branch, which dates from an OLD main — but the pygame/imgui merge
(7f31091) brought to main precisely the static-types machinery:
**PyType_Ready, PyBufferProcs, the slot typedefs, PySequence/PyMappingMethods,
the tail fields of PyTypeObject**. On the right tree, v1's "wall #1"
(PyType_Ready missing) NO LONGER EXISTS. Always inventory on main.

## The version choice: numpy 2.5.1 (cp314), NOT 1.24

v1's 1.24 pin is ABANDONED, for three converging reasons:
1. **Python compatibility** (decisive): numpy 1.24 only compiles against
   Python ≤ 3.11 (Py_OptimizeFlag removed in 3.13, pre-3.12 PyLong
   internals…). Our headers are 3.14-vintage: porting 1.24 = backporting
   numpy, throwaway work. numpy 2.5.1 publishes **cp314** wheels = the same
   API generation as the bridge.
2. **Borrowed refs**: 1.24 uses PyDict_GetItem (borrowed) everywhere —
   a policy to design on the handle-map side; 2.5 uses the 3.13 `*Ref` APIs
   (PyDict_GetItemRef, PyList_GetItemRef) that the bridge ALREADY covers.
3. **The numbers** (below): 70% covered on 2.5.1 vs 63% on 1.24.

Accepted price: a Meson build (an Emscripten cross recipe to write, existence
proof = Pyodide) and the C metaclass DTypeMeta (invisible to nm, to be
probed in phase 1 — THE remaining question mark).

## The numbers (main's bridge, 830 Py* names provided)

| numpy 2.5.1 scope | distinct symbols | covered | missing |
|---|---:|---:|---:|
| CORE (multiarray_umath + linalg + fft) | 321 | **226 (70%)** | 95 |
| random (10 Cython modules) | 243 | 159 (65%) | 84 |
| internal test modules | 114 | 96 (84%) | 18 |

(v1 for the record: 1.24 CORE = 296/187/63% on the old tree.)

## The CORE's 95 missing, classified

### Header artifacts (~10, free in phase 1)
`_Py_NoneStruct/_Py_TrueStruct/_Py_FalseStruct/_Py_NotImplementedStruct/
_Py_EllipsisObject`, `_Py_Dealloc`, `Py_IsInitialized`,
`PyInterpreterState_Main`, `PyThreadState_Get`, `_PyErr_BadInternalCall` —
the manylinux wheel is compiled against the CPython headers; against the
wasthon headers these symbols resolve via macros (cf. the existing ports).

### 1-line stubs (~8)
`PyContextVar_New/Get/Set` (naive single-thread), `PyTraceMalloc_Track/
Untrack`, `PyEval_GetBuiltins`, `PySys_GetObject`,
`PyUnstable_Object_IsUniqueReferenced*` (return 0 = never unique, safe).

### Pure mechanics (~70, the batch handle-map pattern)
- number: `PyNumber_Invert/Lshift/Negative/Or/Positive/Rshift/Xor` (rich_op
  exists), `PyComplex_Real/ImagAsDouble` + `PyComplex_Type`,
  `PyLong_IsZero/FromUnicodeObject`, `_Py_HashDouble`.
- containers: `PySequence_Concat/Contains/InPlace*`, `PySlice_New/Type`,
  `PyDict_ContainsString/Copy/DelItemString/GetItemStringRef/Merge/Values`,
  `PyMapping_GetItemString`.
- text: `PyUnicode_Contains/Format/FromFormatV/Replace/Tailmatch`,
  `PyBytes_FromString`, `_Py_ascii_whitespace`.
- object: `PyObject_Init/InitVar/Format/Bytes/Not/LengthHint/Print/
  AsFileDescriptor/GenericGetDict`, `_PyObject_GC_New/_PyObject_NewVar`,
  `PyMethod_New`.
- errors: `PyErr_GivenExceptionMatches/NormalizeException/WarnFormat/
  WriteUnraisable`, 5 `PyExc_*` to export, `PyException_SetCause/Context/
  Traceback`.
- capsule: `Import/Get-SetContext/SetName/Type` (New/GetPointer/GetName
  exist; 48 usage sites in numpy 1.24, comparable order in 2.5).
- misc: `PyOS_strtol/strtoul`, `PyArg_VaParseTupleAndKeywords`,
  `PyType_GetFlags/PyType_Modified`, data exports `PyBaseObject_Type/
  PyCFunction_Type/PyDictProxy_Type/PyMemoryView_Type`.

### Remaining structural (small, at last)
- **C descriptors**: `PyGetSetDescr_Type/PyMemberDescr_Type/
  PyMethodDescr_Type` — numpy introspects its descriptors; the bridge
  already materializes tp_getset/tp_members → exports/objects to wire.
- **Generic vectorcall**: `PyVectorcall_Call`,
  `PyObject_VectorcallMethod` (the 3.14 ports go through fastcall →
  probably a small surface).

## What nm does NOT see (the phase-1 list)
1. **DTypeMeta**: numpy 2.x dtypes are C types with a METACLASS —
   how PyType_Ready (the pygame version) reacts to tp_type ≠ PyType_Type;
   THE question mark of the port.
2. **Struct layouts**: `PyFloat_AS_DOUBLE` (ob_fval), scalars
   inheriting from `PyFloatObject`/`PyLongObject` → materialized C shells
   (bytes/cstr pattern, quirk #5). Visible at COMPILE time (phase 1).
3. **Full buffer protocol** (export AND import) — the PyBufferProcs typedef
   arrived with pygame; the full semantics (writable memoryview,
   b4ea3c1) remain to finish.
4. **The Meson build**: an Emscripten cross recipe (cf. Pyodide), to fold
   into brygame's build.sh/recipes pattern.

## Phase 0 verdict (v2)
**70% of the link covered, NO link wall left** — only batch
mechanics + 2 small structural items + the compile-time unknowns. The
pygame merge silently built half the road (static types, buffer typedefs,
PyArg). Next falsifiable milestone — **phase 1: compile
probe** — build `_multiarray_umath` 2.5.1 with the wasthon toolchain
(Meson cross recipe), stub the link, boot `import numpy._core.
_multiarray_umath` up to the first real gap (DTypeMeta and the layouts
will reveal themselves there). The pygame-ce method, exactly.

Working branch: `numpy` (forked from main 66940db, local).

# Phase 1: the compile probe (2026-07-06, same session)

Replayable kit: `numpy-probe/` (probe.sh + the 3 probed wasm32 config
headers + probe_extra.h = every entry is a labeled phase-2 TODO
shim/bridge). Pipeline validated WITHOUT Meson, pygame-ce-recipe style:
standalone numpy generators (`python3 -m code_generators.generate_*`) →
`.src` templates (`process_src_template.py`) → config.h/_numpyconfig.h
written from the probed ABI (wasm32: long 4, longdouble 16 = IEEE quad LE,
off_t 8, complex 8/16/32) → baseline-empty `npy_cpu_dispatch_config.h`
(Pyodide mode) → direct emcc against `src/Python.h`.

## Result: 18/56 multiarray files already compile
(including alloc.c; the 24× repeated errors came from ONE shared header
per round — the onion pattern.)

## The peeled layers (each = a phase-2 TODO class)
1. CPython sub-headers missing from the shim: pymem.h, pyerrors.h,
   frameobject.h (via vendored pythoncapi-compat), datetime.h (→ the
   capsule-based datetime C-API PyDateTime_CAPI = a bridge item of its own).
2. Internal build defines: -DNPY_INTERNAL_BUILD -DHAVE_NPY_CONFIG_H,
   Py_USING_UNICODE, PyMem_FREE/MALLOC aliases…, PyObject_INIT,
   ssizessize*argfunc typedefs, the PyMemAllocatorDomain enum.
3. ★ PY_VERSION_HEX missing from the shim → pythoncapi-compat activated its
   Python-2 fallbacks (PyString_*, PyFrame_FastToLocals): 1 define = 72
   errors. The shim must provide patchlevel.h.
4. The phase-0 nm symbols found ONE BY ONE at compile time
   (near-1:1 cross-validation: PyErr_WriteUnraisable, PyTraceMalloc,
   PyContextVar, PyException_Set*, capsule context, PyComplex,
   PyEval_GetBuiltins, PySlice, descriptors, PyUnstable_*…).

## The probe's STRUCTURAL findings (invisible to nm)
- ★★ `struct _object { intptr_t ob_refcnt; }`: the bridge's PyObject has
  NO ob_type field (handle-map, Py_TYPE() = bridge). numpy accesses it
  DIRECTLY on only 2 sites (methods.c:2000) → 2-line numpy patch in the
  recipe. The 18 files that compile prove Py_TYPE() covers the rest.
- `PyHeapTypeObject` missing from the shim — dtype_api.h (DTypeMeta) EMBEDS
  it (`super`): a layout-sensitive shim addition (done in probe, to harden).
- `PyASCIIObject`/unicode internals referenced by pythoncapi-compat's
  3.14 paths.
- `_Py_SetImmortal` (3.12+ immortality): the bridge's refcount must
  pick a policy.
- Py_Enter/LeaveRecursiveCall (C recursion limit): stubs possible.
- The `*.dispatch.h` generation (argfunc.dispatch.h…): remaining recipe
  plumbing for ~7 files.
- Minor mystery: `undeclared identifier 'new'` (11×) — to dig.

## Phase 1 verdict
The manual-recipe route (no Meson) is VALIDATED end to end.
No new wall: the remains are ~35 mechanical shim/bridge items
+ the 5 bounded structural items above. The logical next step (phase 2):
turn probe_extra.h into real src/*.h additions (headers), implement
the ~95 link functions in batches in wasthon.js, then a first complete
`_multiarray_umath.o` link → boot → DTypeMeta at runtime (the real judge).

# Phase 2 (started same session): THE WHOLE CORE COMPILES, link contract frozen

## Result
- **~150 files = 100% of the numpy 2.5.1 core compile** against the
  wasthon headers: multiarray (56/56), umath + loops/dispatch (baseline),
  npymath (halffloat/ieee754 C++), npysort (vendored highway, -I src/highway),
  stringdtype, textreading. Recipe exclusions: x86_simd_qsort*
  (AVX-only, generic fallback), _simd and the internal test modules.
- **The probe link (with build/wasthon.o + --js-library wasthon.js) yields
  UNDEFINED = exactly 87 symbols, 100% Py*** →
  `numpy-probe/link_contract.txt` = THE phase-3 implementation contract
  (cross-checks the phase-0 nm inventory near-1:1). In batches: ~10 stubs,
  ~60 wasthon.js mechanics, data exports (PyExc_*, types), and the 2 small
  known structural items (C descriptors, vectorcall).
- Bridge/shim commit 698c921 (+ session complements): sub-headers
  (pymem/pyerrors/frameobject/abstract/datetime/patchlevel), faithful 3.14
  structs (PyHeapTypeObject, unicode ×3, CFunction/descriptors),
  tp_is_gc at the TAIL of PyTypeObject, struct _ts.interp, legacy macros/
  typedefs/member-codes, ~55 extern declarations, Py_UNICODE_IS* macros
  (JS impl at link), PyExceptionInstance_Class. ★ Py_GenericAlias becomes
  REAL (types.GenericAlias via the runtime, replaces sre's (void*)0 stub).
  Ports re-verified green after EACH layer: _sre, _pickle,
  _decimal, pyexpat (build + link).
- numpy patches on the recipe side: 3 files / 5 sites (direct
  ->ob_type accesses → Py_TYPE/Py_SET_TYPE) → `numpy-probe/recipe-patches.diff`.
  ⚠ phase-3 runtime: Py_SET_TYPE is a bridge no-op — installing
  StringDType's METACLASS will have to be real.

## Phase 3 (for the resumption)
1. Implement the contract's 87 in batches in wasthon.js (handle-map
   pattern; the PyExc_*/types = data exports on the wasthon.c side like the
   existing ones); smoke the ports after each batch.
2. First CLEAN link of _multiarray_umath.{mjs,wasm} → build.sh recipe
   (generators + templates + configs from the numpy-probe/ kit).
3. Boot: import numpy._core._multiarray_umath in the loader → there speak
   PyType_Ready×31 on the static types, DTypeMeta, the capsules
   (_ARRAY_API, PyDateTime_CAPI) and the layouts at RUNTIME — the real judge.

# Phase 3 (same session): contract IMPLEMENTED, _multiarray_umath BOOTS

## Result: the C module links 0-undefined AND starts
The 87 symbols implemented (commit ab04451):
- **13 data-exports** in `wasthon.c`: 9 type-objects bound to Brython
  classes via BT tags 17-25 (complex/slice/object/memoryview/mappingproxy/
  builtin_function_or_method/getset+member+method_descriptor) + 4 PyExc_.
- **74 functions** in `wasthon.js` (handle-map idioms: rich_op1/dunder
  for number, $getitem/$setitem/$call for dict/seq, setattr for the
  exception state, single-interpreter stubs for thread-state, capsule
  context+import).

## The boot (harness `numpy-probe/boot.mjs`, node ESM)
Loader sequence: `_wasthon_init()` → `PyInit__multiarray_umath()` →
`wasthon_module_create()` (= mod_exec).
- ✅ `_wasthon_init()` OK (the 25 bind_builtin_type calls pass).
- ✅ `PyInit__multiarray_umath()` → non-null handle (519484): the C init runs.
- ✅ `mod_exec` traverses **PyType_Ready ×31 on numpy's STATIC types**,
  the dtype/ufunc registration, the **datetime capsule** (persistent zero
  stub so PyDateTime_IMPORT is non-NULL). ★★ **DTypeMeta and the scalar
  layouts — the 2 dreaded runtime walls — do NOT block.**
- ⏹ STOP at `initialize_static_globals()`: after `import math` (OK), numpy
  does `IMPORT_GLOBAL("numpy.exceptions"/"numpy._globals"/"numpy._core.
  _exceptions"/"numpy._core.printoptions")` → "No module named 'numpy'".

## What this proves
The **C** port of `_multiarray_umath` is functionally crossed:
it compiles (150 files), links (87→0), and the C init runs to the end of
its C part. The stopping point is NOT a C-API wall — it is that the C module
depends on the **Python numpy package** (numpy.exceptions, numpy._globals,
numpy._core._exceptions/printoptions), which must be importable by Brython.

## Phase 4 (the integration frontier)
Make the Python numpy package importable by Brython: vendor numpy's .py
files (starting with numpy/exceptions.py, numpy/_globals.py,
numpy/_core/_exceptions.py, printoptions) and run them on wasthonf,
resolving THEIR cascading imports. This is pure-Python-on-Brython work
(not C bridge), the same profile as any package. The linked
`_multiarray_umath.{mjs,wasm}` (3.5 MB wasm) is ready to be imported BY
that package once it boots. Also remaining, deferred: a real datetime_CAPI
(datetime64 conversion), PyUnicode_FromFormatV varargs, the StringDType
metaclass (Py_SET_TYPE no-op) — none blocks the basic import.

# Phase 4 (same session): the Python numpy package RUNS, the dtype system initializes

## Result: mod_exec traverses the WHOLE numpy type system
Bootstrap: `numpy-probe/boot4.mjs` pre-injects the Python numpy package into
Brython via `$B.run_py` in dependency order (numpy → _utils/_conversions
→ _utils → _globals → exceptions → _core/_exceptions → printoptions → dtypes),
all of them **compile+run on wasthonf** (`run_py`, relative imports OK via
`$is_package`+`__path__`), then `wasthon_module_create` (mod_exec).
- ✅ `initialize_static_globals` PASSES (the 4 init modules seeded).
- ✅ **The whole dtype system initializes**: PyType_Ready on the DType
  classes, sort/cast ArrayMethods registered for EVERY builtin dtype
  (half, float, string…). ★★ **The TWO DTypeMeta metatype walls — the
  project's #1 risk — have FALLEN.**

## The 3 walls crossed this phase (durable fixes, commit b6d33bf)
1. **descrs = C structs, not handles**: numpy's `_builtin_descrs[]` are
   static C structs in linear memory; `unwrap` returns null. The bridge's
   PyObject has NO ob_type slot. → `Py_SET_TYPE(descr, cls)` registers in a
   **pointer→type side-table** (`_cType`) that `wasthon_get_type_of`
   consults FIRST. `_Half_dtype = Py_TYPE(descr)` finally resolves.
2. **DTypeMeta loses its metatype**: the prototype's
   `PyVarObject_HEAD_INIT(&PyArrayDTypeMeta_Type,0)` = `{0},0` under the
   shim (no ob_type slot) → metatype dropped. Recipe patch:
   `Py_SET_TYPE(dtype_class, &PyArrayDTypeMeta_Type)` after
   `PyType_Ready` (dtypemeta.c; StringDType likewise via side-table-first).
   `type(np.dtypes.Float16DType)` resolves.
3. **`Py_SET_TYPE` was a no-op macro** → a real bridge function (rebinds the
   Brython class + `__wasthon_type__` for handles, side-table for C
   structs). + PyArg format char `$` (PEP 3102 kw-only marker).

## Stopping point: the SCALAR subsystem
`int() argument must be ... not 'int32'`: numpy converts an int32 scalar
to a Python int during init. Brython's `int()` does try `__int__`/`__index__`
(`$B.$getattr(get_class(v), '__int__')`), but the np.int32 scalar's class
does not expose them — the scalar type's C slots `nb_int`/`nb_index` are
not materialized as Brython dunders by PyType_Ready. This is the
"scalar shells" work anticipated in phase 3: wire tp_as_number->nb_* (and
reading the scalar's C value) to the Brython dunders.

## Phase 5 (the resumption)
Materialize the numeric protocol of numpy's scalar types: have
PyType_Ready (or a post-pass) expose a scalar type's
tp_as_number->nb_int/nb_index/nb_float… as Brython `__int__`/`__index__`/
`__float__`, and make the scalar's C value readable. Same pattern as
`wasthon_init_number_protocols` (done for PyLong/PyFloat) extended to the
~24 scalar types. Once through, the init should reach the end of mod_exec
→ `import numpy._core._multiarray_umath` succeeds → first ndarray
operations. The boot4.mjs bootstrap + the side-tables are in place.

# Phase 5 (same session): scalar conversion + NDEBUG → very deep mod_exec

## Result: scalars convert, the init traverses the cast setup
- **Scalar conversion slots** (commit 5a22b80): PyType_Ready (static-types
  path) materialized the arithmetic dunders but NOT the conversions →
  np.int32 exposed neither `__int__`/`__index__`/`__float__`, and
  Brython's `int()` (which dispatches to those dunders) rejected int32.
  Added nb_int@64→`__int__`, nb_float@72→`__float__`, nb_index@132→`__index__`
  (+ bitwise binaries + `__rmod__`). `int(np.int32)`/`float(np.float64)` OK.
- **-DNDEBUG** (probe.sh): numpy has internal debug `assert()`s
  (`PyArray_DescrCheck` in dtype_transfer.c) disabled in the production
  manylinux wheels. Compiling with `-DNDEBUG` matches prod and passes
  the cast setup. ★ LESSON: numpy's asserts require NDEBUG like prod.

## Stopping point: scalar IDENTITY + VALUE (the "scalar shells")
`invalid literal for long double:` — `LONGDOUBLE_setitem(op)` receives a
longdouble scalar but `PyArray_IsScalar(op, LongDouble)` returns FALSE
(the scalar's type identity is not recognized: Py_TYPE(scalar) ≠
PyLongDoubleArrType_Type), so numpy falls to `string_to_long_double(op)`
which finds no str → parses "" → error. This is the full SCALAR
subsystem: (a) IDENTITY — numpy scalars (C structs embedding a value)
must have Py_TYPE = their ArrType_Type for `PyArray_IsScalar`/
`PyObject_TypeCheck`; (b) VALUE — `PyArrayScalar_VAL(op, LongDouble)` reads
the C value embedded in the scalar struct. Both tie back to the missing
ob_type slot in the bridge PyObject (same root as the descrs).

## Phase 6 (the resumption)
Materialize numpy's scalar types: have scalar creation
(PyArray_Scalar → the ArrType's tp_alloc) yield an object whose Py_TYPE =
the ArrType_Type (via the `_cType` side-table already in place, or by
registering the ArrTypes as Brython classes), and make the embedded C value
readable (scalar shells, bytes/cstr `__wasthon_cstr__` pattern). Once
scalar identity+value are in place, `LONGDOUBLE_setitem` and all
scalar→C conversions pass, and the init should reach the end of
mod_exec → `import numpy._core._multiarray_umath` succeeds. Build: `-DNDEBUG`
mandatory (probe.sh updated). Boot: `numpy-probe/boot4.mjs`.

# Phase 6 (same session): robust scalar conversions, very deep init

## Result: mod_exec passes the whole longdouble/scalar path
Root of the longdouble wall: the bridge hands numpy JS PRIMITIVES (a float
= JS number, a bool = JS boolean) where numpy expects Python objects, so
`LONGDOUBLE_setitem` → `string_to_long_double` (which only handles
PyLong/str) failed on them.
- **PyFloat_AsDouble handles JS booleans** (True→1.0) — bridge.
- **Recipe patch**: `string_to_long_double` routes everything non-string
  through `PyFloat_AsDouble` (covers float/bool/`__float__`).
Diagnosed by successive instrumentation: float (patched) → bool (patched).

## Stopping point: a silent -1 in mod_exec's long tail
`module exec slot returned -1 without setting an exception`: a deeper step
of `_multiarray_umath_exec` returns -1 with no pending exception.
Hard to pinpoint without numpy-side tracing (numpy compiled without line
info). It is the init's long tail (dozens of sub-inits).

## The real debt: scalar identity (still open)
These conversions (float/bool→C) are a WORKAROUND: the real solution is
for numpy scalars to be typed objects (`Py_TYPE(scalar) ==
ArrType_Type` so `PyArray_IsScalar` is true, C value readable via
`PyArrayScalar_VAL`). As long as the bridge yields primitives, every
primitive type (float, bool, complex…) must be worked around in every
setitem. The structural fix = materialize the scalars (shells pattern),
which would remove this whole class of workarounds.

## Phase 7 (the resumption)
1. Pinpoint the silent -1: instrument `_multiarray_umath_exec` (add
   recipe logs OR compile numpy with line info / an
   fprintf per sub-init) to find which sub-init returns -1.
   Suspect: an init calling a bridge stub returning -1 without an error
   (PyArg_VaParseTupleAndKeywords→0, PyUnicode_FromFormatV, PyVectorcall…).
2. In parallel, the structural scalar fix (identity+value) that removes the
   conversion workarounds. Build: -DNDEBUG. Boot: boot4.mjs.

# ★★★ NUMPY'S C CORE BOOTS (2026-07-06, same session)

## Result: `_multiarray_umath` initializes FULLY and creates ndarrays
`wasthon_module_create` returns a real module (`ndarray`, `dtype`, `zeros`,
`array`, `_ARRAY_API`, `flatiter`). Functional test (numpy-probe/boot4.mjs):
`array([1,2,3])` → an **ndarray** with `.shape==(3,)`, `.ndim==1`, `.size==3`.

## mod_exec's long tail, crossed by bisection (printf markers)
The silent -1 → chain: `initumath` → `_PyArray_SetNumericOps` → `SET(add)`
→ `!PyCallable_Check(ufunc)`. Root 1: **PyType_Ready did not install
tp_call → __call__**; numpy's ufuncs (callables via tp_call) were not
seen as callable. Bridge fix: tp_call@100 wired (FromModuleAndSpec
marshaling). Then a DType wall in the umath dispatcher (`DType tuple may
only contain None and DType classes`). Root 2: the **6 ABSTRACT DTypes**
(Int/Float/Complex Abstract + PyLong/PyFloat/PyComplexDType) readied outside
`dtypemeta_wrap_legacy_descriptor` → no metatype. Recipe fix:
`Py_SET_TYPE(&X, &PyArrayDTypeMeta_Type)` after each PyType_Ready.

## C port balance sheet
numpy's C port is FUNCTIONALLY COMPLETE for the core:
compiles (150 files) → links (87→0) → full mod_exec → real ndarrays.
All the hard roots fell: DTypeMeta (_cType side-table +
real Py_SET_TYPE + metatype on legacy/string/abstract dtypes), scalars
(int/float/bool conversion), tp_call, PyArg $, NDEBUG.

## What remains = numpy's PYTHON layer (phase 8, not C bridge)
- `.sum()` → ufunc reductions that import lazy numpy Python modules.
- `repr(arr)` → `numpy._core.arrayprint`.
- full `import numpy` → the whole Python package (numpy/__init__.py and its
  cascade), to run on wasthonf/Brython (same profile as any
  pure-Python package, NOT C bridge).
The boot4.mjs bootstrap already seeds 7 modules; phase 8 = extend that
seeding to the whole package (or a real finder that loads numpy's .py), and
settle the lazy imports triggered by operations. Build: -DNDEBUG. The
linked `_multiarray_umath.{mjs,wasm}` is ready to be imported by that package.

# Phase 8 (started): numpy's Python layer — full import

## Infra: recursive disk finder (numpy-probe/boot8.mjs)
Wrap of `$B.$__import__`: any missing `numpy.*` module is loaded from the
source tree via `run_py`; the cascade resolves by recursion. The C
`_multiarray_umath` initializes LAZILY when `numpy._core` imports it (at
that point numpy+numpy._core are partial in $B.imported →
initialize_static_globals resolves). Also resolves the circular bootstrap
correctly.

## Progress: `import numpy` traverses the start of the cascade
Loaded OK: numpy, numpy.version, numpy._expired_attrs_2_0, numpy._globals,
numpy._utils(._conversions), numpy._distributor_init. Stub added:
numpy/__config__.py (generated at meson build time, absent from the sdist;
recipe → numpy-probe/numpy__config__stub.py).

## Remaining walls (Brython-level, not C bridge)
1. **`posix.putenv`/`unsetenv` not implemented** (Brython) — numpy._core/
   __init__.py uses them for a reload-guard (gh-30627). Fix = make them
   no-op on the vendored Brython side (the harness monkeypatch did not take:
   putenv is resolved dynamically, not through the module dict — to investigate).
2. **Import quirk `numpy._core.False_`** — `from . import (..., True_, False_)`
   where these are OBJECTS not modules; Brython tries importing them as
   submodules. Adjust the finder / the fromlist handling.
3. Then: the rest of the package (numpy/__init__.py = ~450 lines, the
   _core cascade → dozens of modules), the operations' lazy imports (.sum →
   numpy._core._methods → `import numpy as np`).

## Phase 8bis (resumption)
Make `posix.putenv/unsetenv` no-op (vendored Brython), fix the fromlist
finder for non-modules, then unroll the cascade module by module
(same technique: each EXC = one missing module/attr to supply). The C core
is ready; this is pure-Python-on-Brython. Build -DNDEBUG, harness boot8.mjs.

# Phase 8bis DONE (2026-07-07): the cascade traverses all of numpy._core

## Result: 78 numpy modules load, `numpy._core` imports FULLY
From `posix.putenv` the cascade reaches into `numpy._typing`, `numpy.linalg`,
`numpy.matrixlib`, `numpy.lib`. **The numpy core is FUNCTIONAL** (harness
scratchpad np_descr_probe.mjs): `array([1,2,3,4])` = ndarray, `.tolist()` =
[1,2,3,4], indexing `a[0]` = **int32** scalar, `int(a[0])` = 1,
**`a.sum()` = 10** (correct, int32 type), `.max()`, typeinfo (58 real dtypes),
`arr.dtype` = Int32DType, `repr(dtype)` OK.

## 6 walls fallen this session (all committed locally, numpy branch)
1. **posix.putenv/unsetenv** (VENDORED Brython, backing environ) — reload-guard
   gh-30627. The harness monkeypatch did not take (dynamic resolution) → clean
   fix in `brython_stdlib.js` (posix module). [[wasthon-numpy-path]]
2. **Harness: do NOT overwrite `$B.builtins.__import__`** — replacing it with
   the raw `$B.$__import__` removes the arg defaults (globals=None); the bridge's
   `PyImport_ImportModule(name)` (1 arg) then crashed in `str_dict_get`
   (globals=undefined). The real `_b_.__import__` applies the defaults THEN
   delegates to our wrapper. (boot8.mjs)
3. **RECIPE: `arr_add_docstring` no-op** — `overrides.py` add_docstrings the
   `_ArrayFunctionDispatcher` type; the struct-deref branches (`new->tp_doc`, …)
   dereference a bridge handle as a pointer → OOB. Docstrings are cosmetic.
4. **BRIDGE: tp_dictoffset → real instance `__dict__`** (`$slots_has_dict` +
   auto-creating `__dict__` getset). numpy does `ufunc.__module__ = …` (×90) and
   `update_wrapper(dispatcher, …)` READS `dispatcher.__dict__`.
5. **BRIDGE: `unwrap` materializes `_cType` pointers on demand** — the static
   dtype descrs (`_builtin_descrs[]`) are never handles → crossed as JS `null`
   (typeinfo, arr.dtype). Wrapper {`__wasthon_ptr__`, `__class__`=dtype class}
   bound for identity.
6. **BRIDGE (two):** (a) **PyType_Ready readies the base recursively** if not
   materialized — numpy readies `Int32DType` (base=`IntAbstractDType`) BEFORE
   the abstract is readied (`initialize_and_map` later) → the link fell to
   `object`, `.type`/`.kind` unreachable. CPython readies the base first. (b)
   **member getter: `Py_T_CHAR`(15)/`LONGLONG`/`ULONGLONG`/`DOUBLE`/`FLOAT`** —
   the switch stopped at `UBYTE`(12), the dtype `.kind`/`.char`/`.flags` raised
   `SystemError: unsupported PyMemberDef type: 15`.

## Remaining walls for a COMPLETE `import numpy` (14 failures, categorized)
- **Brython PEP 695** (`type X = …`, `class C[T]:`) → `locals_X is not defined`
  on `numpy._typing._dtype_like`, `numpy.lib._arraysetops_impl` (type-only
  modules, not needed at runtime). Brython codegen gap (candidate big vendored
  project, or patch numpy to avoid them).
- **`_umath_linalg` missing** (LAPACK C ext) → `numpy.linalg._linalg` →
  `matrixlib.defmatrix` → `lib._index_tricks_impl`. Needs a second C port
  (LAPACK/BLAS) — big.
- **Real bugs to dig** (probable fixes): `_add_newdocs_scalars`
  (`too many values to unpack (expected 5, got 6)`), `_core.numeric`
  (`AttributeError undefined`), `lib._scimath_impl` (`Maximum call stack
  exceeded` — recursion).

## Two functional core bugs (runtime path, to dig)
- **`repr(arr)` / `repr(scalar)`** → `SystemError: unable to get format_options
  context variable`. numpy creates `format_options` = a (Brython)
  `contextvars.ContextVar` in `printoptions.py` and the C reads it via
  `PyContextVar_Get` + `IMPORT_GLOBAL`. The bridge's `PyContextVar_Get` only
  handles its OWN ContextVars (`{value}`); the CVs seen (varH 125/492) are
  bridge ones (numpy `current_handler` memory), the get of the Brython CV
  `format_options` never shows → either `IMPORT_GLOBAL` captures it wrong, or
  the repr path differs. LEAD: make `PyContextVar_Get` read `.get()` of a real
  Brython ContextVar, and check `IMPORT_GLOBAL("numpy._core.printoptions",
  "format_options")`.
- **`a+b` / `a*b` (element-wise ufunc)** → `Maximum call stack exceeded`
  (recursion). Distinct from reductions (`sum`/`max` work). Probable loop
  in the ufunc dispatch/number protocol or `__array_ufunc__`. To stack-trace
  (Brython re-wraps the RangeError → capture the raw JS stack).

## Repro
`cd <scratchpad>; node np8boot.mjs` (cascade) or `node np_descr_probe.mjs`
(functional ops). numpy-2.5.1 tree + NDEBUG .o in npobj2/, gen in
npgen/, factory npprobe.mjs. Relink: see the emcc command (npobj2/*.o +
build/wasthon.o + --js-library src/wasthon.js, EXPORT `_wasthon_module_create`).

# ★★★ NUMPY CORE FULLY FUNCTIONAL (2026-07-07, same session, +10 commits)

## All the core's runtime bugs SOLVED — numpy really computes
```
array([1,2,3,4,5,6])          => array([1, 2, 3, 4, 5, 6])
.reshape(2,3)                 => array([[1, 2, 3], [4, 5, 6]])
.sum()/.mean()/.std()         => np.int32(21) / 3.5 / np.float64(1.7078…)
.min()/.max()/.argmax()       => np.int32(1) / np.int32(6) / np.int32(5)
.cumsum()                     => array([ 1,  3,  6, 10, 15, 21])
a+a / a*2                     => array([ 2,  4,  6,  8, 10, 12])
a>3                           => array([False, False, False, True, True, True])
a[0], int(a[0]), a[0]==1      => np.int32(1), 1, np.True_
a.dtype / .dtype.name         => dtype('int32') / 'int32'
repr(scalar) / repr(array)    => np.int32(1) / array(...)
```

## The 10 runtime walls fallen (discovery order, all committed)
1. **`PyVectorcall_Call`** re-dispatched via `$B.$call` → infinite recursion on
   `a+b`/`a*b`/`repr(array)` (the ufunc has `tp_call=&PyVectorcall_Call`). Fix:
   honor the vectorcall protocol (call the `vectorcallfunc` at
   `tp_vectorcall_offset`@72).
2. **`os.uname()`** returned 6 fields (platform) → VENDORED 5-field (`_add_newdocs_scalars`).
3. **`from . import X, X as Y`** lost the plain name → VENDORED (numeric).
4. **`issubclass(non-class)`** crashed instead of `TypeError` → VENDORED (dtype.name/issubdtype).
5. **`PyArg_VaParseTupleAndKeywords`** = stub `return 0` → delegate to the non-va
   parser (`va_list`=varargs ptr in emscripten); `NpyArg_ParseKeywords` → **reshape** + every
   kwargs method.
6. **np.bool_ static singletons** (`_PyArrayScalar_BoolValues`) → RECIPE `Py_SET_TYPE`
   + BRIDGE `_wasthon_Py_SET_TYPE` doing raw handle lookup (not the materializing
   unwrap, which cached a classless wrapper before the type existed) → **scalar comparison**.
7. **`PyFloat_Check`** matched Brython ints (`typeof==='number'`) → `!Number.isInteger`
   (Brython floats are boxed) → `PyArray_PythonPyIntFromInt` accepts int axis/ndim
   → **mean** passes `normalize_axis_index`.
8. **`PyFloat_Type.tp_new`** = null slot → `wasthon_builtin_float_tp_new` (C+JS) →
   `double_arrtype_new`/`np.float64(x)` → **mean=2.5, std, cumsum**.
9. **`PyContextVar_Get`** only handled its own `{value}` → read `.get()` of a real
   Brython ContextVar → **scalar repr** (`format_options`).
10. (already in 8bis) tp_dictoffset `__dict__`, `unwrap` materializes `_cType`,
    recursive base-ready, `Py_T_CHAR`, `arr_add_docstring` no-op, `posix.putenv`.

## What still BLOCKS the COMPLETE `import numpy`
- ~~Brython PEP 695~~ **SOLVED 07-07** (VENDORED). It was NOT missing PEP 695
  support (Brython handles `type X=`, `class C[T]:`, `def f[T]:`, bounds, generic
  aliases). The real bug: `types.FunctionType`/`$B.function.$factory` bound a
  module's globals to the **calling frame**'s module (`'locals_'+frame[2]`)
  instead of the **code**'s module. When `typing.Protocol` lazily evaluates the
  `__annotate__` of a cross-module PEP 695 generic class (via
  `annotationlib.get_annotations`), the current frame = `annotationlib`
  → param `locals_annotationlib` ≠ the `locals_<module>` referenced by the body → JS
  `locals_<module> is not defined` FATAL. Fix: bind from the code's module
  (`globals.__name__`, else the `locals_<mod>` the body literally references) → an
  unresolved name becomes a clean Python `NameError` (handled by annotationlib)
  instead of a JS crash. `numpy._typing._dtype_like` + `numpy.lib._arraysetops_impl`
  LOAD. Cascade 78→**81 modules**.
- **`_umath_linalg`** (LAPACK) → linalg/matrixlib/index_tricks/arraypad/polynomial/shape_base
  (the last **7** failures, all in that cascade). A 2nd C port (BLAS/LAPACK→WASM). Huge —
  blocks linear algebra, NOT the rest. Can wait (Florent's decision 07-07).
The C core + the operational Python layer ARE there; the ONLY remaining wall for the full
`import numpy` is LAPACK. The numpy core RUNS on wasthonf/Brython.

# ★★★ FULL `import numpy` SUCCEEDS (2026-07-07) — via LAPACK stub

## Proof: `import numpy OK`, 83 modules, 0 failures
LAPACK only concerns linear algebra. `numpy/linalg/_linalg.py` only touches
`_umath_linalg` at import (line 80, `from … import _umath_linalg`) — NO
module-level attribute access; the 20 gufuncs (solve/inv/det/eig/svd/qr/cholesky/lstsq/…)
are only used INSIDE functions. So a **pure-Python stub** (numpy-probe/
`_umath_linalg_stub.py`: the 20 names = callables raising NotImplementedError) makes
`numpy.linalg` import → the whole cascade (matrixlib/index_tricks/arraypad/polynomial/
shape_base) completes → **`import numpy` succeeds** (`np.__version__` == '2.5.1').

## The top-level `np.` API WORKS (everything but linalg)
```
np.array([1,2,3]) / np.arange(6).reshape(2,3) / np.zeros(3) / np.ones((2,2))  ✓
np.sum / np.mean / np.sqrt(ufunc) / np.dot([1,2,3],[4,5,6])==32 / np.pi        ✓
float-array repr (via errstate/contextvars)                                    ✓
np.linalg.inv(...)  →  clean NotImplementedError (LAPACK not built)            ✓ (expected)
```
A few functions remain to finish (e.g. `np.linspace` → a `Symbol(DICT)` on null, a
distinct dispatch bug). The stub is the clean route: Pierre will ship a
`_umath_linalg.py` on the integration side (or a real LAPACK port later);
95%+ of numpy is usable WITHOUT it.

## The contextvars fix that unlocked np.ones/np.sqrt/float-repr
`PyContextVar_New` created a `{value}` shim without `.set()`; numpy does
`_extobj_contextvar.set(extobj)` in `errstate.__enter__` (Python), used by
`FloatingFormat.fillFormat` for any float array with non-zero values. Fix: create a real
Brython `contextvars.ContextVar` (+ Set via `.set()`). C side and Python side share the object.

# Browser page: loader/numpy.html (2026-07-07)

Model = `loader/wasthonp.html` (a special case with its own page, not the standard
bundle). numpy's Python layer is served through a **Brython VFS** (Florent's choice):
a `.js` blob loaded by `<script>`, Brython's VFSFinder imports numpy.* by itself;
only the C module `_multiarray_umath` is hooked in the page (created lazily via the
WASM factory at the right point of the bootstrap). Validated in node with the REAL
VFSFinder (runvfs).

## Building the assets (in build/, gitignored)
```
# 1. the C core (npprobe) — see numpy-probe/probe.sh, then:
cp <scratchpad>/npprobe.mjs  build/numpy_multiarray_umath.mjs   # references npprobe.wasm
cp <scratchpad>/npprobe.wasm build/npprobe.wasm
# 2. the VFS (numpy Python layer + LAPACK stub):
node numpy-probe/gen_numpy_vfs.mjs <numpy-2.5.1/numpy>          # -> build/numpy_vfs.js (~8.8 MB)
# 3. open loader/numpy.html (serves build/ as ../build/)
```
The page runs: array/arange/reshape/sum/mean/a+a/a*2/a>2/sqrt/dot/ones/pi/m.T,
and `np.linalg.inv` → clean NotImplementedError (LAPACK). ~12 MB of assets (wasm 3.3 +
VFS 8.8). The generator is tracked; the blobs are build artifacts.

## Known gaps in the numpy layer (to finish, independent of LAPACK)
- `np.eye` → `arr.flat[slice] = 1`: **flatiter assignment** not wired yet.
- `np.linspace` → a `Symbol(DICT)` on null (a distinct dispatch bug).
The rest of the tested API works.

# ★★ 7 BRIDGE WALLS FALLEN (2026-07-07, +7 commits, `numpy` branch)
Long-tail hunt via node harnesses (disk-loader `nptest.mjs` + VFS `runvfs.mjs`). Each
fix = 1 one-line bridge commit, 4 ports re-smoked green. `loader/numpy.html` = **29/29**
(sections [7]-[8] added: eye/diag/linspace/flat-setitem/matmul/roll/pad/np.int32-slice/view-subclass).

1. **flatiter** (`arr.flat`, `np.eye`, `np.diag`) — `PyObject_Init`/`PyObject_InitVar` were
   no-ops; `PyArray_IterNew` mallocs+inits its iterator outside `tp_alloc` → arrived `null`.
   Both now bind the raw ptr to its type (idempotent). Commit 1de750a.
2. **`np.linspace`** — `_PyObject_NewVar` stub `return 0` → `_array_converter(...)` = null.
   Delegates to `wasthon_object_gc_new_var` (basicsize+n*itemsize alloc). Commit f41ca68.
3. **`@` matmul** — `nb_matrix_multiply`/`nb_inplace_matrix_multiply` (offsets 136/140)
   missing from the static types' numeric slot reader. Commit dc707a3.
4. **`.view(subclass)`** — `PyCapsule_CheckExact` answered true for ANY object → numpy took
   the C-func branch for every Python `__array_finalize__` → silent NULL ("view: call
   returned NULL"). Now only matches real `{__class__:'PyCapsule'}`. Commit 1f7e58e.
5. **Subclass instance `__dict__`** — instances allocated by numpy's C `tp_alloc`
   (`arr.view(Sub)`) had no dict → `self.foo=x` / `self.__dict__.update()` broke.
   `gc_new`/`_var` init the dict when the class has ITS OWN `__dict__` descriptor
   (the marker of Brython subclasses; base C types do not have it). Commit 4797be2.
6. **Static C iterators** (`np.broadcast` → `np.roll`) — `tp_iter`/`tp_iternext` (offsets
   24/56) exposed as `__iter__`/`__next__` when `tp_iternext` is present (guarded so as not
   to touch container iteration like ndarray). Commit 8945366.
7. **numpy slice bounds** (`arr[np.int32(i):np.int32(j)]`, `np.pad`) — `PySlice_GetIndicesEx`
   read `slice.indices()` via `Number()`; `Number(np.int32(1))`=NaN → `|0`=0 → empty slice.
   Coerce via `coerceInt` (`__index__`). Commit cde39f9. **Strong lever** (every bound computed
   by numpy is a numpy scalar).

## Remaining walls (rabbit holes, diminishing ROI)
- **numpy.ma** (blocks `np.unique` too): the `masked = MaskedConstant()` singleton bootstraps
  via `MaskedArray(...).view(MaskedConstant)`; each fix peels one `__array_finalize__` layer
  (solved: capsule, `_update_from`/`__dict__`) — now stops at `self.dtype` = null in
  MaskedConstant's nested finalize (core.py:3139). Deep chain in the ma bootstrap.
- **`np.percentile`**: `RuntimeError: Only NumPy must call ufunc->type_resolver()` — C
  internals of a ufunc (lerp/type-resolver). Deep.
- **`np.random`**: `_bounded_integers`/`mtrand`/… = Cython extensions not built for WASM
  (like LAPACK — out of pure-bridge scope, would require porting those .pyx).

# ★ The numpy test suite RUNS (2026-07-07) — not turnkey like CPython
The CPython tests work because they only use `unittest` (in Brython) and are
self-contained. numpy's 182 test files depend on: **pytest** (147/182),
**hypothesis** (6), **numpy.random** (66, unbuilt C ext), **C test extensions**
(`_rational_tests`/`_multiarray_tests`/…, 26). Of the 121 files in the real API
directories, **54 are blocked ONLY by pytest**.
Unblocked with TWO artifacts (numpy-probe/, tracked): (1) `_umath_linalg_stub.py` gains
`_ilp64 = False` — `numpy/testing/_private/utils.py:96` reads `HAS_LAPACK64 =
_umath_linalg._ilp64` at import; without it `numpy.testing` half-imported (no
`assert_*`). (2) `pytest_shim.py` (~150 lines): `raises`/`mark.parametrize`/`skip`/`skipif`/
`xfail`/`fixture`/`approx`/`warns`/`param`. + a collector/runner (scratchpad `nprun.mjs`)
that finds the `Test*`/`test_*`, expands `parametrize`, runs, counts pass/fail/skip.

Measured result (14 files, node harness `nprun.mjs`): **1148 pass / 120 fail / 10 skip**.
Nice scores: test_scalar_ctors 184/13, test_umath_complex 323/5, test_arraypad 571/45,
test_function_base 33/7, test_indexerrors 8/0. Failure nature = 2 families: (a) shim
holes (fixtures with a `request` argument → should become skips, not fails:
test_finfo 0/30); (b) real bridge holes (recurring: `ufunc->type_resolver()` on the
mixins/percentile; `null function` on char-scalar radd/repeat). A real
`test-numpy-all.html` dashboard (the CPython counterpart) = the remaining layer: embed
pytest_shim + runner + test files (already in the VFS since gen_numpy_vfs walks all .py);
ONLY the browser judges. The fail backlog = the real list of bridge bugs to work next.

## Browser dashboard DONE (2026-07-07): test-numpy-all.html
Counterpart of the CPython dashboard, but **a fresh page per module** (iframe
`test-numpy.html?test=<mod>`) — because sharing one context corrupts the wasm core
("memory access out of bounds" after a few modules; in ISOLATION every module
gives stable numbers). The pytest shim is embedded in the VFS
(`gen_numpy_vfs.mjs` adds it + synthesizes the namespace-packages like
`numpy._core.tests` that have no `__init__.py`). `test-numpy.html` = 1-module runner
(prints `ran=/passed=/failed+errored=/skipped=` + `=== done ===` which the dashboard
parses). Curated list = 26 modules of the pytest-portable subset (no random/ctypes/mmap/
zoneinfo/_simd/hypothesis). **Measured isolated result: 1394 pass / 1911 runnable (73%),
517 fail, 22 skip, 4/26 green, 0 import-fail, no hang.** The big fails = real bridge
holes (backlog): test_scalar_methods 113/118, test_dlpack 17/78, test_defchararray 9/90,
test_finfo 0/30 (shim hole = `request` fixture), test_half 11/28. ONLY the browser judges
the rendering; validated node-side through the REAL VFS path (scratchpad harness testnpvfs.mjs).

## `ufunc->type_resolver()` wall FALLEN (2026-07-07, tip 98fe2d7)
`np.true_divide(50,100)`/`np.divide(50,100)` on int scalars raised `RuntimeError: Only
NumPy must call ufunc->type_resolver()` (add/mul/floor_divide OK — division has a custom
legacy type_resolver). Root: at import numpy caches division's type-tuple via
`PyTuple_Pack(3, float64_descr×3)`, but the descr singleton is NOT yet a bridge handle
at that moment (`_cType` not yet populated) → `unwrap`=null → cached tuple `[null,null,null]`
→ later the legacy resolver receives NULLs → `PyArray_DescrCheck(NULL)` fails. Bridge fix:
`PyTuple_Pack` keeps a lazy proxy `{__wasthon_ptr__}` when a non-null pointer does not yet
resolve; `PyTuple_GetItem` re-wraps it and at read time the pointer resolves the real descr.
Debugged by tracing PyType_IsSubtype/PyTuple_CheckExact/PyTuple_SetItem then handles.set(113)
→ `_PyTuple_Pack` at import. Impact: scalar true_divide/divide OK (a FUNDAMENTAL op),
percentile advances (then hits numpy.ma), test_mixins 9→10; 4 ports green, 0 regression.

## C-method introspection RESTORED (2026-07-07): add_docstring
Lever found while digging "why does numpy test introspection so heavily": it is
NOT frivolous. numpy's C methods have `ml_doc = NULL` in the source; numpy attaches
docstrings + **argument-clinic signatures** at runtime at import via `add_docstring(obj, doc)`
(`_add_newdocs.py`, helper `_array_method_doc` that prefixes `$self`). It is a real contract:
`inspect.signature`, `help()`, IDEs, Sphinx, type-checkers + scalar↔array API parity
(`np.float64.tolist` must have the same signature as `np.ndarray.tolist`). The wasthon recipe
**no-op'd `arr_add_docstring`** (the C impl writes `tp_doc`/`m_ml->ml_doc` = OOB on our handles),
silently dropping all the C signatures/docs. Fix (2 separate commits): (1) RECIPE
`arr_add_docstring` parses its args then calls `wasthon_set_docstring(obj, docstr)` instead of
the no-op; (2) BRIDGE `wasthon_set_docstring` sets `obj.__doc__` + parses `"<name>($self,…)\n--\n\n"`
into `obj.$text_signature` (read by Brython's `inspect._signature_fromstr`). Result:
`inspect.signature(np.generic.view)` → `(self, /, *args, **kwargs)`; **test_scalar_methods
113→207 (−94 fails)**. ⚠ `help()`/`__doc__` remains incomplete: `method_descriptor.__doc___get`
is a Brython stub + `__doc__` missing from its `tp_getset` → getattr falls back to `object.__doc__`;
a vendored fix is possible (getter + add `__doc__` to the tp_getset) but the blast radius is wide, deferred.
Debugged: `np.generic.view.__doc__` = `object`'s doc → `ml_doc=NULL` in scalartypes.c.src →
`add_docstring` no-op confirmed. Recompile compiled_base.o (GEN=scratchpad/npgen).

## np.from_dlpack REPAIRED (2026-07-07): PyCapsule_IsValid by name
Same family as the `PyCapsule_CheckExact` fix. `np.from_dlpack(arr)` raised `BufferError:
exported DLPack major version too high`. numpy distinguishes the versioned vs unversioned
DLPack capsule SOLELY by its name (`PyCapsule_IsValid(cap, VERSIONED_NAME)`); but the bridge
had a permissive stub (`cap ? 1 : 0`) ignoring the name → an unversioned capsule read as
`DLManagedTensorVersioned` → `version.major` read at the wrong offset (garbage > 1). Bridge fix:
`PyCapsule_IsValid` only matches a real capsule whose name == the requested name (CPython
semantics: NULL==NULL or strcmp). `np.from_dlpack(np.array([1,2,3]))` → `array([1, 2, 3])`;
**test_dlpack 17→70 (+53)**. Diagnostics: `a.__dlpack__()` returns 'JSObject' (bridge capsule);
message `dlpack.c:639 if (managed->version.major > 1)`, write `dlpack.c:412 major=1`.

## nb_lshift wired (2026-07-07): scalar.as_integer_ratio (float16/32/longdouble)
Root #1 of the remapped "null function" cluster (32 fails). `np.float16(1.5).as_integer_ratio()`
(+ float32/longdouble) crashed `null function`; float64 OK because it is a Brython `float` (skips
the numpy C path). The C `@name@_as_integer_ratio` (scalartypes.c.src:2537) folds `2**exponent` via
`PyLong_Type.tp_as_number->nb_lshift(...)` — but the bridge (`wasthon_long_nb` in wasthon.c) only
wired nb_multiply/nb_floor_divide/nb_power → **nb_lshift NULL**. Added `wasthon_long_nb_lshift`
(int.__lshift__). **test_scalar_methods 207→226 (+19)**. The rest of the 32 "null function" is a
scattered long tail (char radd/repeat, half cast, linspace subclass…), distinct roots.

## getattr on a builtin type-struct SOLVED (2026-07-07): np.strings/np.char
Small harvest fix. `np.strings.upper(arr)` (the `np.char` family) raised `AttributeError:
type object 'str' has no attribute 'upper'`. Root: `_vec_string` (multiarraymodule.c) does
`PyObject_GetAttr((PyObject *)&PyUnicode_Type, method_name)` to fetch `str.upper`, but
`handles[&PyUnicode_Type]` is overwritten after `PyType_Ready` by a bare type-struct wrapper
(named `'str'` but NOT the Brython class `str`, with no method dict) → getattr misses. Bridge fix:
`wasthon_bind_builtin_type` keeps an authoritative reverse map `builtinClassForStruct`
(struct ptr → real Brython class), and `PyObject_GetAttr` redirects there when the target is a
bound builtin type-struct. **test_defchararray 9→11 (+2)**, 0 regressions (4 ports green). Moves
`np.strings.upper` one notch: `str.upper` resolution works, the element call then hits a
2nd-layer "null function" (separate lead, multi-layer — not a harvest).

## PyArg `#` suffix SOLVED (2026-07-07): s#/z#/y#/U#
`np.char.equal(a, b)` (every `np.char`/`np.strings` comparison) raised `SystemError: format
char '#' not implemented`. `compare_chararrays` (multiarraymodule.c:3896) parses
`"OOs#O&:compare_chararrays"`; the legacy varargs parser had no `#` case — it handled
`s`, then choked on `#` as an unknown format. `#` means the buffer code is followed by a
2nd out-pointer receiving the length (`Py_ssize_t`). Bridge fix: `hasHash` detection,
length write (UTF-8 bytes for s#/z#/U# via `PyUnicode_AsUTF8AndSize`, raw bytes for y#
via `PyBytes_AsStringAndSize`), consuming the extra varargs slot, skipping the `#`.
**test_defchararray 11→12 (+1)**; 4 ports 0 fail (re/pickle/decimal/pyexpat). Small gain because
most defchararray comparisons then hit the 2D-subclass-view bug (base@20),
cf. [[wasthon-numpy-2d-subclass-view-base]]; but s#/y#/z# was a real generic hole.

## 2-arg complex ctor SOLVED (2026-07-07): PyObject_CallObject on a builtin type-struct
Same family as the type-struct getattr fix. `np.complex128(1, 2)` raised `TypeError: complex
takes no arguments`; the 1-arg forms `np.complex128(2)` / `np.complex128(1+3j)` worked.
Root: `cdouble_arrtype_new` (scalartypes.c.src:3505) builds the 2-part value via
`PyObject_CallObject((PyObject *)&PyComplex_Type, args)`; but `handles[&PyComplex_Type]` is a
bare `PyType_Ready` wrapper (tp_new/tp_init = `object`'s) → falls to `object.tp_new` →
"takes no arguments" (the 1-arg form never calls `&PyComplex_Type`, hence its success). Bridge
fix: `PyObject_CallObject` AND `PyObject_Call` redirect a builtin type-struct handle
to its real Brython class via the same `builtinClassForStruct` reverse map as
`PyObject_GetAttr`. `np.complex128(1, 2)` → `np.complex128(1+2j)`; **test_scalar_ctors 184→192
(+8)** (the 8 `TestArrayFromScalar.test_complex` arg=(1,2) cases). 4 ports 0 fail, 3 numpy modules
unchanged (umath_complex/scalar_methods/dlpack).

## ndarray __pow__ SOLVED (2026-07-07): the ternary nb_power slot
`np.array([1,2,3]) ** 2` raised `TypeError: unsupported operand type(s) for **: 'ndarray'`
(add/sub/mul/floordiv OK). Root: the heap-types' number-slot installer wired the binary
`nb_*` via `wrapBin`, but `nb_power` (offset 20 of `PyNumberMethods`) is TERNARY
`(a, b, modulo)` — `wrapBin` does not carry the 3rd arg, so `nb_power` was skipped and
`__pow__`/`__rpow__` never landed on `ndarray` (nor any C heap-type). Fix: a `wrapPow`
helper that calls the slot with `modulo = Py_None` for binary `a ** b` (CPython convention;
`array_power` tests `modulo != Py_None`), installs `__pow__`/`__rpow__`. `a**2`/`2**a`/`a**a`,
scalars, complexes OK. **test_umath_complex 323→326, test_half 11→12 (+4)** (measured on the
dashboard, 1571→1583 with the complex ctor). 4 ports 0 fail (decimal exercises nb_power). NB:
test_mixins stays 10/1 — its `forward_binary_methods` fail is a distinct BigInt issue in the
ArrayLike path (`__array_ufunc__`), not pow.
