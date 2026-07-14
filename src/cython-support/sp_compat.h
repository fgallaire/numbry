/* scipy.special bridge shims for symbols missing from BOTH cython_compat.h and
   scipy_compat.h. Consumed by spbuild.sh via -include, for the C and C++
   translation units. (scipy_compat.h — itself extern "C"-guarded — supplies
   the rest to both C and C++; this header only fills what it doesn't.) */
#ifndef SP_COMPAT_H
#define SP_COMPAT_H

/* sf_error.cc formats through the CPython-private PyOS_vsnprintf. */
#ifndef PyOS_vsnprintf
#define PyOS_vsnprintf vsnprintf
#endif

/* Cython's __Pyx_KwargsAsDict_FASTCALL expands to the CPython-private
   _PyStack_AsDict (kwnames tuple + parallel value array -> dict), which the
   bridge headers don't provide. Rebuild it from public calls. */
#ifdef __GNUC__
__attribute__((unused))
#endif
static PyObject *_PyStack_AsDict(PyObject *const *values, PyObject *kwnames)
{
    PyObject *d = PyDict_New();
    Py_ssize_t i, n;
    if (!d) return NULL;
    n = PyTuple_Size(kwnames);
    for (i = 0; i < n; i++) {
        PyObject *k = PyTuple_GetItem(kwnames, i);
        if (!k || PyDict_SetItem(d, k, values[i]) < 0) {
            Py_DECREF(d);
            return NULL;
        }
    }
    return d;
}

/* The handled-exception (exc_info) accessors take/return STOLEN references:
   drop them so swaps don't leak. The bridge tracks the live exception in JS
   (pendingException), so the only visible cost is a degraded sys.exc_info()
   context inside these modules' except blocks — not the correctness of
   raising or catching. cython_compat.h declares PyErr_SetExcInfo extern but
   nothing implements it; the C output preprocesses the call away, the C++
   output emits it, so route it to an inline drop-refs (the earlier extern
   decl is left unused). */
#ifndef PyErr_GetHandledException
#define PyErr_GetHandledException() (NULL)
#endif
#ifndef PyErr_SetExcInfo
#define PyErr_SetExcInfo(t, v, tb) \
    do { Py_XDECREF(t); Py_XDECREF(v); Py_XDECREF(tb); } while (0)
#endif

/* Cython reads an *exact* Python complex through the raw C struct field
   ((PyComplexObject *)o)->cval — garbage under the handle-based bridge, where o
   is a handle, not a C PyComplexObject in linear memory. Force the CheckExact
   fast-path off so Cython's __Pyx_PyComplex_As_* falls to PyComplex_AsCComplex,
   which the bridge implements correctly (reads the Brython complex real/imag).
   Fixes every cython_special function taking a complex (D) argument. */
#undef PyComplex_CheckExact
#define PyComplex_CheckExact(op) 0

/* WebAssembly has NO rounding-mode control: its float instructions are
   specified as round-to-nearest-even, with no mode register to set. But
   emscripten's musl ships fenv.c — literally titled "Dummy functions for archs
   lacking fenv implementation" — whose __fesetround() returns 0 (success) and
   does nothing. scipy's have_fenv() believes it, so test_add_round_{up,down}
   run and mismatch on ~50% of samples (49986/100000) — the exact signature of a
   rounding mode being ignored.

   Report the platform truthfully: only FE_TONEAREST is achievable. have_fenv()
   then returns False and scipy's own
   `@pytest.mark.skipif(not have_fenv(), reason="no fenv()")` skips those tests —
   which is what upstream does on any fenv-less platform (scipy's _round.h even
   carries the same fallback: `int fesetround(int){ return -1; }`).

   fenv.h is pulled in HERE so the real declaration is seen before the macro
   exists; the TU's own `#include <fenv.h>` is then a no-op (include guard) and
   only call sites expand. Sole caller in this build: _test_internal. */
#include <fenv.h>
#undef fesetround
#define fesetround(r) ((r) == FE_TONEAREST ? 0 : -1)

#endif
