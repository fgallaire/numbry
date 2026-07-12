# HARD BUG — sqlite3 "GC destructor" out-of-bounds wasm-table call, layout-sensitive

**Status: SOLVED (2026-07-11).** Root: a **use-after-free**, not an uninitialised
slot — and the crash was never in the GC destructor path the test name suggests.
`$wasthon_gc_collect`'s mark walks frame locals/globals dicts, but a `with`
statement keeps its context manager in a compiled-JS local (`var mgr_NNN = …`),
invisible to the mark. The test does `with memory_database() as dest: … del dest;
gc.collect()`: the Connection's only remaining reference lived in that JS local,
so the partial GC finalized it — tp_dealloc closed the db and `PyObject_GC_Del`
**freed the struct**. The manager's `__exit__` then called `close()` on the
dangling struct, read a heap-reuse garbage `self->db`, and `sqlite3Close →
sqlite3BtreeEnterAll` called through a garbage function pointer. Whether the
garbage lands in wasm-table range depends on the whole allocation history —
hence the maddening layout-sensitivity (any `wasthon_init` codegen change
flipped it) and the deterministic-per-build behaviour.

Diagnosed by stashing the raw JS stack at Brython's `$B.set_exc` wrap site
(`globalThis.__JSSTACK`) during the full-suite run — the standalone repro never
crashes (fresh heap → the garbage value happens to be in range):
`sqlite3BtreeEnterAll ← sqlite3Close ← connection_close ←
pysqlite_connection_close ← tramp ← __exit__ ← test_function_destructor_via_gc`.
Then confirmed by making `gcFinalize` skip Connections (patching the BUILT
wasthon-full.mjs — JS-only, wasm layout untouched): crash gone.

Fix (src/wasthon.js): conservative finalize — under `gcFinalize` (and only
there; refcount deaths still free), `PyObject_GC_Del` releases resources,
weakrefs and registries but keeps the struct bytes and the ptr→instance
binding. A live reference then operates on the CLOSED object
(`connection_close` is a no-op on `db == NULL` — CPython's semantics for an
explicitly closed connection) instead of dangling memory. Victim struct bytes
are a deliberate bounded leak — the classic conservative-collector trade.
test_sqlite3 473/0 with `PyExc_AssertionError` wired (the 25478c8 layout
band-aid is obsolete; `wasthon_init` can change freely again).

## Symptom
`test_sqlite3.test_userfunctions.FunctionTests.test_function_destructor_via_gc` fails with
`JavascriptError: index out of bounds` (unittest ERROR, not FAILURE) → test_sqlite3 472/1
instead of 473/0. The test registers a user SQL function, drops all references inside a
self-referential list cycle (`y=[x]; y.append(y)`), then `gc_collect()`. The crash is during
collection, in sqlite3's C destructor for the user function.

## What triggered it
The pybind11-support commit **ba03bb2** added one line to the shared `wasthon_init`:
`wasthon_bind_builtin_type(BT_PROPERTY, &PyProperty_Type)`. test_sqlite3 went 473 → 472/1 at
that commit. Every later commit kept it red.

## Diagnosis (definitive, the surprising part)
The property binding is **INERT** to the failure — it is NOT the logical cause:
- Reducing the binding to a complete no-op (skip every map write + struct write, guarded on
  `tag === 26`) → still **472/1**.
- Removing the C call `wasthon_bind_builtin_type(BT_PROPERTY, …)` entirely → **473/0**.
- Re-adding the binding via a *different* path (a tiny `EMSCRIPTEN_KEEPALIVE` accessor
  `wasthon_get_property_type_addr`, never called from init) → **472/1 again**.

So it is **layout-sensitivity**: `"index out of bounds"` is emscripten's message for
`wasmTable.get(i)` with `i` past the table end — i.e. a **call through a garbage/uninitialised
function pointer**. Its value depends on the wasm memory/code layout; ANY change to
`wasthon_init`'s codegen (the bind call, or an unrelated accessor) shifts the layout enough to
move that pointer from "in-range" (works or calls a harmless wrong entry) to "out-of-range"
(throws). It is **deterministic per build** (472/1 ×3, 473/0 ×2), NOT flaky. STACK_SIZE is 4 MB
with `STACK_OVERFLOW_CHECK=2`, so it is not a stack overflow.

The read is in sqlite3's user-function GC-destructor path: `create_function` stores a Python
callable + a C `xDestroy` context; on GC of the connection cycle, sqlite3 frees the function and
calls the destructor, which Py_DECREFs the callable. Somewhere on that path a function pointer is
read from an uninitialised struct field and called through the table.

## Bisection trap (cost an hour)
`build.sh` recompiles `build/wasthon.o` correctly (absolute `-I ${SRC}`), but a MANUAL
`emcc -c -I ../src` under `build/` (the wasthon3 symlink) silently uses the STALE wasthon3
headers and leaves wasthon.o unchanged — so early "results" were from a stale binary. Always
verify the change landed: `grep -c 'tag===26' build/wasthon-full.mjs` (emscripten strips the
comments from the js-library but keeps the code).

