# Browser implementation of the stdlib zoneinfo module (absent from Brython):
# ZoneInfo backed by dateutil's TZif parser over the page's build-extracted
# zoneinfo dict (window.DATEUTIL_ZONEINFO) — real tzinfo objects, same IANA
# data. pandas/conftest.py imports it unconditionally.
import base64
from io import BytesIO

from dateutil.tz import tzfile as _tzfile

__all__ = ["ZoneInfo", "ZoneInfoNotFoundError", "InvalidTZPathWarning",
           "available_timezones", "reset_tzpath", "TZPATH"]


class ZoneInfoNotFoundError(KeyError):
    pass


class InvalidTZPathWarning(RuntimeWarning):
    pass


def _data(key):
    try:
        from browser import window
        return base64.b64decode(window.DATEUTIL_ZONEINFO[key])
    except Exception:
        raise ZoneInfoNotFoundError("No time zone found with key %s" % key)


class ZoneInfo(_tzfile):
    # CPython's constructor caches per key: ZoneInfo("UTC") is ZoneInfo("UTC")
    # (pandas' is_utc/tz_compare rely on that identity).
    _cache = {}

    def __new__(cls, key):
        inst = cls._cache.get(key)
        if inst is None:
            inst = super().__new__(cls)
            cls._cache[key] = inst
        return inst

    def __init__(self, key):
        if getattr(self, "_key", None) == key:
            return  # cached instance, already built
        super().__init__(BytesIO(_data(key)), filename=key)
        self._key = key

    @property
    def key(self):
        return self._key

    @classmethod
    def no_cache(cls, key):
        obj = _tzfile.__new__(cls)
        _tzfile.__init__(obj, BytesIO(_data(key)), filename=key)
        obj._key = key
        return obj

    @classmethod
    def clear_cache(cls, *, only_keys=None):
        if only_keys is None:
            cls._cache.clear()
        else:
            for k in only_keys:
                cls._cache.pop(k, None)

    @classmethod
    def from_file(cls, fobj, key=None):
        obj = _tzfile.__new__(cls)
        _tzfile.__init__(obj, fobj, filename=key)
        obj._key = key
        return obj

    def __repr__(self):
        return "zoneinfo.ZoneInfo(key=%r)" % (self._key,)

    def __str__(self):
        return self._key if self._key is not None else super().__str__()


def available_timezones():
    try:
        from browser import window
        return {k for k in window.Object.keys(window.DATEUTIL_ZONEINFO)
                if k != 'METADATA'}
    except Exception:
        return set()


TZPATH = ()


def reset_tzpath(to=None):
    pass
