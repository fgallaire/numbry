# Browser implementation of stdlib tracemalloc, backed by the bridge's real
# PyTraceMalloc_Track/Untrack bookkeeping (wasthon.js keeps a
# (domain, ptr) -> size Map on globalThis.__wasthon_tracemalloc while tracing
# is on). Enough for pandas/tests/libs/test_hashtable.py: khash allocations
# are domain-tagged (KHASH_TRACE_DOMAIN) and the tests only domain-filter
# snapshots and sum trace sizes.


class DomainFilter:
    def __init__(self, inclusive, domain):
        self.inclusive = inclusive
        self.domain = domain


class Filter:
    def __init__(self, inclusive, filename_pattern, lineno=None,
                 all_frames=False, domain=None):
        self.inclusive = inclusive
        self.filename_pattern = filename_pattern
        self.lineno = lineno
        self.all_frames = all_frames
        self.domain = domain


class Trace:
    def __init__(self, domain, size):
        self.domain = domain
        self.size = size
        self.traceback = ()


class Snapshot:
    def __init__(self, traces=None):
        self.traces = traces or []

    def filter_traces(self, filters):
        traces = self.traces
        for f in filters:
            if isinstance(f, DomainFilter):
                if f.inclusive:
                    traces = [t for t in traces if t.domain == f.domain]
                else:
                    traces = [t for t in traces if t.domain != f.domain]
            # plain (filename) Filters: no traceback data under the bridge —
            # keep the traces rather than dropping them all.
        return Snapshot(list(traces))

    def statistics(self, key_type, cumulative=False):
        return []

    def compare_to(self, old_snapshot, key_type, cumulative=False):
        return []


def _store():
    from browser import window
    st = getattr(window, "__wasthon_tracemalloc", None)
    if st is None:
        window.eval(
            "globalThis.__wasthon_tracemalloc ="
            " { tracing: false, map: new Map() }")
        st = window.__wasthon_tracemalloc
    return st


def start(nframe=1):
    st = _store()
    st.map.clear()
    st.tracing = True


def stop():
    st = _store()
    st.tracing = False
    st.map.clear()


def is_tracing():
    return bool(_store().tracing)


def _traces():
    from browser import window
    st = _store()
    out = []
    entries = getattr(window.Array, "from")(st.map.entries())
    for pair in entries:
        key, size = pair[0], pair[1]
        try:
            domain = int(str(key).split(":")[0])
        except ValueError:
            continue
        out.append(Trace(domain, int(size)))
    return out


def take_snapshot():
    return Snapshot(_traces())


def get_traced_memory():
    total = sum(t.size for t in _traces())
    return (total, total)


def reset_peak():
    pass


def get_tracemalloc_memory():
    return 0


def clear_traces():
    _store().map.clear()
