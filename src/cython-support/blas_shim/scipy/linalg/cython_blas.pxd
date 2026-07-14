# Façade for scipy.linalg.cython_blas — the two BLAS routines scipy.cluster._vq
# cimports (dgemm/sgemm). Declared as direct C externs from cython_blas_shim.h
# (a clean-signature wrapper over numpy lapack_lite's f2c'd dgemm_/sgemm_), so
# Cython emits a straight C call — no runtime cython_blas module / capsule.
cdef extern from "cython_blas_shim.h" nogil:
    void dgemm(char *transa, char *transb, int *m, int *n, int *k,
               double *alpha, double *a, int *lda, double *b, int *ldb,
               double *beta, double *c, int *ldc)
    void sgemm(char *transa, char *transb, int *m, int *n, int *k,
               float *alpha, float *a, int *lda, float *b, int *ldb,
               float *beta, float *c, int *ldc)
