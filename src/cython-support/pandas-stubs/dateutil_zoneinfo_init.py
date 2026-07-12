# -*- coding: utf-8 -*-
# wasthon replacement for dateutil/zoneinfo/__init__.py: the upstream module
# tarfile-walks the 619-member zoneinfo tarball and parses EVERY tzfile at
# construction — 2 minutes of pure-Python tarfile under Brython, paid at
# `import pandas`. The build extracts the tarball into a JS dict
# (window.DATEUTIL_ZONEINFO = {name: base64(tzif)}); zones parse lazily.
import warnings
import json
import base64

from io import BytesIO

from dateutil.tz import tzfile as _tzfile

__all__ = ["get_zonefile_instance", "gettz", "gettz_db_metadata"]

ZONEFILENAME = "dateutil-zoneinfo.tar.gz"
METADATA_FN = 'METADATA'


class tzfile(_tzfile):
    def __reduce__(self):
        return (gettz, (self._filename,))


def _raw_zones():
    # {zone_name: base64(tzif bytes)}, extracted from the tarball at build time
    try:
        from browser import window
        zd = window.DATEUTIL_ZONEINFO
        return {name: zd[name] for name in window.Object.keys(zd)}
    except Exception:
        warnings.warn("DATEUTIL_ZONEINFO data blob not loaded; "
                      "dateutil zoneinfo will be empty")
        return {}


class _LazyZones(dict):
    """A zones dict whose tzfile values parse on first access."""
    def __init__(self, raw):
        super().__init__()
        self._raw = raw

    def __missing__(self, name):
        b64 = self._raw.get(name)
        if b64 is None:
            raise KeyError(name)
        z = tzfile(BytesIO(base64.b64decode(b64)), filename=name)
        self[name] = z
        return z

    def get(self, name, default=None):
        try:
            return self[name]
        except KeyError:
            return default

    def __contains__(self, name):
        return name in self._raw

    def __iter__(self):
        return iter(self._raw)

    def __len__(self):
        return len(self._raw)

    def keys(self):
        return self._raw.keys()

    def items(self):
        return [(k, self[k]) for k in self._raw]

    def values(self):
        return [self[k] for k in self._raw]


def getzoneinfofile_stream():
    # the tarball no longer exists at runtime; ZoneInfoFile ignores its stream
    return None


class ZoneInfoFile(object):
    def __init__(self, zonefile_stream=None):
        raw = _raw_zones()
        md = raw.pop(METADATA_FN, None)
        self.metadata = json.loads(base64.b64decode(md).decode('UTF-8')) if md else None
        self.zones = _LazyZones(raw)

    def get(self, name, default=None):
        """
        Wrapper for :func:`ZoneInfoFile.zones.get`. This is a convenience method
        for retrieving zones from the zone dictionary.

        :param name:
            The name of the zone to retrieve. (Generally IANA zone names)

        :param default:
            The value to return in the event of a missing key.

        .. versionadded:: 2.6.0

        """
        return self.zones.get(name, default)


_CLASS_ZONE_INSTANCE = []


def get_zonefile_instance(new_instance=False):
    if new_instance:
        zif = None
    else:
        zif = getattr(get_zonefile_instance, '_cached_instance', None)

    if zif is None:
        zif = ZoneInfoFile(getzoneinfofile_stream())

        get_zonefile_instance._cached_instance = zif

    return zif


def gettz(name):
    warnings.warn("zoneinfo.gettz() will be removed in future versions, "
                  "to use the dateutil-provided zoneinfo files, instantiate a "
                  "ZoneInfoFile object and use ZoneInfoFile.zones.get() "
                  "instead. See the documentation for details.",
                  DeprecationWarning)

    if len(_CLASS_ZONE_INSTANCE) == 0:
        _CLASS_ZONE_INSTANCE.append(ZoneInfoFile(getzoneinfofile_stream()))
    return _CLASS_ZONE_INSTANCE[0].zones.get(name)


def gettz_db_metadata():
    warnings.warn("zoneinfo.gettz_db_metadata() will be removed in future "
                  "versions, to use the dateutil-provided zoneinfo files, "
                  "ZoneInfoFile object and query the 'metadata' attribute "
                  "instead. See the documentation for details.",
                  DeprecationWarning)

    if len(_CLASS_ZONE_INSTANCE) == 0:
        _CLASS_ZONE_INSTANCE.append(ZoneInfoFile(getzoneinfofile_stream()))
    return _CLASS_ZONE_INSTANCE[0].metadata
