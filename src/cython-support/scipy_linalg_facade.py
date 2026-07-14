"""scipy.linalg façade over numpy.linalg — Fortran-free.

scipy ships its LAPACK/BLAS wrappers as real Fortran (compiled by gfortran at
build time), so scipy.linalg's own __init__ can't be imported in this wasm
build. But the functions scipy.signal / scipy.spatial / scipy.cluster actually
pull from scipy.linalg are all either numpy.linalg-backed (numpy's f2c'd
lapack_lite works here) or pure-numpy constructions. This module serves exactly
that subset, with scipy-compatible signatures, so those modules import and run.

NOT a complete scipy.linalg: anything needing LAPACK routines outside numpy's
subset (schur, qz, lu with pivots, banded/structured solvers beyond the few
below, cython_blas/cython_lapack) is absent — a caller reaching for one gets a
clean AttributeError, not a wrong answer.
"""
import numpy as np
from numpy.linalg import LinAlgError

__all__ = [
    'LinAlgError', 'LinAlgWarning',
    'norm', 'inv', 'pinv', 'det', 'solve', 'lstsq',
    'eig', 'eigh', 'eigvals', 'eigvalsh', 'svd', 'qr', 'cholesky',
    'matrix_rank',
    'toeplitz', 'hankel', 'companion', 'block_diag', 'circulant',
    'orthogonal_procrustes', 'expm',
    'solve_banded', 'eigh_tridiagonal', 'eigvals_banded',
]


class LinAlgWarning(RuntimeWarning):
    """scipy.linalg's warning class (ill-conditioning, etc.)."""


# ---- numpy.linalg-backed, with scipy signatures ------------------------------

def norm(a, ord=None, axis=None, keepdims=False, check_finite=True):
    return np.linalg.norm(np.asarray(a), ord=ord, axis=axis, keepdims=keepdims)


def inv(a, overwrite_a=False, check_finite=True):
    return np.linalg.inv(np.asarray(a))


def pinv(a, atol=None, rtol=None, return_rank=False, check_finite=True):
    r = np.linalg.pinv(np.asarray(a))
    if return_rank:
        return r, np.linalg.matrix_rank(np.asarray(a))
    return r


def det(a, overwrite_a=False, check_finite=True):
    return np.linalg.det(np.asarray(a))


def solve(a, b, lower=False, overwrite_a=False, overwrite_b=False,
          check_finite=True, assume_a=None, transposed=False):
    a = np.asarray(a)
    if transposed:
        a = a.T
    return np.linalg.solve(a, np.asarray(b))


def lstsq(a, b, cond=None, overwrite_a=False, overwrite_b=False,
          check_finite=True, lapack_driver=None):
    # scipy returns (x, residues, rank, s); numpy returns the same tuple.
    x, res, rank, s = np.linalg.lstsq(np.asarray(a), np.asarray(b), rcond=cond)
    return x, res, rank, s


def eig(a, b=None, left=False, right=True, overwrite_a=False, overwrite_b=False,
        check_finite=True, homogeneous_eigvals=False):
    if b is not None:
        raise NotImplementedError("generalized eig (b != None) needs LAPACK ggev")
    if left:
        raise NotImplementedError("left eigenvectors need LAPACK geev jobvl")
    w, vr = np.linalg.eig(np.asarray(a))
    return (w, vr) if right else w


def eigvals(a, b=None, overwrite_a=False, check_finite=True,
            homogeneous_eigvals=False):
    if b is not None:
        raise NotImplementedError("generalized eigvals needs LAPACK ggev")
    return np.linalg.eigvals(np.asarray(a))


