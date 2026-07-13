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

#endif
