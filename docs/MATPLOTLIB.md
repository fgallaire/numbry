# matplotlib — feasibility recon (2026-07-07)

**Status: PORTED and deployed (2026-07-12).** `loader/test-matplotlib.html`
renders a real figure (Agg + FreeType text, 480×320) and blits
`buffer_rgba()` onto a canvas, on the deployed site. The build chain is
`mplbuild.sh` (24 objects → `npmpl.mjs`, wired in `build.sh`) +
`gen_mpl_vfs.mjs` (215-module VFS + `window.MPL_DATA` fonts/matplotlibrc) +
`mpl-vfs.patch`/`pyparsing-vfs.patch` (browser fixes to the Python layer).
What the recon below predicted as "the pybind11 wall" fell in three rungs,
all of the same nature — pybind11 casts bridge handles to CPython structs
and reads fields by offset, so the bridge makes those objects *real*:

1. **`PyType_Type.tp_alloc`** hands out raw `PyHeapTypeObject` memory that
   `PyType_Ready` consumes (pybind11's `get_internals()` builds 3 internal
   types by the manual heap-type protocol).
2. **`PyCFunction_NewEx`** returns an actual 24-byte `PyCFunctionObject`
   whose address is the handle (`m_ml`/`m_self` readable by offset), with
   the Brython trampoline bound on top.
3. The `draw_path` table-OOB was **not** pybind11 at all:
   `-DPY_ARRAY_UNIQUE_SYMBOL` was missing, so `NO_IMPORT_ARRAY` translation
   units linked `PyArray_API` with one indirection too many. One shared
   symbol per wasm module fixes it.

Other outcomes vs the recon: **FreeType = emscripten port**
(`-sUSE_FREETYPE=1`), zero vendoring — the assumed-hard piece was trivial;
kiwisolver built with the same pybind11 layer; contourpy/`_tri`/`_qhull`
skipped (optional); Pillow is a stub (import-level only). Pin
**pybind11 == 2.13.6 exactly** — the header seds are calibrated on it.
Bridge-side fixes are logged in wasthon's `CHANGELOG.md` (buffer protocol
for static types, `Py_BuildValue s#/y#`, borrowed exporter views). The
recon below is kept as the original analysis.

---

**Verdict: the most REACHABLE of the high-appeal "hard" libraries. NO Cython, NO
Fortran, NO scipy. Array access goes through the standard numpy C-API the bridge
ALREADY IMPLEMENTS (the `_core` port). The only genuinely new wall = a "pybind11 support
layer", bounded and one-off.** Analyzed target: matplotlib 3.9.2.

---

## Extension surface

- **9 C++ modules**: `_backend_agg`, `_c_internal_utils`, `_image`, `_macosx` (skip), `_path`,
  `_qhull`, `_tkagg` (skip), `_tri`, `_ttconv`. **Zero Cython.**
- **Mixed bindings**:
  - **pybind11** (6): `_c_internal_utils`, `_image_wrapper`, `_path_wrapper`, `_qhull_wrapper`, `_ttconv`, `_tkagg`.
  - **raw C-API** (2): `_backend_agg_wrapper`, `ft2font_wrapper`.
- **Vendored**: `extern/agg24-svn` (the Agg rasterizer, C++), `extern/ttconv`.
- **C dependency**: **FreeType** (`ft2font` — font metrics/rendering).
- **Separate C++ runtime deps**: **contourpy** (contours, pybind11), **kiwisolver** (constraint
  layout, C++), **Pillow** (image I/O, C); + pure Python (fonttools, pyparsing, cycler, dateutil).

## ★ The two big POSITIVES (vs pandas/scipy)

1. **Zero Cython** → no Cython bootstrap, none of the `ob_item`/fast-path wall at all.
2. **Array access = standard numpy C-API.** `src/numpy_cpp.h` reads
   `PyArray_DIMS/STRIDES/BYTES/NDIM(arr)` — **exactly the API the bridge ALREADY provides** for its
   numpy `_core` port (the numpy C core uses it internally). And the bridge's ndarrays have a **real
   `PyArrayObject` + data buffer in linear memory** → matplotlib's C++ reads vertices/pixels
   directly from real memory. That is THE reason matplotlib is tractable where
   scipy (f2py) and pandas (Cython over generic Python objects) are not.

