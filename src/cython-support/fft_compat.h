/* scipy.fft (pypocketfft) bridge shim, force-included by fftbuild.sh.
   The bridge builds functions via PyCFunction_NewEx and adds them with
   PyModule_AddObject, but doesn't provide the batch helper pypocketfft uses
   for good_size / prev_good_size. Rebuild it from those two public calls. */
#ifndef FFT_COMPAT_H
#define FFT_COMPAT_H

#ifndef PyModule_AddFunctions
static inline int PyModule_AddFunctions(PyObject *module, PyMethodDef *functions)
{
    PyMethodDef *ml;
    for (ml = functions; ml && ml->ml_name; ml++) {
        PyObject *f = PyCFunction_NewEx(ml, NULL, module);
        if (!f) return -1;
        /* PyModule_AddObject steals f's reference on success. */
        if (PyModule_AddObject(module, ml->ml_name, f) < 0) {
            Py_DECREF(f);
            return -1;
        }
    }
    return 0;
}
#endif

#endif
