# Minimal pytest shim — enough to import and run numpy's own test modules
# (raises/mark.parametrize/skip/xfail/fixture/approx/warns). Not a real pytest;
# just the surface numpy's test files touch at import + run time.
import re as _re


class Skipped(Exception):
    pass


class XFailed(Exception):
    pass


class _Raises:
    def __init__(self, expected, match=None):
        self.expected = expected if isinstance(expected, tuple) else (expected,)
        self.match = match
        self.value = None
        self._wcm = None

    def __enter__(self):
        # pandas runs its suite under `filterwarnings = error`: an expected
        # Warning class actually RAISES there (pytest.raises(FutureWarning)
        # is idiomatic in its tests). Emulate for the classes asked for.
        wcls = [c for c in self.expected
                if isinstance(c, type) and issubclass(c, Warning)]
        if wcls:
            import warnings
            self._wcm = warnings.catch_warnings()
            self._wcm.__enter__()
            for c in wcls:
                warnings.simplefilter("error", category=c)
        return self

    def __exit__(self, et, ev, tb):
        if self._wcm is not None:
            self._wcm.__exit__(None, None, None)
        if et is None:
            raise AssertionError("DID NOT RAISE %r" % (self.expected,))
        if not issubclass(et, self.expected):
            return False
        self.value = ev
        if self.match is not None and not _re.search(self.match, str(ev)):
            raise AssertionError("pattern %r not found in %r" % (self.match, str(ev)))
        return True


def raises(expected, *args, match=None, **kw):
    if args:
        func = args[0]
        try:
            func(*args[1:], **kw)
        except expected as e:
            return e
        raise AssertionError("DID NOT RAISE %r" % (expected,))
    return _Raises(expected, match=match)


class approx:
    def __init__(self, expected, rel=None, abs=None, nan_ok=False):
        self.expected, self.rel, self.abs = expected, rel, abs

    def __eq__(self, other):
        a = self.abs if self.abs is not None else 1e-12
        r = self.rel if self.rel is not None else 1e-6
        try:
            return abs(other - self.expected) <= max(a, r * abs(self.expected))
        except Exception:
            return False

    __req__ = __eq__


def skip(reason=""):
    raise Skipped(reason)


def xfail(reason=""):
    raise XFailed(reason)


def fail(reason="", pytrace=True):
    raise AssertionError(reason)


def importorskip(name, *a, **k):
    try:
        return __import__(name)
    except Exception:
        raise Skipped("could not import %r" % name)


class _WarnsCtx:
    # Records warnings raised in the block so tests can inspect them
    # (`with pytest.warns(...) as w: ...; w[0].message`, `len(w)`). Uses
    # warnings.catch_warnings(record=True); does NOT swallow exceptions.
    def __init__(self, *a, **k):
        self._log = []
        self._cm = None

    def __enter__(self):
        import warnings
        self._cm = warnings.catch_warnings(record=True)
        self._log = self._cm.__enter__()
        warnings.simplefilter("always")
        return self

    def __exit__(self, *exc):
        if self._cm is not None:
            self._cm.__exit__(*exc)
        return False

    def __getitem__(self, i):
        return self._log[i]

    def __len__(self):
        return len(self._log)

    def __iter__(self):
        return iter(self._log)


def warns(*a, **k):
    # pytest's legacy callable form warns(WarningCls, func, *args, **kwargs)
    # calls func and returns its value (numpy's test_floating_overflow does
    # `flongdouble = pytest.warns(RuntimeWarning, np.longdouble, '1e10000')`).
    if len(a) >= 2 and callable(a[1]):
        return a[1](*a[2:], **k)
    return _WarnsCtx()


def deprecated_call(*a, **k):
    return _WarnsCtx()


def param(*values, **kw):
    return _Param(values, kw.get("marks", ()), kw.get("id"))


class _Param:
    def __init__(self, values, marks=(), id=None):
        self.values, self.marks, self.id = values, marks, id


class _Mark:
    def parametrize(self, argnames, argvalues, **kw):
        def deco(func):
            params = list(getattr(func, "_pytest_params", []))
            params.append((argnames, list(argvalues)))
            func._pytest_params = params
            return func
        return deco

    def skip(self, reason="", **k):
        def deco(obj):
            obj._pytest_skip = reason or True
            return obj
        return deco

    def skipif(self, cond, reason="", **k):
        def deco(obj):
            if cond:
                obj._pytest_skip = reason or True
            return obj
        return deco

    def xfail(self, *a, **k):
        def deco(obj):
            obj._pytest_xfail = True
            return obj
        return deco

    def __getattr__(self, name):
        # slow/serial/custom marks: no-op decorator (bare or called)
        def deco(*a, **k):
            if len(a) == 1 and callable(a[0]) and not k:
                return a[0]
            return lambda obj: obj
        return deco


mark = _Mark()


def fixture(*a, **k):
    # Mark the function so the runner can resolve it into missing test
    # arguments (module-level fixtures only; params= multiplies the cases
    # like parametrize, the value reaching the body via request.param).
    def _mark(f):
        # Not every decorated object can carry attributes (test_dlpack
        # stacks @pytest.fixture on a staticmethod): fall back silently,
        # the fixture just stays unresolvable like before.
        try:
            f._pytest_fixture = True
            f._pytest_fixture_params = k.get("params")
        except (AttributeError, TypeError):
            pass
        return f
    if len(a) == 1 and callable(a[0]) and not k:
        return _mark(a[0])
    return _mark


class _SkipModule(Exception):
    pass


def importskip(*a, **k):
    raise Skipped()


# pytest.ini-style markers registry no-ops
def register_assert_rewrite(*a, **k):
    pass


class ExceptionInfo:
    pass