## The one new wall: pybind11 (measured)

Compile-probe of the smallest pybind11 module (`_c_internal_utils.cpp`, 232 l.) against `wasthon.h`:
**100 errors → ~30 DISTINCT items**. Same character as the Cython bootstrap: a bounded batch of
C-API symbols/types/macros `wasthon.h` does not expose, in categories:

| Category | Examples | Effort |
|---|---|---|
| Trivial check macros | `PyInstanceMethod_Check`, `PyWeakref_Check`, `PyAnySet_Check`, `PyFrozenSet_Check`, `PyType_HasFeature`, `PyObject_HasAttr` | one-liners (cousins exist) |
| C-API fns to stub/map | `PyMemoryView_FromBuffer`, `PyCapsule_GetName`, `PyByteArray_FromObject`, `PyStaticMethod_New`, `PyProperty_Type` | bridge (many have cousins) |
| Traceback/frame/code (error cosmetics) | `PyTracebackObject`, `tb_next/tb_frame`, `PyFrame_GetLineNumber`, internal `PyCodeObject` | no-op stubs |
| GIL/tstate (single-threaded WASM) | `Py_tss_t`, `gilstate_counter`, `PyThreadState_New/Clear/DeleteCurrent` | no-op stubs |
| 3.11+ managed dict | `Py_TPFLAGS_MANAGED_DICT`, `PyObject_ClearManagedDict` | flag + stub |

→ One **pybind11 support layer** (compat header + ~15-20 bridge fns/macros) unblocks **ALL**
pybind11 modules: matplotlib's 6 **+ contourpy + kiwisolver** (and any pybind11 library). It is
the analogue of `cython_compat.h` (see `PANDAS.md`).

## FreeType & rendering

- **FreeType**: matplotlib builds a vendored FreeType; emscripten has a FreeType port → buildable.
- **Rendering surface**: two routes:
  - **Raster (Agg)**: `_backend_agg` produces an RGBA buffer → blit onto a `<canvas>`. Max fidelity.
  - **SVG (pure Python)**: `backend_svg.py` writes SVG. **But** it still pulls `_path` (C++,
    also imported by the CORE `transforms.py`) + `ft2font` (text metrics). So "SVG" ≠ zero C++
    — at minimum you need **`_path` + `ft2font` + FreeType**.

## Minimal path to "a figure in the browser"

`_path` (C++/pybind11, transforms/clipping) + `ft2font` (C-API + FreeType, text) +
`_c_internal_utils`, THEN either `_backend_agg`+`_image` (raster→canvas) or the SVG backend.
`_tri`/`_qhull`/contourpy/kiwisolver = extra features (contours, layout) — optional.

## Verdict & recommendation

- **Difficulty: ~★★★☆☆–★★★★☆** (clearly below scipy/sklearn) — **no Fortran, no Cython,
  reuses the already-ported numpy C-API**.
- **Appeal: ★★★★★** — plotting in the browser = a major demo/education feature;
  paired with pandas → a complete "data + charts" stack, without ever touching Fortran.
- **Key new investment = the pybind11 support layer** (+ FreeType + the rendering decision).
- **Next feasibility pass**: build a minimal `pybind11_compat.h` (the ~30 items) and
  push `_c_internal_utils` (the smallest) to a clean `.o` then loaded into the bridge —
  exactly like the `byteswap` pass in `PANDAS.md`. Then `_path` (the core's pivot).

**Strategic position**: after numpy, the highest ROI/appeal duo WITHOUT a Fortran wall =
**pandas (Cython) + matplotlib (pybind11)**. Two "support layers" to write once
(`cython_compat.h`, `pybind11_compat.h`), and a whole slice of the scientific stack opens up.

---
Pointers: `PANDAS.md` (Cython layer + byteswap probe), `SCIPY.md`/`SCIKIT_LEARN.md` (the Fortran
wall, out of matplotlib's scope), `NUMPY.md` (the numpy C-API matplotlib reuses).
