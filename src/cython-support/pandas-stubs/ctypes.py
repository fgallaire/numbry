"""Minimal ctypes stub for the wasthon bridge: pandas.errors imports ctypes
at module level but only touches ctypes.WinError inside a Windows-only
error-message path that never runs here."""

def WinError(*args, **kwargs):
    raise OSError("ctypes.WinError is not available on this platform")
