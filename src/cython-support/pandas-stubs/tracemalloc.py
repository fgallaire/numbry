# Browser stub of tracemalloc: pandas/tests/libs/test_hashtable.py imports it
# at module level to measure khash allocations. No allocation tracing exists
# under the bridge; snapshots come back empty (size assertions fail, the rest
# of the module runs).


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


class Snapshot:
    def __init__(self, traces=None):
        self.traces = traces or []

    def filter_traces(self, filters):
        return self

    def statistics(self, key_type, cumulative=False):
        return []

    def compare_to(self, old_snapshot, key_type, cumulative=False):
        return []


_tracing = False


def start(nframe=1):
    global _tracing
    _tracing = True


def stop():
    global _tracing
    _tracing = False


def is_tracing():
    return _tracing


def take_snapshot():
    return Snapshot()


def get_traced_memory():
    return (0, 0)


def reset_peak():
    pass


def get_tracemalloc_memory():
    return 0


def clear_traces():
    pass