## Current fix (band-aid) = commit 25478c8
Removed the `wasthon_bind_builtin_type(BT_PROPERTY, …)` call from `wasthon_init`. Nothing in the
CPython bundle uses `property ↔ &PyProperty_Type`; it existed only for pybind11 (matplotlib, a
separate module blocked further down). test_sqlite3 back to 473/0, sentinels intact. The global
`PyProperty_Type` + extern + `case 26` + `PyCapsule_GetName/SetPointer` + `PyCFunction_NewEx`
stay (matplotlib still compiles).

## Leads for the REAL fix
- Instrument the sqlite3 destructor path: recompile `Modules/_sqlite/connection.c` with a printf
  at the xDestroy/`_destructor`/`set_callback_context` sites, relink the bundle, and log the
  function-pointer value that ends up out of range. Compare a "good" vs "bad" layout to see which
  field is uninitialised.
- Suspect the bridge's GC/dealloc reading `type->tp_dealloc`/`tp_free`/a weakref-callback slot
  from a struct that wasthon under-fills (the ndarray under-allocation pattern below, but for a
  sqlite3 object). Check `wasthon_object_gc_new` sizing for the sqlite3 Connection/Cursor/Function
  structs and whether the destructor slot is zeroed.
- Reproduce in the browser (node has no _sqlite3 harness): the JS stack is logged by
  `brython.js` at the `console.log('Javascript error', js_exc); console.log(js_exc.stack)` site —
  patch it to stash `js_exc.stack` in `globalThis.__JSSTACK` and read it via selenium (the
  earlier capture missed it; make sure the throw goes through THAT path, not the exec-catch at
  brython.js:5572 which only logs `'JS error'`).
- When matplotlib resumes: re-establish `property ↔ &PyProperty_Type` for pybind11 WITHOUT
  touching `wasthon_init` (a layout-neutral path — e.g. resolve it lazily in `PyType_Ready` off a
  value pybind11 already provides), or fix the uninitialised-pointer read so layout no longer
  matters.

Memory pointer: `wasthon-matplotlib-port` (the regression note), `wasthon-stack-vs-dealloc-lesson`
("index out of bounds" ⇒ suspect layout/stack/dealloc first).

---

# HARD BUG — `arr.view(<subclass>)` corrupts `base` for ndim ≥ 2

**Status: SOLVED (2026-07-09).** Root: NOT a stray write — an **under-allocation**.
For a Brython subclass of a C type, `tp_alloc` dispatches through an `ensureTypeStruct`
handle whose `rt.types` entry carries **no `basicsize`**, so `wasthon_object_gc_new` did
`_malloc(undefined)` → a minimal ~16-byte chunk instead of the 44-byte
`PyArrayObject_fields`. numpy's next malloc — the `npy_alloc_cache_dim` dims/strides
block — was placed at `fa+16`, INSIDE the struct: for a 2-D view, `dims[1]` landed on
`base` (offset 20). **The "0x2 = True-handle" below was a red herring: it was `dims[1]`
of a (2,2) array.** 1-D views survived because the 8-byte overlap covered exactly the
dims/strides *fields*. Diagnosed by printing `fa / subtype->tp_basicsize / fa->dimensions`
in `PyArray_NewFromDescr_int`: subclass showed `bs=0, dims=fa+16`; base type `bs=44,
dims=fa+48`. Fix: `wasthon_object_gc_new`/`_var` inherit `tp_basicsize` from the first
C ancestor in the MRO (CPython subtyping semantics), cached into the registry entry —
type identity (the scoped decimal subtype-struct path) untouched. test_defchararray
12→60 passed. Original dossier kept below for the record.

## Symptom
Viewing a **multi-dimensional (ndim ≥ 2)** array as **any subclass** of `ndarray` raises:

```
ValueError: Cannot set the NumPy array 'base' dependency more than once
```

- 1-D `.view(subclass)` → **OK**
- 2-D `.view(np.ndarray)` (base type, not a subclass) → **OK**
- 2-D `.view(<any subclass>)` → **FAILS** (pure-python `Sub`, `chararray`, `recarray`,
  masked arrays, unit libraries…). **General**, not chararray-specific.

## Impact
- **66 fails in `numpy._core.tests.test_defchararray`** (its `A()`/`array()` helpers do
  `np.array([[...],[...]]).view(np.char.chararray)` on 2-D data).
- Contributes to every subclass-heavy multi-dim path (matrixlib, masked arrays, etc.).

