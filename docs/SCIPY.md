# SciPy — feasibility recon: THE wall (2026-07-07)

**Verdict: SciPy is the ★★★★★ of the stack. The route EXISTS (f2c for the F77 + supplying
LAPACK/BLAS + emcc for C/C++ + the Cython support layer) and Pyodide proves it is buildable —
but it is a MASSIVE toolchain project, and it is the point where wasthon's bridge architecture
is structurally at a disadvantage against Pyodide.** Analyzed target: scipy 1.14.1.

---

## Surface (measured, excluding `/tests/`)

| Language | Files | Note |
|---|---:|---|
| **Fortran** | **463** (**165,301 lines**) | **460 in F77** (f2c-able) / **3 in F90** |
| f2py `.pyf` | 34 | interfaces — including **external** BLAS/LAPACK wrappers |
| Cython `.pyx` | 62 | + the bridge's memory-layout wall |
| C | 425 | emscripten OK |
| C++ | 1417 | 1377 in `_lib` (boost_math, HiGHS, pocketfft, unuran) |

## The Fortran wall, package by package (all F77 → f2c-able)

| Subsystem | Fortran | Package |
|---|---:|---|
| scipy.sparse | 244 | **ARPACK** (80, eigenvalues) + SuperLU |
| scipy.interpolate | 86 | **FITPACK** (Dierckx splines) |
| scipy.integrate | 56 | **QUADPACK** (35) + **ODEPACK** (17) |
| scipy.linalg | 36 | wrappers + helpers |
| scipy.optimize | 31 | **minpack** (25), lbfgsb, slsqp, cobyla |
| scipy.odr | 5 | ODRPACK |

★ **99.4% of SciPy's own Fortran is F77** (460 vs 3 F90). F77 is **translatable to C
with `f2c`** (the route historically used by Pyodide). Only 3 F90 files need anything else.

## The HIDDEN dependency: external BLAS/LAPACK

The `linalg/flapack*.pyf.src`, `fblas*.pyf.src`, `clapack.pyf.src` wrappers do NOT contain
LAPACK — they **wrap BLAS/LAPACK symbols the build links from outside**. So on top of
the 165k own lines, you must **supply a BLAS + a LAPACK to WASM** (another ~1.5–2M lines
of F77). Options: **CLAPACK** (LAPACK already f2c'd to C — it exists) or an OpenBLAS/refLAPACK built for WASM.

## Vendored C++ (volume, not a wall)

`boost_math` (special functions), **HiGHS** (the linprog solver, big C++), **pocketfft** (FFT),
`unuran`, `qhull` (spatial). emscripten handles C++ → it is compile volume, not a blocker.

## Why this is THE hard point for wasthon (≠ Pyodide)

- **Pyodide ships SciPy as WASM** → build + Fortran = **solved** (f2c of the F77, LAPACK supplied,
  emcc for C/C++). Solid existence proof.
- **BUT Pyodide = real CPython compiled to WASM** → real objects (`PyArrayObject` with real
  fields, `ob_item`…). wasthon = **Brython + handle-based bridge**. Yet:
  1. **f2py generates C-API glue** that does **direct field access on `PyArrayObject`**
     (`->data`, `->dimensions`, `->strides`) for every Fortran wrapper. On the bridge, an ndarray
     is a handle; that glue assumes the C memory layout. It is **pervasive** (every f2py wrapper).
  2. The **62 Cython modules** add the same `ob_item`/fast-path wall (see `PANDAS.md`).
- ⇒ Even after winning the Fortran battle (which Pyodide won), wasthon keeps a **structural
  extra cost**: materializing/adapting the memory layout for all the f2py + Cython glue. **This is
  where "real CPython in WASM" (Pyodide) has a decisive architectural advantage.**

## Verdict & honest options

SciPy requires, cumulatively:
1. A **Fortran→WASM toolchain** (f2c for ~460 F77, + the 3 F90) — feasible, heavy.
2. **BLAS + LAPACK for WASM** (f2c'd CLAPACK or OpenBLAS-wasm).
3. Compiling **1417 C++ + 425 C** (boost, HiGHS, pocketfft…) — volume.
4. The shared **Cython support layer** (see `PANDAS.md`).
5. **The wasthon surcharge**: adapting the f2py + Cython glue to the handle bridge (the real differentiator).

**Three possible stances:**
- **(a) Do not port SciPy.** Accept that the heavy stack (scipy/sklearn) stays out of wasthon's scope,
  and focus on what the bridge does well (numpy + "light" Fortran-free Cython libs:
  pandas, numpy.random). An honest position given the architectural surcharge.
- **(b) Targeted Fortran feasibility pass**: take ONE self-contained F77 package with no BLAS
  (e.g. **QUADPACK** = numerical integration, 35 `.f`, no LAPACK), run it f2c → C → emcc →
  bridge, and see whether the f2py glue holds on handles. That prices wall #5 (the only
  wasthon-specific one) on the smallest possible perimeter.
- **(c) Re-evaluate the architecture**: for the heavy scientific stack, "real CPython in WASM"
  (Pyodide-style) is structurally better placed than the bridge. A product-level call.

**Recommendation**: if SciPy is the goal, run **pass (b) on QUADPACK** — the smallest
revealer of the one wall Pyodide does not have (f2py glue vs handles). Otherwise, declare SciPy
out of scope and capitalize on the shared Cython layer (pandas/random).

---
Pointers: `SCIKIT_LEARN.md` (downstream of SciPy), `PANDAS.md` (Cython bootstrap + `ob_item`),
`NUMPY.md` (acquired C-API surface). f2c/flang not installed in the build env.
