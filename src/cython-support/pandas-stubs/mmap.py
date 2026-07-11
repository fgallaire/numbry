"""Minimal mmap stub: pandas.io.common imports it at module level but only
uses it when memory_map=True (never the default in the browser)."""

ACCESS_DEFAULT = 0
ACCESS_READ = 1
ACCESS_WRITE = 2
ACCESS_COPY = 3
PAGESIZE = 4096
ALLOCATIONGRANULARITY = 4096


class mmap:
    def __init__(self, *args, **kwargs):
        raise OSError("mmap is not supported in the browser")