## Minimal reproduction
```python
import numpy as np
class Sub(np.ndarray): pass
np.array([['a', 'b'], ['c', 'd']]).view(Sub)          # FAILS
np.array(['abc', 'de']).view(Sub)                     # OK (1-D)
np.array([['a', 'b'], ['c', 'd']]).view(np.ndarray)   # OK (base type)
```
Original test path: `defchararray.py:1364` (`return val.view(chararray)`), reached from
`test_defchararray.py` `TestComparisons.A()` etc.

## Diagnosis (definitive)
Instrumented `PyArray_SetBaseObject` (`numpy/_core/src/multiarray/arrayobject.c:154`) with a
`printf`, recompiled `arrayobject.o`, relinked. For a **2-D** subclass view, `SetBaseObject`
is called **three times on the SAME array**, same `obj`, with `nd` = 1, 1, 2:

```
[SB] arr=0x130530 nd=1 base=0    rawbase@20=0    rawnd@8=1 obj=0x1304d0 sizeof=44 offbase=20
[SB] arr=0x130530 nd=1 base=0    rawbase@20=0    rawnd@8=1 obj=0x1304d0 sizeof=44 offbase=20
[SB] arr=0x130530 nd=2 base=0x2  rawbase@20=0x2  rawnd@8=2 obj=0x1304d0 sizeof=44 offbase=20
```

Reading:
1. Call 1: `base==0` → writes `obj` (0x1304d0) to `arr->base` (arrayobject.c:221
   `((PyArrayObject_fields *)arr)->base = obj;`).
2. Call 2: `base==0` again — so between call 1 and 2 numpy **reset base to 0** (normal
   reconfiguration), and re-writes obj.
3. Call 3: the array is now `nd==2` (reshaped 1-D→2-D), and `base` (offset 20) reads **`0x2`**
   → the "already set" guard trips → error.

Key facts:
- `PyArray_BASE(arr)` reads offset 20 correctly (`rawbase@20` = raw `*(void**)(arr+20)` = same `0x2`).
- `sizeof(PyArrayObject_fields) == 44`, `offsetof(base) == 20`.
- **Bridge `basicsize` for `ndarray` == 44 — the allocation is the correct size** (not
  under-allocated). `wasthon_object_gc_new` zeroes it, so `base` starts at 0.
- **`0x2` = bridge handle 2 = the `True` sentinel (`SLOT_TRUE`).** So a **bridge handle leaks
  into the C struct at `arr+20`** during the 1-D→2-D reconfiguration.

⇒ This is a **memory corruption**: some write intended elsewhere (a wrapped handle, `0x2`)
lands on the `base` field. NOT a wrong offset and NOT an undersized allocation.

