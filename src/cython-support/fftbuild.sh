#!/usr/bin/env bash
# Build the combined numpy + scipy.fft wasm (build/npfft.{mjs,wasm}): the numpy
# C core + numpy.random (so `import numpy` works) AND scipy.fft's single pybind11
# extension (pypocketfft, over the header-only pocketfft in scipy/_lib/pocketfft)
# in ONE module. scipy.fft is Fortran-free and has no Fortran-wall runtime deps;
# pybind11 is the same C++ binding layer matplotlib crosses (pin 2.13.6), driven
# by cython-support/pybind11_compat.h + the header seds replicated from mplbuild.sh.
#
# Usage: ./fftbuild.sh <scipy-1.14.1-source-tree> <numpy-2.5.1-source-tree>
#
# Prerequisites (produced by earlier phases): numpy-probe/obj/*.o,
# build/nprnd-obj/*.o, build/wasthon.o; pybind11 headers ($PYBIND11_INC);
# scipy/_lib/pocketfft submodule checked out (build.sh inits it).
set -u
ND="${1:?path to scipy 1.14.1 source tree}"
NP="${2:?path to numpy 2.5.1 source tree}"
CS="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$CS/.." && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/build/fft-obj"; mkdir -p "$OUT"
cd "$ROOT" && source external/emsdk/emsdk_env.sh >/dev/null 2>&1

PYBIND11_INC="${PYBIND11_INC:-$(python3 -c 'import pybind11; print(pybind11.get_include())' 2>/dev/null)}"
[ -f "$PYBIND11_INC/pybind11/pybind11.h" ] || { echo "pybind11 headers not found at $PYBIND11_INC"; exit 1; }

# Local, patched copy of the pybind11 headers (never mutate the shared install).
# Same seds as mplbuild.sh — what lets pybind11 build on the handle bridge.
PB="$OUT/pybind11-inc"; rm -rf "$PB"; mkdir -p "$PB"; cp -r "$PYBIND11_INC/pybind11" "$PB/"
P="$PB/pybind11"
sed -i 's/if (m_trace) {/if (m_trace \&\& 0) {/' "$P/pytypes.h"
sed -i 's/reinterpret_cast<PyTracebackObject \*>/reinterpret_cast<__wasthon_tb *>/' "$P/pytypes.h"
sed -i 's/return o->ob_type == \&PyStaticMethod_Type;/return Py_TYPE(o) == \&PyStaticMethod_Type;/' "$P/pytypes.h"
sed -i 's/src\.ptr()->ob_type->tp_as_number/Py_TYPE(src.ptr())->tp_as_number/' "$P/cast.h"
sed -i 's/type->tp_as_async = \&heap_type->as_async;/\/* wasthon: no as_async *\//' "$P/detail/class.h"
sed -i 's/= reinterpret_cast<PyCFunction>(reinterpret_cast<void (\*)()>(dispatcher));/= reinterpret_cast<void *>(dispatcher);/' "$P/pybind11.h"
sed -i 's/tstate = PyGILState_GetThisThreadState();/tstate = (PyThreadState *)PyGILState_GetThisThreadState();/' "$P/gil.h"

# pypocketfft's raw-C-API method tables use (PyCFunction) casts the bridge's
# void* ml_meth rejects in C++ (good_size / prev_good_size).
PYP="$OUT/pypocketfft.cxx"
cp "$ND/scipy/fft/_pocketfft/pypocketfft.cxx" "$PYP"
sed -i 's/( *PyCFunction *)/(void *)/g' "$PYP"

NPINC="-I $ROOT/numpy-probe/gen -I $ROOT/numpy-probe -I $NP/numpy/_core/include -I $NP/numpy/_core/include/numpy -I $NP/numpy/_core/src/common"
# Single-threaded wasm: compile pocketfft's threading out (default nthreads=1
# never spawns, but this drops the <thread>/<mutex> includes entirely).
em++ -O1 -std=c++17 -c -DNPY_NO_DEPRECATED_API=0 -DPOCKETFFT_NO_MULTITHREADING \
  -DPOCKETFFT_CACHE_SIZE=16 -DPY_ARRAY_UNIQUE_SYMBOL=_scipy_fft_ARRAY_API \
  -include "$CS/pybind11_compat.h" -include "$CS/fft_compat.h" \
  -I "$SRC" -I "$CS" -I "$PB" -I "$ND/scipy/_lib/pocketfft" $NPINC \
  "$PYP" -o "$OUT/pypocketfft.o" 2>"$OUT/pypocketfft_cc.txt"
