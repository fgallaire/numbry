#include <stddef.h>
#include "cython_blas_shim.h"
/* f2c'd BLAS in numpy's lapack_lite. numpy generated its BLAS WITHOUT the
   trailing ftnlen string-length arguments — dgemm_/sgemm_ take the char*
   transa/transb pointers alone (13 args, ending at *ldc). The wrappers must
   match that signature exactly: passing the classic trailing (ftnlen)1,1 makes
   the wasm call disagree with the 13-arg callee and traps ("unreachable
   executed") the moment _vq.vq takes its nfeat>=5 BLAS path. */
extern int dgemm_(char *transa, char *transb, int *m, int *n, int *k,
                  double *alpha, double *a, int *lda, double *b, int *ldb,
                  double *beta, double *c, int *ldc);
extern int sgemm_(char *transa, char *transb, int *m, int *n, int *k,
                  float *alpha, float *a, int *lda, float *b, int *ldb,
                  float *beta, float *c, int *ldc);
void dgemm(char *transa, char *transb, int *m, int *n, int *k,
           double *alpha, double *a, int *lda, double *b, int *ldb,
           double *beta, double *c, int *ldc) {
    dgemm_(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc);
}
void sgemm(char *transa, char *transb, int *m, int *n, int *k,
           float *alpha, float *a, int *lda, float *b, int *ldb,
           float *beta, float *c, int *ldc) {
    sgemm_(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc);
}
