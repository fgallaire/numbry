"""scipy.spatial.distance façade over numpy — pybind11-free.

scipy.spatial.distance's fast pdist/cdist live in a pybind11 C++ extension
(_distance_pybind) plus _distance_wrap.c / _hausdorff.pyx. scipy.cluster only
needs pdist / cdist / squareform / the y-vector validators, over a handful of
metrics — all straightforward in numpy. Serve exactly that so scipy.cluster
imports and runs without the compiled distance backend.

NOT the full distance module: exotic metrics (mahalanobis with VI, weighted
variants, boolean-set metrics beyond the few below) and the KDTree/Hausdorff
paths are absent. Unknown metric -> ValueError, never a wrong number.
"""
import numpy as np


# ---- metric registry: f(u, v) -> scalar (for the pure path) ------------------

def _euclidean(u, v):
    return np.sqrt(np.sum((u - v) ** 2))

def _sqeuclidean(u, v):
    d = u - v
    return np.dot(d, d)

def _cityblock(u, v):
    return np.sum(np.abs(u - v))

def _chebyshev(u, v):
    return np.max(np.abs(u - v)) if u.size else 0.0

def _minkowski(u, v, p=2):
    return np.sum(np.abs(u - v) ** p) ** (1.0 / p)

def _cosine(u, v):
    return 1.0 - np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v))

def _correlation(u, v):
    um = u - u.mean()
    vm = v - v.mean()
    return 1.0 - np.dot(um, vm) / (np.linalg.norm(um) * np.linalg.norm(vm))

def _hamming(u, v):
    return np.mean(u != v)

def _jaccard(u, v):
    nz = (u != 0) | (v != 0)
    if not np.any(nz):
        return 0.0
    return np.sum((u != v) & nz) / np.sum(nz)

def _braycurtis(u, v):
    return np.sum(np.abs(u - v)) / np.sum(np.abs(u + v))

def _canberra(u, v):
    d = np.abs(u - v)
    s = np.abs(u) + np.abs(v)
    with np.errstate(invalid='ignore', divide='ignore'):
        r = np.where(s != 0, d / s, 0.0)
    return np.sum(r)


_METRICS = {
    'euclidean': _euclidean, 'l2': _euclidean,
    'sqeuclidean': _sqeuclidean,
    'cityblock': _cityblock, 'manhattan': _cityblock, 'l1': _cityblock,
    'chebyshev': _chebyshev, 'chebychev': _chebyshev, 'inf': _chebyshev,
    'minkowski': _minkowski,
    'cosine': _cosine,
    'correlation': _correlation,
    'hamming': _hamming,
    'jaccard': _jaccard,
    'braycurtis': _braycurtis,
    'canberra': _canberra,
}


def _resolve(metric):
    if callable(metric):
        return metric
    m = metric.lower()
    if m not in _METRICS:
        raise ValueError("Unknown / unsupported distance metric %r "
                         "(spatial.distance façade)" % (metric,))
    return _METRICS[m]


def pdist(X, metric='euclidean', *, out=None, **kwargs):
    X = np.asarray(X, dtype=float)
    if X.ndim != 2:
        raise ValueError("A 2-dimensional array must be passed.")
    m = X.shape[0]
    f = _resolve(metric)
    dm = np.empty(m * (m - 1) // 2, dtype=float)
    k = 0
    for i in range(m - 1):
        for j in range(i + 1, m):
            dm[k] = f(X[i], X[j], **kwargs) if kwargs else f(X[i], X[j])
            k += 1
    return dm


def cdist(XA, XB, metric='euclidean', *, out=None, **kwargs):
    XA = np.asarray(XA, dtype=float)
    XB = np.asarray(XB, dtype=float)
    if XA.ndim != 2 or XB.ndim != 2:
        raise ValueError("XA and XB must be 2-dimensional arrays.")
    if XA.shape[1] != XB.shape[1]:
        raise ValueError("XA and XB must have the same number of columns.")
    f = _resolve(metric)
    mA, mB = XA.shape[0], XB.shape[0]
    dm = np.empty((mA, mB), dtype=float)
    for i in range(mA):
        for j in range(mB):
            dm[i, j] = f(XA[i], XB[j], **kwargs) if kwargs else f(XA[i], XB[j])
    return dm


def squareform(X, force="no", checks=True):
    X = np.asarray(X, dtype=float)
    if X.ndim == 1:
        n = X.shape[0]
        d = int(np.ceil(np.sqrt(n * 2)))
        if d * (d - 1) // 2 != n:
            raise ValueError("Incompatible vector size. It must be a binomial "
                             "coefficient n choose 2 for some integer n >= 1.")
        M = np.zeros((d, d), dtype=X.dtype)
        iu = np.triu_indices(d, k=1)
        M[iu] = X
        M[(iu[1], iu[0])] = X
        return M
    elif X.ndim == 2:
        s = X.shape
        if s[0] != s[1]:
            raise ValueError("The matrix argument must be square.")
        if checks:
            is_valid_dm(X, throw=True, name='X')
        d = s[0]
        return X[np.triu_indices(d, k=1)]
    raise ValueError("The first argument must be one or two dimensional array.")


def is_valid_dm(D, tol=0.0, throw=False, name="D", warning=False):
    D = np.asarray(D)
    try:
        if D.ndim != 2 or D.shape[0] != D.shape[1]:
            raise ValueError("Distance matrix %r must be square." % name)
        if not np.allclose(np.diag(D), 0, atol=tol):
            raise ValueError("Distance matrix %r diagonal must be zero." % name)
        if not np.allclose(D, D.T, atol=tol):
            raise ValueError("Distance matrix %r must be symmetric." % name)
        return True
    except ValueError:
        if throw:
            raise
        return False


def is_valid_y(y, warning=False, throw=False, name=None):
    y = np.asarray(y)
    try:
        if y.ndim != 1:
            raise ValueError("Condensed distance matrix must be 1-D.")
        n = y.shape[0]
        d = int(np.ceil(np.sqrt(n * 2)))
        if d * (d - 1) // 2 != n:
            raise ValueError("Length must be a binomial coefficient.")
        return True
    except ValueError:
        if throw:
            raise
        return False


def num_obs_y(Y):
    Y = np.asarray(Y)
    n = Y.shape[0]
    d = int(np.ceil(np.sqrt(n * 2)))
    if d * (d - 1) // 2 != n:
        raise ValueError("Invalid condensed distance matrix length.")
    return d


def num_obs_dm(d):
    d = np.asarray(d)
    return d.shape[0]