N=$(grep -c 'error:' "$OUT/pypocketfft_cc.txt" || true)
if [ "$N" != 0 ]; then echo "pypocketfft: errors=$N"; grep -m5 'error:' "$OUT/pypocketfft_cc.txt"; exit 1; fi
echo "pypocketfft: OK"

# link stubs for pybind11's error/traceback + import machinery (see fft_stub.c)
emcc -O1 -c -I "$SRC" "$CS/fft_stub.c" -o "$OUT/fft_stub.o" 2>"$OUT/fft_stub_cc.txt"
N=$(grep -c 'error:' "$OUT/fft_stub_cc.txt" || true)
if [ "$N" != 0 ]; then echo "fft_stub: errors=$N"; grep -m5 'error:' "$OUT/fft_stub_cc.txt"; exit 1; fi
echo "fft_stub: OK"

# scipy/__init__.py probes `from scipy._lib._ccallback import LowLevelCallable`
# (its first extension import) — so npfft must carry _ccallback_c too, else
# scipy raises "extension modules cannot be imported". Reuse the object the
# ndimage phase already Cythonised (build.sh runs ndbuild before fftbuild).
CCB="$ROOT/build/nd-obj/scipy__lib__ccallback_c.o"
[ -f "$CCB" ] || CCB="$ROOT/build/sp-obj/scipy__lib__ccallback_c.o"
[ -f "$CCB" ] || { echo "need _ccallback_c.o from the ndimage/special phase"; exit 1; }
# numpy.fft's C backend, so `import numpy.fft` works (the suite compares
# scipy.fft against numpy.fft.fftfreq/fftshift as reference). Reuse the object
# the ndimage phase already compiled.
PFU="$ROOT/build/nd-obj/_pocketfft_umath.o"
[ -f "$PFU" ] || PFU="$ROOT/build/sp-obj/_pocketfft_umath.o"
[ -f "$PFU" ] || { echo "need _pocketfft_umath.o from the ndimage/special phase"; exit 1; }

# ---- link: numpy core + numpy.random + pypocketfft + _ccallback_c + wasthon
NR="$ROOT/build/nprnd-obj"
EXP='"_PyInit__multiarray_umath","_wasthon_init","_wasthon_module_create","_malloc","_free","_PyInit__common","_PyInit_bit_generator","_PyInit__mt19937","_PyInit__philox","_PyInit__pcg64","_PyInit__sfc64","_PyInit__bounded_integers","_PyInit__generator","_PyInit_mtrand","_PyInit_pypocketfft","_PyInit__ccallback_c","_PyInit__pocketfft_umath"'
CY="$NR/_common.o $NR/bit_generator.o $NR/_mt19937.o $NR/_philox.o $NR/_pcg64.o $NR/_sfc64.o $NR/_bounded_integers.o $NR/_generator.o $NR/mtrand.o"
ALGO="$NR/mt19937.o $NR/mt19937-jump.o $NR/philox.o $NR/pcg64.o $NR/sfc64.o $NR/legacy-distributions.o"
emcc -O1 "$ROOT"/numpy-probe/obj/*.o "$ROOT/build/wasthon.o" "$NR/tanh_stub.o" $CY $ALGO "$NR"/npyrandom/*.o "$OUT/pypocketfft.o" "$OUT/fft_stub.o" "$CCB" "$PFU" \
  --js-library "$SRC/wasthon.js" --js-library "$CS/cython_support.js" \
  -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -sSTACK_SIZE=5242880 --profiling-funcs \
  -Wl,--allow-multiple-definition -s EXPORTED_FUNCTIONS="[$EXP]" \
  -s ERROR_ON_UNDEFINED_SYMBOLS=0 \
  -s EXPORTED_RUNTIME_METHODS='["HEAPU8","HEAP32","UTF8ToString","stringToUTF8","lengthBytesUTF8","wasmTable"]' \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=npfft \
  -o "$ROOT/build/npfft.mjs" 2>"$OUT/link_err.txt"
echo "link exit=$? errors=$(grep -c 'error:' "$OUT/link_err.txt")"
grep "undefined symbol" "$OUT/link_err.txt" | sed 's/.*undefined symbol: //' | sort -u
ls -la "$ROOT/build/npfft.wasm" 2>/dev/null | awk '{print "wasm:", $5, "bytes"}'
