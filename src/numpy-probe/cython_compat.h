/* cython_compat.h — minimal shim so Cython-generated C compiles against
 * wasthon.h. Feasibility probe: types/macros to satisfy the compiler +
 * prototypes for the handful of C-API funcs the bridge would implement.
 * Include BEFORE the Cython C (via -include). */
#ifndef WASTHON_CYTHON_COMPAT_H
#define WASTHON_CYTHON_COMPAT_H
#include <stdint.h>
#include "wasthon.h"

/* --- trivial typedefs/macros --- */
#ifndef PY_INT64_T
typedef int64_t PY_INT64_T;
#endif
#ifndef CO_OPTIMIZED
#define CO_OPTIMIZED 0x0001
#endif
#ifndef CO_NEWLOCALS
#define CO_NEWLOCALS 0x0002
#endif
typedef uint32_t Py_UNICODE;
typedef PyObject *(*PyCFunctionWithKeywords)(PyObject *, PyObject *, PyObject *);
typedef PyObject *(*PyCMethod)(PyObject *, PyTypeObject *, PyObject *const *, size_t, PyObject *);

/* legacy unicode macros Cython still references on some paths (cosmetic here) */
#ifndef PyUnicode_GET_SIZE
#define PyUnicode_GET_SIZE(u) PyUnicode_GetLength(u)
#endif
#ifndef PyUnicode_AS_UNICODE
#define PyUnicode_AS_UNICODE(u) ((Py_UNICODE *)0)
#endif

/* exception-check macros → bridge helpers */
#ifndef PyExceptionClass_Check
#define PyExceptionClass_Check(x) PyType_Check(x)
#endif
#ifndef PyExceptionInstance_Check
#define PyExceptionInstance_Check(x) (!PyType_Check(x))
#endif
#ifndef PyTraceBack_Check
#define PyTraceBack_Check(x) 0
#endif

/* struct stubs: Cython pokes fields on these only for tuple fast-paths,
 * exception normalisation and traceback synthesis — give it the fields so
 * it compiles; the bridge routes the real behaviour through the handle map. */
typedef struct { PyObject_HEAD Py_ssize_t ob_size; PyObject **ob_item; } PyListObject;
typedef struct { PyObject_HEAD PyObject *args; PyObject *traceback;
                 PyObject *context; PyObject *cause; } PyBaseExceptionObject;
typedef struct { PyObject_HEAD long hash; } _cy_hashcarrier;
struct _wasthon_code { PyObject_HEAD int co_flags; };  /* complete PyCodeObject */
typedef struct { PyObject_HEAD PyObject *mm_class; } PyCMethodObject;

/* newer / internal C-API funcs the bridge would provide (link-time contract) */
extern PyObject *PyImport_AddModuleRef(const char *);
extern PyObject *PyImport_ImportModuleLevelObject(PyObject *, PyObject *, PyObject *, PyObject *, int);
extern PyObject *PyModule_NewObject(PyObject *);
extern PyObject **_PyObject_GetDictPtr(PyObject *);
extern PyObject *PyUnstable_Code_NewWithPosOnlyArgs(int, int, int, int, int, int, PyObject *, PyObject *, PyObject *, PyObject *, PyObject *, PyObject *, PyObject *, PyObject *, PyObject *, int, PyObject *, PyObject *);
extern int64_t PyInterpreterState_GetID(void *);

#endif
