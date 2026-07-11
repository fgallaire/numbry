"""wasthon stub for numpy.linalg._umath_linalg.

The real module is a C extension over LAPACK/BLAS, which isn't built for the
wasthon/WASM target. Every linear-algebra gufunc is present so that
numpy.linalg (and therefore the whole `import numpy`) imports cleanly, but each
raises NotImplementedError when actually called — so array creation, ufuncs,
reductions, reshaping, indexing, dtypes, etc. all work; only linalg operations
(inv/solve/eig/svd/qr/cholesky/det/lstsq/...) are unavailable.
"""

_MSG = ("numpy.linalg is unavailable in this build: it needs the LAPACK/BLAS "
        "C extension (_umath_linalg), which is not compiled for wasthon/WASM.")


def _no_lapack(*args, **kwargs):
    raise NotImplementedError(_MSG)


# numpy.testing._private.utils reads this at import (HAS_LAPACK64 detection);
# we ship no LAPACK, so certainly not the ILP64 build.
_ilp64 = False

# The linalg gufuncs numpy._linalg looks up on this module.
solve = solve1 = inv = det = slogdet = eig = eigvals = _no_lapack
eigh_lo = eigh_up = eigvalsh_lo = eigvalsh_up = _no_lapack
svd = svd_f = svd_s = cholesky_lo = cholesky_up = _no_lapack
qr_r_raw = qr_reduced = qr_complete = lstsq = _no_lapack
