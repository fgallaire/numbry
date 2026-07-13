/* scipy.fft (pypocketfft) link stubs. pybind11's error/traceback and import
 * machinery — instantiated by pypocketfft's use of stl.h / numpy.h, which the
 * matplotlib modules never pull in — references a dozen CPython entry points
 * the bridge doesn't provide. Definitions here match the vendored CPython
 * headers in src/ (compiled as C, so C linkage lines up with pybind11's
 * extern "C" declarations). The traceback/exc-info ones are pure error-path:
 * returning NULL/no-op degrades the traceback a raised exception carries, not
 * the correctness of raising or of the FFT itself. The import/module ones are
 * routed to real bridge calls (numpy.h imports numpy through these at init).
 */
#include <Python.h>
#include <stdint.h>

PyCodeObject *PyCode_NewEmpty(const char *filename, const char *funcname,
                              int firstlineno) {
    (void)filename; (void)funcname; (void)firstlineno; return NULL;
}
PyFrameObject *PyFrame_New(PyThreadState *tstate, PyCodeObject *code,
                           PyObject *globals, PyObject *locals) {
    (void)tstate; (void)code; (void)globals; (void)locals; return NULL;
}
int PyTraceBack_Here(PyFrameObject *frame) { (void)frame; return 0; }

void PyErr_GetExcInfo(PyObject **ptype, PyObject **pvalue, PyObject **ptb) {
    *ptype = NULL; *pvalue = NULL; *ptb = NULL;
}
void PyErr_SetExcInfo(PyObject *type, PyObject *value, PyObject *tb) {
    Py_XDECREF(type); Py_XDECREF(value); Py_XDECREF(tb);
}

int64_t PyInterpreterState_GetID(PyInterpreterState *interp) {
    (void)interp; return 0;
}
vectorcallfunc PyVectorcall_Function(PyObject *callable) {
    (void)callable; return NULL;   /* no vectorcall slot -> pybind11 falls back */
}

const char *PyModule_GetName(PyObject *m) {
    PyObject *d = PyModule_GetDict(m);
    if (d) {
        PyObject *n = PyDict_GetItemString(d, "__name__");   /* borrowed */
        if (n) return PyUnicode_AsUTF8(n);
    }
    return "";
}
PyObject *PyModule_NewObject(PyObject *name) {
    const char *s = PyUnicode_AsUTF8(name);
    return PyModule_New(s ? s : "?");
}

PyObject *PyImport_GetModule(PyObject *name) {   /* returns a NEW reference */
    PyObject *mods = PyImport_GetModuleDict();   /* borrowed */
    const char *s = PyUnicode_AsUTF8(name);
    if (mods && s) {
        PyObject *m = PyDict_GetItemString(mods, s);   /* borrowed */
        Py_XINCREF(m);
        return m;
    }
    return NULL;
}
PyObject *PyImport_AddModuleRef(const char *name) {
    PyObject *mods = PyImport_GetModuleDict();
    PyObject *m = mods ? PyDict_GetItemString(mods, name) : NULL;
    if (m) { Py_INCREF(m); return m; }
    m = PyModule_New(name);
    if (m && mods) PyDict_SetItemString(mods, name, m);
    return m;
}
PyObject *PyImport_ImportModuleLevelObject(PyObject *name, PyObject *globals,
                                           PyObject *locals, PyObject *fromlist,
                                           int level) {
    (void)globals; (void)locals; (void)fromlist; (void)level;
    const char *s = PyUnicode_AsUTF8(name);
    return s ? PyImport_ImportModule(s) : NULL;
}
/* NOTE: a broader set (PySequence_SetItem, PyNumber_InPlaceRshift,
 * PyObject_DelAttr, …) that pybind11's stl.h references was tried here but
 * clobbered working bridge/numpy definitions via --allow-multiple-definition
 * and broke _ccallback_c init. Those stay as lazy throw-stubs
 * (ERROR_ON_UNDEFINED_SYMBOLS=0) — only hit on pybind11's error path, not on
 * the FFT compute path. */
