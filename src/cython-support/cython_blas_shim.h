/* Clean-signature BLAS gemm over numpy lapack_lite's f2c'd dgemm_/sgemm_
   (which carry trailing ftnlen string-length args). For scipy.cluster._vq. */
#ifndef CYTHON_BLAS_SHIM_H
#define CYTHON_BLAS_SHIM_H
void dgemm(char *transa, char *transb, int *m, int *n, int *k,
           double *alpha, double *a, int *lda, double *b, int *ldb,
           double *beta, double *c, int *ldc);
void sgemm(char *transa, char *transb, int *m, int *n, int *k,
           float *alpha, float *a, int *lda, float *b, int *ldb,
           float *beta, float *c, int *ldc);
#endif
