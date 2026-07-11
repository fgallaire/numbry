"""Stand-in for the meson-generated version module: the versioneer fallback
shells out to git (subprocess/os.pipe, unavailable in the browser)."""
__version__ = "2.2.3"
__git_version__ = None
