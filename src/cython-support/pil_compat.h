/* Pillow ↔ wasthon bridge shim. Two CPython macro/3.13+ C-API entry points that
 * Pillow's C core uses but the reduced handle-based bridge doesn't expose. Both
 * are pure macros expanded at the call site (Python.h is already included there),
 * so they need no link symbol. Guarded so a future bridge definition wins. */
#ifndef PIL_COMPAT_H
#define PIL_COMPAT_H

/* 3.13+ strong-ref list getter: borrowed PyList_GetItem + an incref. */
#ifndef PyList_GetItemRef
#define PyList_GetItemRef(list, i) Py_XNewRef(PyList_GetItem((list), (i)))
#endif

/* Unchecked fast PyLong→C long macro; route to the safe bridge accessor. */
#ifndef PyLong_AS_LONG
#define PyLong_AS_LONG(op) PyLong_AsLong((PyObject *)(op))
#endif

#endif /* PIL_COMPAT_H */
