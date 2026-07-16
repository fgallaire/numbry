"""Minimal ctypes stand-in for the numpy VFS (wasm has no real ctypes).

numpy.random._common.prepare_ctypes builds its `interface` namedtuple from
c_void_p(addr), cast(addr, CFUNCTYPE(...)) — the addresses are wasm
linear-memory pointers and the function pointers are wasm table indices, so
the values are meaningful; only the C *call* machinery doesn't exist here.
The bit-generator test suite checks the interface's construction and
caching, never a call. Same spirit as the _umath_linalg VFS stub.
"""


class _SimpleCData:
    def __init__(self, value=None):
        self.value = value

    def __repr__(self):
        return f"{type(self).__name__}({self.value!r})"


class c_void_p(_SimpleCData):
    pass


class c_uint32(_SimpleCData):
    pass


class c_uint64(_SimpleCData):
    pass


class c_double(_SimpleCData):
    pass


class _CFuncPtr:
    _restype_ = None
    _argtypes_ = ()

    def __init__(self, address=0):
        self.value = address

    def __call__(self, *args):
        raise NotImplementedError(
            "wasthon ctypes stub: C function calls are not supported")


def CFUNCTYPE(restype, *argtypes):
    return type("CFunctionType", (_CFuncPtr,),
                {"_restype_": restype, "_argtypes_": argtypes})


def cast(obj, typ):
    value = getattr(obj, "value", obj)
    return typ(value)
