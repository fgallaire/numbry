# Browser stub: no property-based engine in the page. pandas' test modules
# import @given/strategies at module level; @given tests are collected as
# SKIPS (the dashboard runner honors _pytest_skip), strategies are inert
# factories so pandas._testing._hypothesis's shared strategies build fine.


class _S:
    """Inert strategy: absorbs any attribute/call/combinator."""

    def __getattr__(self, name):
        return _S()

    def __call__(self, *a, **k):
        return _S()

    def __or__(self, other):
        return _S()

    def map(self, *a, **k):
        return _S()

    def filter(self, *a, **k):
        return _S()

    def flatmap(self, *a, **k):
        return _S()


strategies = _S()


def given(*a, **k):
    def deco(fn):
        def _skipped(*aa, **kk):
            import pytest
            raise pytest.Skipped("hypothesis not available in the browser")
        _skipped._pytest_skip = True
        _skipped.__name__ = getattr(fn, "__name__", "given")
        return _skipped
    return deco


def example(*a, **k):
    def deco(fn):
        return fn
    return deco


def settings(*a, **k):
    if a and callable(a[0]):
        return a[0]

    def deco(fn):
        return fn
    return deco


settings.register_profile = lambda *a, **k: None
settings.load_profile = lambda *a, **k: None


def assume(cond):
    return True


class HealthCheck:
    too_slow = None
    differing_executors = None
    filter_too_much = None
    data_too_large = None
    function_scoped_fixture = None