def eigh(a, b=None, *, lower=True, eigvals_only=False, overwrite_a=False,
         overwrite_b=False, type=1, check_finite=True, subset_by_index=None,
         subset_by_value=None, driver=None):
    if b is not None:
        # generalized symmetric eig A x = w B x -> reduce via Cholesky of B.
        L = np.linalg.cholesky(np.asarray(b))
        Linv = np.linalg.inv(L)
        C = Linv @ np.asarray(a) @ Linv.conj().T
        w, v = np.linalg.eigh(C)
        v = Linv.conj().T @ v
    else:
        w, v = np.linalg.eigh(np.asarray(a))
    if subset_by_index is not None:
        lo, hi = subset_by_index
        w, v = w[lo:hi + 1], v[:, lo:hi + 1]
    return w if eigvals_only else (w, v)


def eigvalsh(a, b=None, *, lower=True, overwrite_a=False, overwrite_b=False,
             type=1, check_finite=True, subset_by_index=None,
             subset_by_value=None, driver=None):
    return eigh(a, b, lower=lower, eigvals_only=True, type=type,
                subset_by_index=subset_by_index)


def svd(a, full_matrices=True, compute_uv=True, overwrite_a=False,
        check_finite=True, lapack_driver='gesdd'):
    return np.linalg.svd(np.asarray(a), full_matrices=full_matrices,
                         compute_uv=compute_uv)


def qr(a, overwrite_a=False, lwork=None, mode='full', pivoting=False,
       check_finite=True):
    if pivoting:
        raise NotImplementedError("column-pivoted QR needs LAPACK geqp3")
    # scipy modes -> numpy modes: full->complete (Q is MxM), economic->reduced.
    npmode = {'full': 'complete', 'economic': 'reduced', 'r': 'r',
              'raw': 'raw'}.get(mode, 'complete')
    res = np.linalg.qr(np.asarray(a), mode=npmode)
    if mode == 'r':
        return (res,)  # scipy returns a 1-tuple (R,)
    return res


def cholesky(a, lower=False, overwrite_a=False, check_finite=True):
    # numpy returns the LOWER factor; scipy defaults to the UPPER one.
    L = np.linalg.cholesky(np.asarray(a))
    return L if lower else L.conj().T


def matrix_rank(a, tol=None, *args, **kw):
    return np.linalg.matrix_rank(np.asarray(a), tol=tol)


# ---- pure-numpy structured matrices (scipy._special_matrices, simplified) ----

def toeplitz(c, r=None):
    c = np.asarray(c).ravel()
    r = c.conjugate() if r is None else np.asarray(r).ravel()
    vals = np.concatenate((c[::-1], r[1:]))
    n, m = len(c), len(r)
    idx = (np.arange(m)[None, :] - np.arange(n)[:, None]) + (n - 1)
    return vals[idx]


def hankel(c, r=None):
    c = np.asarray(c).ravel()
    r = np.zeros_like(c) if r is None else np.asarray(r).ravel()
    vals = np.concatenate((c, r[1:]))
    n, m = len(c), len(r)
    idx = np.arange(n)[:, None] + np.arange(m)[None, :]
    return vals[idx]


def circulant(c):
    c = np.asarray(c).ravel()
    n = len(c)
    idx = (np.arange(n)[:, None] - np.arange(n)[None, :]) % n
    return c[idx]


def companion(a):
    a = np.atleast_1d(np.asarray(a))
    if a.ndim != 1:
        raise ValueError("`a` must be one-dimensional.")
    if a.size < 2:
        raise ValueError("The length of `a` must be at least 2.")
    if a[0] == 0:
        raise ValueError("The first coefficient in `a` must not be zero.")
    first_row = -a[1:] / (1.0 * a[0])
    n = a.size
    c = np.zeros((n - 1, n - 1), dtype=first_row.dtype)
    c[0] = first_row
    c[list(range(1, n - 1)), list(range(0, n - 2))] = 1
    return c


def block_diag(*arrs):
    if not arrs:
        arrs = ([],)
    arrs = [np.atleast_2d(np.asarray(a)) for a in arrs]
    shapes = np.array([a.shape for a in arrs])
    out_dtype = np.result_type(*[a.dtype for a in arrs]) if arrs else float
    out = np.zeros(np.sum(shapes, axis=0), dtype=out_dtype)
    r, c = 0, 0
    for a in arrs:
        rr, cc = a.shape
        out[r:r + rr, c:c + cc] = a
        r += rr
        c += cc
    return out


