#include <stddef.h>
#include "cython_blas_shim.h"
/* f2c'd BLAS in numpy's lapack_lite: same args + two trailing ftnlen (string
   lengths of transa/transb; here the single chars "T"/"N" -> length 1). In
   wasm32 int and size_t are both i32, so the trailing width matches. */
extern int dgemm_(char *transa, char *transb, int *m, int *n, int *k,
                  double *alpha, double *a, int *lda, double *b, int *ldb,
                  double *beta, double *c, int *ldc, size_t la, size_t lb);
extern int sgemm_(char *transa, char *transb, int *m, int *n, int *k,
                  float *alpha, float *a, int *lda, float *b, int *ldb,
                  float *beta, float *c, int *ldc, size_t la, size_t lb);
void dgemm(char *transa, char *transb, int *m, int *n, int *k,
           double *alpha, double *a, int *lda, double *b, int *ldb,
           double *beta, double *c, int *ldc) {
    dgemm_(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc,
           (size_t)1, (size_t)1);
}
void sgemm(char *transa, char *transb, int *m, int *n, int *k,
           float *alpha, float *a, int *lda, float *b, int *ldb,
           float *beta, float *c, int *ldc) {
    sgemm_(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc,
           (size_t)1, (size_t)1);
}
