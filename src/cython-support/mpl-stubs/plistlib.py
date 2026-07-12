# Browser stub: matplotlib.font_manager only reads macOS .plist font metadata.
def load(*a, **k):
    raise OSError("plistlib not available")
def loads(*a, **k):
    raise OSError("plistlib not available")
def dump(*a, **k):
    raise OSError("plistlib not available")
def dumps(*a, **k):
    raise OSError("plistlib not available")
