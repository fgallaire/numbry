/*
 * dstevr -> dsteqr shim.
 *
 * scipy.special needs exactly ONE LAPACK routine: dstevr (selected
 * eigenvalues/vectors of a symmetric tridiagonal matrix), called by the
 * _ellip_harm ufunc and _ellip_harm_2 with jobz='V', range='I'.
 * numpy's f2c'd lapack_lite (already linked for numpy.linalg) has no dstevr,
 * but it has dsteqr_ — the QL/QR eigensolver for the SAME tridiagonal input
 * (all eigenvalues, ascending). Emulate dstevr on top of it: run dsteqr on a
 * copy, then apply the range selection. Matrices here are tiny (ellip_harm
 * degree n -> size ~n/2+1), so computing all pairs costs nothing.
 *
 * Signature matches scipy/special/lapack_defs.h exactly — including the two
 * trailing size_t string-length arguments — because wasm traps on
 * caller/callee signature mismatch.
 */
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

extern int dsteqr_(char *compz, int *n, double *d, double *e, double *z,
                   int *ldz, double *work, int *info);

void dstevr_(char *jobz, char *range, int *n, double *d, double *e,
             double *vl, double *vu, int *il, int *iu, double *abstol,
             int *m, double *w, double *z, int *ldz, int *isuppz,
             double *work, int *lwork, int *iwork, int *liwork,
             int *info, size_t jobz_len, size_t range_len)
{
    (void)abstol; (void)isuppz; (void)iwork; (void)jobz_len; (void)range_len;
    int nn = *n;
    *info = 0;
    if (*lwork == -1 || *liwork == -1) {   /* workspace query */
        work[0] = 1.0;
        if (*liwork == -1) iwork[0] = 1;
        return;
    }
    if (nn <= 0) { *m = 0; return; }

    int want_v = (jobz[0] == 'V' || jobz[0] == 'v');
    double *dd = (double *)malloc((size_t)nn * sizeof(double));
    double *ee = nn > 1 ? (double *)malloc((size_t)(nn - 1) * sizeof(double))
                        : NULL;
    double *zz = want_v ? (double *)malloc((size_t)nn * nn * sizeof(double))
                        : NULL;
    double *wk = (double *)malloc((size_t)(nn > 1 ? 2 * nn - 2 : 1) *
                                  sizeof(double));
    if (!dd || (nn > 1 && !ee) || (want_v && !zz) || !wk) {
        free(dd); free(ee); free(zz); free(wk);
        *info = -100;
        return;
    }
    memcpy(dd, d, (size_t)nn * sizeof(double));
    if (nn > 1) memcpy(ee, e, (size_t)(nn - 1) * sizeof(double));

    char compz = want_v ? 'I' : 'N';
    dsteqr_(&compz, &nn, dd, ee, zz ? zz : dd /* unused when 'N' */,
            &nn, wk, info);
    if (*info == 0) {
        /* dd now holds ALL eigenvalues ascending; zz the vectors (col-major) */
        int lo = 0, hi = nn - 1;             /* range 'A' */
        if (range[0] == 'I' || range[0] == 'i') {
            lo = *il - 1;                    /* LAPACK is 1-based */
            hi = *iu - 1;
        } else if (range[0] == 'V' || range[0] == 'v') {
            while (lo < nn && dd[lo] <= *vl) lo++;
            hi = nn - 1;
            while (hi >= lo && dd[hi] > *vu) hi--;
        }
        int cnt = hi - lo + 1;
        if (cnt < 0) cnt = 0;
        *m = cnt;
        for (int j = 0; j < cnt; j++) {
            w[j] = dd[lo + j];
            if (want_v)
                memcpy(z + (size_t)j * *ldz, zz + (size_t)(lo + j) * nn,
                       (size_t)nn * sizeof(double));
        }
    }
    free(dd); free(ee); free(zz); free(wk);
}