## PyArrayObject_fields layout (measured, compiled with numpy's own headers + wasthon.h)
```
offset  4  data
offset  8  nd            (int)
offset 12  dimensions    (npy_intp *)
offset 16  strides       (npy_intp *)
offset 20  base          (PyObject *)   ← corrupted with 0x2
offset 24  descr
offset 28  flags         (int)
offset 32  weakreflist
offset 36  _buffer_info
offset 40  mem_handler
sizeof = 44
```
(Head is 4 bytes = `ob_refcnt` only; wasthon's PyObject has NO `ob_type` slot.)

## Leads for the next attempt
- `0x2` is a bridge sentinel handle → find where a **handle** gets written into the ndarray
  struct at offset 20 during the **1-D→2-D reshape** of the view.
- Suspect the **dims/strides allocation** on reshape: numpy normally does
  `fa->dimensions = npy_alloc_cache_dim(2*nd)` **separately** — verify the bridge doesn't
  route it inline / overwrite the struct. Also check `__array_finalize__` /
  `PyArray_UpdateFlags` on the 2-D view writing a wrapped value.
- Instrument by tracing **every write to `arr+20`** between call 2 and call 3 (e.g. a guard
  page / a write-watch, or add prints around dims/strides assignment in `ctors.c`
  `PyArray_NewFromDescr_int` and the reshape path).
- Compare the working 2-D `.view(np.ndarray)` path vs the failing subclass path — the delta is
  the extra `__array_finalize__` + the subclass `tp_alloc`.

## Build recipe (to reproduce / instrument)
```sh
# recompile one numpy .o (GEN = scratchpad/npgen, flags from numpy-probe/probe.sh):
SP=<scratchpad>; NP=$SP/numpy-2.5.1; SRC=~/wasthon4/src; GEN=$SP/npgen
emcc -O1 -c -DNDEBUG -DNPY_INTERNAL_BUILD -DHAVE_NPY_CONFIG_H -D_FILE_OFFSET_BITS=64 \
  -I "$SRC" -I "$GEN" -I "$NP/numpy/_core/src/common" -I "$NP/numpy/_core/src/multiarray" \
  -I "$NP/numpy/_core/src/umath" -I "$NP/numpy/_core/src/npymath" \
  -I "$NP/numpy/_core/src/npysort" -I "$NP/numpy/_core/src/multiarray/stringdtype" \
  -I "$NP/numpy/_core/src/highway" -I "$NP/numpy/_core/include" -I "$NP/numpy/_core/include/numpy" \
  "$NP/numpy/_core/src/multiarray/arrayobject.c" -o "$SP/npobj2/arrayobject.o"
# relink:
emcc -O1 "$SP"/npobj2/*.o ~/wasthon4/build/wasthon.o --js-library ~/wasthon4/src/wasthon.js \
  -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 \
  -s EXPORTED_FUNCTIONS='["_PyInit__multiarray_umath","_wasthon_init","_wasthon_module_create","_malloc","_free"]' \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=numpy_probe -o "$SP"/npprobe.mjs
# run: node <scratchpad>/prun.mjs <a .py file that does the 2-D subclass view>
```

Memory pointer: `wasthon-numpy-2d-subclass-view-base`.

---

# PAIRED BUG — dlpack read-only import needed BOTH a kwargs fix AND a Py_BuildValue fix

**Status: SOLVED (2026-07-09).** `np.from_dlpack(writable_array)` returned a **read-only**
array (the "assignment destination is read-only" family). Two roots, landed together:

1. **`PyObject_VectorcallMethod` dropped all kwnames** (src/wasthon.js) — it only forwarded
   positional args. numpy's `from_dlpack` calls `obj.__dlpack__(max_version=(1,0), …)` via
   VectorcallMethod; the kwarg was lost → `array_dlpack` saw `max_version=None` → built an
   **unversioned** capsule → `from_dlpack` unversioned path forces `readonly=1`. Fix: mirror
   `PyObject_Vectorcall`'s `{$kw:[kwMap]}` handling.
2. **`Py_BuildValue` pushed group separators as elements** (src/wasthon.js). The 07-07 lead
   "array_dlpack(versioned=1) returns NULL between malloc and fill" was a **red herring** —
   the versioned export path in dlpack.c is fine (proved by a direct Python-side
   `x.__dlpack__(max_version=(1,0))`, which builds a `dltensor_versioned` capsule). The real
   root: `readOne` returns `[null, i+1]` for `','`/`' '`/`':'`, the top-level loop filters the
   nulls but the `(`/`[`/`{` group loop did `items.push(r[0])` unfiltered → numpy's static
   `dl_max_version = Py_BuildValue("(i,i)", 1, 0)` (npy_static_data.c:212) came out as the
   3-tuple `(1, <JS null>, 0)` → `array_dlpack`'s "tuple with two elements" check raised
   TypeError → `from_dlpack`'s `except TypeError` fallback retried WITHOUT kwargs →
   unversioned → read-only. Same corruption hit `dl_cpu_device_tuple` ("(i,i)" too, breaking
   `from_dlpack(x, device="cpu")`), and a `':'` inside `{…}` would shift every key/value pair.
   Fix: filter nulls in the group loop like the top-level loop does.

Diagnosis path that cracked it: printf bisection in an instrumented dlpack.c showed
`[ARRDL] mv tuple check FAILED: check=1 size=3`, then `dbg_repr(max_version)` printed the
smoking `(1, <Javascript null>, 0)`. **Repr the operand, don't theorize about the branch.**

---

# SOLVED — `np.arange(np.float16(x))` : "arange: cannot compute length" (2026-07-09)

Root exactly as the lead suspected, narrowed to ONE function: the bridge's
`PyNumber_Subtract` was the single binary op still on the initial-commit numeric fast path —
it coerced non-number operands with `Number(obj)`, so a numpy scalar (C-struct-backed, no
`.value`) became **NaN**; `_calc_length`'s `stop - start` (C-API) fed ceil(NaN) → bail.
`PyNumber_TrueDivide` was innocent (already `rich_op1('__truediv__')`, like every other
`PyNumber_*`). Fix: `rich_op1('__sub__')`. numpy dashboard +19; numeric sweep
(math/cmath/statistics/json + 4 ports) 0 fails.

---

# SOLVED — `Cls.method` on a spec/cdef type yields the unbound `cython_function_or_method` (2026-07-09)

Was: class-level access on a cdef class (`getattr(MT19937, 'random_raw')`) returned a bound
Brython `method` — no settable `__module__` (numpy.random's mtrand repr-cosmetics loop crashed
its module init; worked around by deleting the loop at the source), wrong self on unbound
`Cls.method(inst, …)` calls.

**Root — ONE line in the wired `Py_tp_descr_get` wrapper** (src/wasthon.js,
PyType_FromModuleAndSpec). Brython's `type.tp_getattro` does the RIGHT thing (passes `$B.NULL`
or None for class access), but the wrapper converted that to a real handle
(`rt.wrap(None)` ≠ 0). Cython's `__Pyx_PyMethod_New(func, self, typ)` tests `if (!self)
return func` — non-NULL → `PyMethod_New(func, None)` → the bridge built the Brython `method`.
CPython's `wrap_descr_get` maps None → C NULL before calling the slot; the wrapper now does the
same (`$B.NULL`/None/undefined → 0). The 07-08 diagnosis was misled twice: the logged
"obj = the class itself" came from a different (instance-getattr fallback) call site, and the
"experimental objH change was ineffective" because it special-cased the class marker instead of
the `$B.NULL`/None sentinels that actually arrive.

`MT19937.random_raw` → raw `cython_function_or_method`, `__module__` readable AND settable
(the mtrand cosmetic loop would now run — the build-time patch in `cython-support/nprnd.sh`
can be retired next time the recipe is touched), `MT19937.random_raw(MT19937(5), 2)` returns
the right uint64s, instance access still binds. Dashboard stable, 4 ports green, smoke 38/38.

---

# CLOSED — a failing Cython `Py_mod_exec` reports "returned -1 without setting an exception"

**Status: no longer reproduces (2026-07-09).** Re-tested with a pendingException write-trap
(`Object.defineProperty` setter logging every transition + stack) on a fresh failing exec
(re-creating `_generator` with `numpy.random.bit_generator` evicted): at `__pyx_L1_error`
`PyErr_Occurred()==1`, `__Pyx_AddTraceback`'s `PyErr_Fetch`/`PyErr_Restore` pair brackets
cleanly, and `wasthon_module_create` returns 0 **with the pending exception intact** — the
real error (ModuleNotFoundError) surfaces. The 07-08 desync was almost certainly
`__Pyx_AddTraceback` dying mid-flight between Fetch and Restore on the then-broken
`PyCode_NewEmpty` (fixed by the `call returned NULL` root fix) — the fetched exception was
never restored. The historical trigger (mtrand's `method.__module__` loop) is also gone
(`Cls.method` descr_get fix): **mtrand now builds and inits with the UPSTREAM VERBATIM
cosmetics loop — the `nprnd.sh` source patch is retired** (`RandomState.random.__module__`
== 'numpy.random', seed-42 sample bit-exact, smoke 38/38).

Residual cosmetic note (harness-only): `PyErr_Restore` stores `msg = String(obj)` which
prints as `[object Object]` in pv.mjs' `pe.msg` console line; the surfaced exception itself
is correct (the instance is preserved via `setError`'s third arg).

## Symptom
When a Cython C module's `Py_mod_exec` slot returns -1, `wasthon_module_create` raises
`SystemError: module exec slot returned -1 without setting an exception`
(src/wasthon.js ~12481: `if (rc !== 0) { if (!rt.pendingException) setError(...); }`), even
though the module **did** set a Python exception.

## Diagnosis
Instrumented the exec's `__pyx_L1_error:` label (printf): at the error label
`PyErr_Occurred() == 1` (a C-level exception IS set), yet by the time the bridge checks after the
exec returns, `rt.pendingException == null`. So the **C-level PyErr and the bridge's
`rt.pendingException` are desynced** — one of the exec's cleanup steps between the failing
statement and the return clears `rt.pendingException`:
`__Pyx_XDECREF` of temporaries, `__Pyx_AddTraceback("init …")`, or `Py_CLEAR(__pyx_m)`.
Result: the real error (a `ModuleNotFoundError` for a relative import, an `AttributeError` in a
repr loop, …) is swallowed and one must add `printf("%d", __pyx_lineno)` per module to find the
failing `.pyx` line.

## Impact
Every numpy.random Cython module bring-up (`_generator`, `mtrand`, …) required instrumenting the
generated `.c` by hand to discover the failing line — slow. A real per-module blocker to
diagnosability, not correctness.

## Leads for the next attempt
- Make `wasthon_module_create`, on `rc != 0`, read the **C-level** exception (whatever store
  `PyErr_Occurred()` consults) rather than only `rt.pendingException`, and surface that.
- OR find why `PyErr_Occurred() == 1` while `rt.pendingException == null` — they should be the
  same store; check whether `__Pyx_AddTraceback` / `Py_CLEAR(__pyx_m)` / a `PyErr_Clear` on the
  bridge side wipes `rt.pendingException` but not the C flag (or vice-versa).
- Cross-check the `except`-match failure above: Cython's `__Pyx_PyErr_ExceptionMatches` reads the
  same exception state, so a desync there is the likely reason a genuine `AttributeError` didn't
  match `except (AttributeError, TypeError)`.


# SOLVED — `np.dtype(bool/float/complex)` → real dtypes: the PyFloat_FromString lock is broken (2026-07-09)

**Status: SOLVED.** The dossier's reopening plan worked exactly as written: probe the
_json fast path FIRST, nail `PyFloat_FromString`'s real argument, fix it, THEN unify.
The argument was **bytes** after all — but a C-ALLOCATED bytes
(`PyBytes_FromStringAndSize(NULL, n)` placeholder that C memcpy'd into): its Brython
`.source` was still the BLANK placeholder, which is why the 07-08 "decode .source"
attempt didn't fire and the error mutated to `could not convert string to float: '    '`.
Fix: `PyFloat_FromString` accepts bytes/bytearray (CPython contract) reading the
linear-memory buffer (`__wasthon_cstr__`) FIRST, `.source` otherwise. With that,
`bool/float/complex` joined the `canon` list in `ensureTypeStruct`: test_json 170/0
(the historical −6 erased), test_pickle 941/0 (the historical browser timeout does not
reproduce — likely killed by one of the day's fixes), 8-suite numeric sweep 0 fails.
`np.dtype(bool/float/complex)` → `bool/float64/complex128`, `g.integers(dtype=bool)`
works, `np.dtype(bool) == np.bool_` is True. Original dossier below for the record.

## Symptom
`np.dtype(bool)` / `np.dtype(float)` / `np.dtype(complex)` return `dtype('O')` (object) instead of
`dtype('bool')` / `dtype('float64')` / `dtype('complex128')`. `np.dtype(int)` is correct; numpy
scalar types (`np.bool_`) and dtype strings (`'bool'`, `'?'`) are correct. Downstream:
`g.integers(0,2,5,dtype=bool)` → `TypeError: Unsupported dtype dtype('O') for integers`, and any
`np.array(x, dtype=float)` with the Python builtin type resolves to object.

## Root
numpy's descriptor resolution compares the passed type object against the C globals `&PyBool_Type` /
`&PyFloat_Type` / `&PyComplex_Type` by pointer identity. In the bridge, `ensureTypeStruct`
(src/wasthon.js ~873) unifies ONLY `int` (+ None/ellipsis/NotImplemented) with its canonical bound
struct, so `wrap(int) == &PyLong_Type` and numpy recognizes it. `bool`/`float`/`complex` get a FRESH
per-class struct handle ≠ their canonical global → `typ == &PyFloat_Type` fails → object dtype. The
int-only scoping is DELIBERATE (the code comment notes unifying str/bytes/containers regressed pickle).

## The fix that "works" (but must not ship as-is)
Add `bool`/`float`/`complex` to the `canon` list in `ensureTypeStruct`. Then `np.dtype(bool/float/
complex)` resolve correctly, `np.zeros(3,dtype=bool)` gives a real bool array, `np.dtype(bool)==np.bool_`
is True. **Measured numpy.random gain: only +2** (dashboard 1016→1018) — the random suite uses numpy
scalar dtypes, not Python builtins, so the payoff on the target suite is tiny.

## Why REVERTED — regresses _json (−6) AND _pickle (browser timeout)
Unifying `float` makes `wrap(float) == &PyFloat_Type`. numpy is happy, but _json's C number scanner does
`if (s->parse_float != (PyObject*)&PyFloat_Type) CallOneArg(parse_float, numstr); else PyFloat_FromString(numstr);`.
- BEFORE: `parse_float` (= `wrap(float)`) ≠ `&PyFloat_Type` → `float(numstr)` via Brython → worked.
- AFTER: `parse_float` == `&PyFloat_Type` → the scanner takes the `PyFloat_FromString(numstr)` branch, and
  the bridge's `PyFloat_FromString` (src/wasthon.js ~3713) raised `TypeError: PyFloat_FromString: not a str`.
→ **test_json 170→164 (−6)**: `test_floats`, `test_dict_values`, `test_list`, `test_out_of_range`,
`test_parse` (TestCEnum/TestCFloat/TestCPass1). And **test_pickle TIMED OUT in the browser** — a run
that normally completes — because unpickled float/int reconstruction hits the same
`&PyFloat_Type`/`&PyLong_Type` C-paths. Net: +2 numpy.random for −6 json plus a pickle timeout → REVERTED.

## Leads for a real fix (if ever revisited)
- The blocker is NOT the dtype unification itself but that _json/_pickle then take the
  `PyFloat_FromString` / `&PyFloat_Type`-as-callable C-paths the bridge under-serves. Fix
  `PyFloat_FromString` to accept whatever _json passes on that branch BEFORE unifying `float`.
  The arg type was NOT nailed: the `bytes`/`.source`-decode hypothesis was wrong (it didn't fire),
  and a DIAG-message rebuild + full `test_json` run (~158s/iteration) was too slow/inconclusive.
  NEXT: instrument `PyFloat_FromString` to log `class_name(arg)` + `typeof`, and drive it from a FAST
  targeted probe (`json.loads('[1.5]')`) — do NOT iterate on the 208-test suite.
- Then sweep BOTH `_json` and `_pickle` (each regresses on core-type identity changes — cf. memory
  rule "sweep numeric suites on core-type change") BEFORE re-adding anything to `canon`.
- `bool` and `complex` alone may be safe (the observed regression is float-specific, via
  `PyFloat_FromString`), but they were never measured in isolation from `float`.

## Reproduction
Fix: in `ensureTypeStruct` (src/wasthon.js ~873) add `cls === this._b_.bool || cls === this._b_.float
|| cls === this._b_.complex` to the `canon` condition; relink `build/nprnd.mjs` (scratchpad linkall)
for numpy, and `./build.sh wasthon-full` for the CPython bundle. numpy check: `np.dtype(bool)` →
`dtype('bool')`. Regression check: `driver-par.py test_json test_pickle` → json −6, pickle timeout.
The reverse of the numpy.random exception-propagation win (commit 5b8169d, PyCode_NewEmpty) is
unrelated and stays committed; only this `ensureTypeStruct` change was backed out.


# BRIDGE GAP — `np.bytes_` scalars from S arrays are empty shells (no Brython backing)

**Status: SOLVED (2026-07-09), two roots in one.** (1) `PyType_Ready` resolved a builtin-struct
`tp_base` into a HOLLOW class materialized from `tp_name` — the mro printed `[bytes_, bytes,
object]` but `mro[1] is bytes` was False (impostor), so isinstance and method lookup failed;
fixed by consulting `builtinClassForStruct` first. (2) `PyBytes_AsString` on the var-object
shell read `(obj.source || obj).length` = undefined → `_malloc(NaN)` → PyArray_Scalar memcpy'd
the payload into a ~0-byte chunk (heap scribble + payload lost, hence `np.bytes_(b'')`); fixed
by handing C an `ob_size`-byte buffer and materializing `.source` lazily on first access.
Original dossier below.

## Symptom
```python
a = np.array([b'ab', b'cd'])
e = a[0]          # type np.bytes_ — but repr is np.bytes_(b'') : EMPTY
len(e)            # TypeError: object of type 'bytes_' has no len()
e.upper()         # AttributeError: 'bytes_' object has no attribute 'upper'
bytes(e)          # TypeError: cannot convert 'bytes_' object to bytes
np.strings.upper(np.array([b'ab']))  # dies in Brython bytes.upper: self.source undefined
```
U arrays are fine (their elements come back as plain str via the wired
`PyUnicode_Type.tp_new` / getitem paths).

## Diagnosis
`PyArray_Scalar` (scalarapi.c) builds flexible-dtype scalars via
`type->tp_alloc(type, itemsize)` + memcpy into `PyBytes_AS_STRING(u)` (the C struct's
inline `ob_sval`). On the bridge, tp_alloc = `wasthon_object_gc_new_var` → a C struct
plus a Brython instance SHELL (`__wasthon_ptr__` only) — the bytes payload lives in
linear memory, but the Brython side has **no `.source`**, so every Brython bytes method
(`len`, `upper`, `__bytes__`…) reads `self.source` → undefined.

## Leads
- Materialize `.source` when a var-instance's class inherits from `bytes`: read
  `ob_size` and the inline `ob_sval` from the struct (wasthon.h PyBytesObject layout)
  at bind time — or lazily on first unwrap (cheap: scalar sizes are tiny).
- Symmetric check for `str_` subclass shells if any path constructs them via tp_alloc
  rather than the (now wired) tp_new.
- Trace: `_vec_string` → `_PyObject_CallFunctionObjArgs(bytes.upper, elem)` →
  brython.js:7104 `self.source.length`.

---

# CHAIN — pickling numpy.random / dtypes: CLOSED (2026-07-10, 7 roots + buffer lifetime)

**Goal cluster:** `cannot pickle 'SeedSequence'` ×4, `PyObject_GetAttrString: 'PickleBuffer'`
×3, `'_DTypeMeta' object is not callable` ×2, plus every test that round-trips a bit
generator / dtype / ndarray through pickle. The chain ran SEVEN distinct roots deep plus a
buffer-lifetime bug on the load side. All closed: `pickle.loads(pickle.dumps(x))` round-trips
ndarray / dtype (incl. structured) / SeedSequence / MT19937 / Generator / numpy scalars at
protocol 2 AND at the 3.14 default protocol 5, with exact data and bit-exact generator state
($SP/pk9.py 12/12 via pv.mjs).

## Fixed (measure by probing `pickle.dumps(x, 2)` in $SP/pk*.py via pv.mjs)
1. **`__Pyx_setup_reduce` aliasing never landed** — its guards compare `PyObject_GetAttr`
   handles by POINTER identity (`cls.__getstate__` vs `object.__getstate__` …), which the
   bridge can't guarantee for inherited attributes, so it silently skipped promoting
   `__reduce_cython__` → `__reduce__`. The bridge now does the aliasing at spec-type method
   install, but ONLY when no ancestor below `object` defines the dunder (MT19937 inherits
   BitGenerator's real `__reduce__` while carrying its own RAISING `__reduce_cython__` —
   blind aliasing shadowed the good one; that guard mirrors setup_reduce's
   `reduce == object_reduce` check).
2. **`Py_BuildValue` had no `'c'` format** — numpy's `array_reduce` builds its args tuple
   with `"ONc"`; the whole BuildValue failed and `PyTuple_SET_ITEM(ret, 1, 0)` stored a JS
   null → "second item of the tuple returned by __reduce__ must be a tuple, not NullType"
   on EVERY ndarray protocol-2 pickle since forever.
3+4. **Metatype instances used object's attribute access** — PyType_Ready and
   FromModuleAndSpec installed `object.tp_getattro` as the default on every class; for a
   METAtype (mro contains `type`) its instances are classes, and class-attribute access must
   walk the CLASS mro (type.tp_getattro). With object's default,
   `Int32DType.__reduce__` bound `object.__reduce__` (via the metaclass) instead of finding
   `dtype.__dict__['__reduce__']` — dtype pickling fell into copyreg and died with
   "Can't pickle <class '_DTypeMeta'>: it's not found as numpy._DTypeMeta".

## Roots 5-7 + buffer lifetime (closed 2026-07-10)
5. **Metatype tp_call** (70fcc56) — DType classes inherit `type.tp_call`; `Int32DType()`
   returns the int32 singleton per `legacy_dtype_default_new`.
6. **The trampoline's subclass-aware reduce swap fired on C-defined classes** — the bridge
   patches `__reduce__`/`__reduce_ex__` results to name the instance's actual class when the
   C reduce names a strict base (needed for BRYTHON subclasses, where Py_TYPE is the parent
   struct). For a dtype instance the "subclass" is `Int32DType` (a C-defined DType) and the
   C reduce names `np.dtype` DELIBERATELY (`arraydescr_reduce`), so the swap corrupted item 0
   into `Int32DType` — whose call with args is TypeError by design. The instrumented GetAttr
   was right all along: the mutation happened AFTER the C returned, in the trampoline result
   pass (the $SP/md7.py mark probe nailed it — the marked object vanished from the tuple).
   Guard: skip the swap when `subcls.__wasthon_type_handle__ === rself.__wasthon_type__`
   (the C side saw the real type, so its choice of callable is deliberate).
7. **`'O!'` inside a `PyArg_ParseTuple` `'(...)'` group** — the group loop read one varargs
   slot per CHARACTER, so the `'!'` of `"(iO!O!iO)"` (numpy's `array_setstate`) was parsed
   as its own integer slot → every ndarray/bit-generator `__setstate__` failed with
   "integer expected in argument 1". The group parser now consumes `'O!'` as one type-checked
   code taking two varargs slots (dtype setstate `"(iOOOOnnk)"` never hit this — 1-char codes
   only).
- **Buffer lifetime (load side, protocol 5)** — `wasthon_get_buffer_data` malloc'd a fresh
  copy per view and `wasthon_buffer_release` freed it, but numpy's `PyArray_FromBuffer`
  releases the view and KEEPS aliasing `view->buf` (the CPython contract: the buffer sticks
  around with the OBJECT). Unpickled protocol-5 arrays aliased freed memory and came back as
  heap garbage. The copy is now cached on the supplying object (`__wasthon_bufptr__`, same
  model as `__wasthon_cstr__`) and marked object-owned so release skips the free.
- **PEP 688 `__buffer__` for C buffer types** — Brython's memoryview factory delegates to
  `__buffer__` when the type has no native buffer path; PyType_Ready now installs one
  (method_descriptor in the class dict) on any C type with `tp_as_buffer`, so
  `memoryview(ndarray)` works — that is what `pickle.py`'s `save_picklebuffer` reads for the
  in-band protocol-5 bytes. Writable buffers cross as bytearray so they round-trip writable.
- **`pickle.PickleBuffer` fallback (VENDORED, brython_stdlib.js)** — Brython's pickle.py had
  the full pure-python PickleBuffer machinery but `from _pickle import PickleBuffer` fails on
  pages that don't load the C _pickle (the numpy dashboard pages). A minimal pure-Python
  fallback class (obj + raw()/release()/__buffer__) now sets `_HAVE_PICKLE_BUFFER=True`.

## (was) Lock 2 — DType classes are not callable (`Int32DType('i4', False, True)`)
The protocol-2 LOADS path reconstructs a dtype by CALLING its DType class; Brython's `$call`
looks for `get_class(Int32DType).tp_call` = `_DTypeMeta.tp_call` (JS slot) — absent.
`'__call__' in _DTypeMeta.__dict__` is False, so the PyType_Ready tp_call@100 wiring did NOT
run for `PyArrayDTypeMeta_Type` (it is materialized through the phase-3 `_cType` side-table
path, not the standard ready loop). Wire `dtypemeta_call` (its static struct's tp_call) as
`_DTypeMeta.tp_call`/`__call__` the same way the ready path does, or route the side-table
types through the same slot-wiring. Signature in the dashboard: `'_DTypeMeta' object is not
callable` ×2 — flips those plus every pickle ROUND-TRIP (loads) of arrays/dtypes/generators
at protocol 2.