def orthogonal_procrustes(A, B, check_finite=True):
    A = np.asarray(A)
    B = np.asarray(B)
    if A.ndim != 2:
        raise ValueError("expected ndim to be 2, but observed %s" % A.ndim)
    if A.shape != B.shape:
        raise ValueError("the shapes of A and B differ (%s vs %s)"
                         % (A.shape, B.shape))
    u, w, vt = np.linalg.svd(B.T.dot(A).T)
    R = u.dot(vt)
    scale = w.sum()
    return R, scale


# ---- matrix exponential: scaling-and-squaring Padé(13) -----------------------

def expm(A):
    A = np.asarray(A, dtype=float if np.isrealobj(A) else complex)
    if A.ndim != 2 or A.shape[0] != A.shape[1]:
        raise ValueError("expected a square matrix")
    n = A.shape[0]
    ident = np.eye(n, dtype=A.dtype)
    normA = np.max(np.sum(np.abs(A), axis=0))  # 1-norm
    # Padé-13 coefficients.
    b = (64764752532480000., 32382376266240000., 7771770303897600.,
         1187353796428800., 129060195264000., 10559470521600.,
         670442572800., 33522128640., 1323241920., 40840800.,
         960960., 16380., 182., 1.)
    if normA == 0:
        return ident.copy()
    s = max(0, int(np.ceil(np.log2(normA / 5.4))))  # scale so ||A/2^s|| small
    A = A / (2.0 ** s)
    A2 = A @ A
    A4 = A2 @ A2
    A6 = A2 @ A4
    U = A @ (A6 @ (b[13] * A6 + b[11] * A4 + b[9] * A2)
             + b[7] * A6 + b[5] * A4 + b[3] * A2 + b[1] * ident)
    V = (A6 @ (b[12] * A6 + b[10] * A4 + b[8] * A2)
         + b[6] * A6 + b[4] * A4 + b[2] * A2 + b[0] * ident)
    R = np.linalg.solve(-U + V, U + V)
    for _ in range(s):
        R = R @ R
    return R


# ---- banded / tridiagonal solvers, densified onto numpy ----------------------

def solve_banded(l_and_u, ab, b, overwrite_ab=False, overwrite_b=False,
                 check_finite=True):
    (l, u) = l_and_u
    ab = np.asarray(ab)
    n = ab.shape[1]
    A = np.zeros((n, n), dtype=ab.dtype)
    for i in range(ab.shape[0]):
        diag = u - i  # ab row i holds the (u-i)-th superdiagonal (diag>0) etc.
        for j in range(n):
            col = j
            row = j - diag
            if 0 <= row < n:
                A[row, col] = ab[i, j]
    return np.linalg.solve(A, np.asarray(b))


def eigh_tridiagonal(d, e, eigvals_only=False, select='a', select_range=None,
                     check_finite=True, tol=0.0, lapack_driver='auto'):
    d = np.asarray(d, dtype=float)
    e = np.asarray(e, dtype=float)
    n = d.shape[0]
    A = np.diag(d) + np.diag(e, 1) + np.diag(e, -1)
    w, v = np.linalg.eigh(A)
    return w if eigvals_only else (w, v)


def eigvals_banded(a_band, lower=False, overwrite_a_band=False, select='a',
                   select_range=None, max_ev=0, check_finite=True):
    ab = np.asarray(a_band, dtype=float)
    u = ab.shape[0] - 1
    n = ab.shape[1]
    A = np.zeros((n, n))
    for k in range(u + 1):
        if lower:
            for j in range(n - k):
                A[j + k, j] = ab[k, j]
                A[j, j + k] = ab[k, j]
        else:
            off = u - k
            for j in range(off, n):
                A[j - off, j] = ab[k, j]
                A[j, j - off] = ab[k, j]
    return np.linalg.eigvalsh(A)
