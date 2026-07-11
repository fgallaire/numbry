# wasthon: minimal stub of numpy's build-generated __config__ module.
def show_config(mode="stdout"):
    if mode == "dicts":
        return {}
    return None
def _check_pyyaml():
    raise RuntimeError("show_config('dicts') needs no yaml here")
