#!/usr/bin/env bash
# Build numpy + scipy.cluster wasm (build/npcl.{mjs,wasm}): numpy C core +
# numpy.random + scipy.cluster's three Cython extensions (_vq, _hierarchy,
# _optimal_leaf_ordering) in ONE module. Fortran-free; scipy.cluster's only
# scipy dependency is scipy.spatial.distance (pdist/cdist/squareform), served
# as a numpy façade in the VFS (no pybind11 distance backend needed).
#
# Usage: ./clbuild.sh <scipy-1.14.1-source-tree> <numpy-2.5.1-source-tree>
set -u
ND="${1:?path to scipy 1.14.1 source tree}"
NP="${2:?path to numpy 2.5.1 source tree}"
CS="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$CS/.." && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/build/cl-obj"; mkdir -p "$OUT"
cd "$ROOT" && source external/emsdk/emsdk_env.sh >/dev/null 2>&1

CLSRC="$ND/scipy/cluster"
PP="-DCYTHON_USE_TYPE_SPECS=1 -DCYTHON_USE_MODULE_STATE=0 -DCYTHON_FAST_THREAD_STATE=0 -DCYTHON_USE_EXC_INFO_STACK=0 -DCYTHON_USE_TYPE_SLOTS=0 -DCYTHON_USE_PYTYPE_LOOKUP=0 -DCYTHON_USE_UNICODE_INTERNALS=0 -DCYTHON_USE_PYLONG_INTERNALS=0 -DCYTHON_USE_PYLIST_INTERNALS=0 -DCYTHON_ASSUME_SAFE_MACROS=0 -DCYTHON_UNPACK_METHODS=0 -DCYTHON_AVOID_BORROWED_REFS=1 -DPy_OptimizeFlag=0"
NDINC="-I $SRC -I $CS -I $ROOT/numpy-probe/gen -I $ROOT/numpy-probe -I $NP/numpy/_core/include -I $NP/numpy/_core/include/numpy -I $NP/numpy/_core/src/common -I $ND/scipy/_lib/src -I $ND/scipy/_build_utils/src"
CFLAGS="-O1 -c -DNDEBUG -DPy_PYTHON_H -DNPY_NO_DEPRECATED_API=0 -DCYTHON_VECTORCALL_TPNEW=0 $PP -Wno-macro-redefined -Wno-int-conversion -Wno-incompatible-pointer-types -include $SRC/patchlevel.h -include $CS/cython_compat.h -include $CS/scipy_compat.h $NDINC"

FAILED=""

build_pyx() {  # $1 = dotted module name, $2 = pyx path, $3 = "pxd" to bind the adjacent .pxd
  local MOD="${1##*.}" C="$OUT/${1//./_}.c"
  rm -f "$C"
  if [ "${3:-}" = "pxd" ]; then
    # Cythonize under the SHORT name from the pyx's own directory: the only
    # spelling under which Cython binds the adjacent .pxd (with the dotted
    # --module-name it looks for scipy/ndimage/_cytest.pxd and finds nothing),
    # and the .pxd is what makes Cython emit the __pyx_capi__ exports that
    # LowLevelCallable.from_cython consumes. Same shape as upstream meson
    # (short names from src/). The pages rename the module def to the dotted
    # name at PyInit time.
    ( cd "$(dirname "$2")" && PYTHONPATH="${CYTHON_PYTHONPATH:-}" python3 -m cython -3 -I "$NP" -I "$CS/blas_shim" \
      "$(basename "$2")" -o "$C" ) 2>"$OUT/${MOD}_cy.txt"
  else
  PYTHONPATH="${CYTHON_PYTHONPATH:-}" python3 -m cython -3 -I "$NP" -I "$CS/blas_shim" \
    --module-name "$1" "$2" -o "$C" 2>"$OUT/${MOD}_cy.txt"
  fi
  if [ ! -f "$C" ]; then echo "$1: CYTHONIZE FAIL"; grep -m3 "error" "$OUT/${MOD}_cy.txt"; return 1; fi
  sed -i 's/def->ml_meth(/((PyCFunction)def->ml_meth)(/g' "$C"
  perl -0pi -e 's/__Pyx_copy_object_array\(src, \(\(PyListObject\*\)res\)->ob_item, n\);/{ Py_ssize_t _i; for(_i=0;_i<n;_i++){ Py_INCREF(src[_i]); PyList_SET_ITEM(res,_i,src[_i]); } }/g' "$C"
  perl -0pi -e 's/#define __Pyx_ArgsSlice_FASTCALL\(args, start, stop\) PyTuple_GetSlice\(args, start, stop\)/#define __Pyx_ArgsSlice_FASTCALL(args, start, stop) __Pyx_PyTuple_FromArray(&__Pyx_Arg_FASTCALL(args, start), stop - start)/g' "$C"
  perl -0pi -e 's|(/\* TupleAndListFromArray(?:\.proto)? \*/\n)#if CYTHON_COMPILING_IN_CPYTHON|${1}#if 1|g' "$C"
  perl -0pi -e 's/__Pyx_copy_object_array\(src, \(\(PyTupleObject\*\)res\)->ob_item, n\);/{ Py_ssize_t _i; for(_i=0;_i<n;_i++){ Py_INCREF(src[_i]); __Pyx_PyTuple_SET_ITEM(res,_i,src[_i]); } }/g' "$C"
  sed -i 's/basicsize = PyLong_AsSsize_t(py_basicsize);/basicsize = PyLong_AsSsize_t(py_basicsize); basicsize = (Py_ssize_t)size;/' "$C"
  perl -0pi -e 's/\(\(PySliceObject\*\)([A-Za-z0-9_]+)\)->(start|stop|step)/__wasthon_slice_$2($1)/g' "$C"
  perl -0pi -e 's/\(\(size_t\)\(basicsize \+ itemsize\) < size\)/(0)/g' "$C"
  perl -0pi -e 's/if \(basicsize != expected_basicsize\) \{/if (0) {/g' "$C"
  local L=$(grep -n "^  #define CYTHON_COMPILING_IN_CPYTHON 1$" "$C" | head -1 | cut -d: -f1)
  [ -n "$L" ] && sed -i "${L}s/#define CYTHON_COMPILING_IN_CPYTHON 1/#define CYTHON_COMPILING_IN_CPYTHON 0/" "$C"
  emcc $CFLAGS "$C" -o "${C%.c}.o" 2>"$OUT/${MOD}_cc.txt"
  local NE=$(grep -c "error:" "$OUT/${MOD}_cc.txt" || true)
  if [ "$NE" != "0" ]; then echo "$1: compile errors=$NE"; grep -m3 "error:" "$OUT/${MOD}_cc.txt"; return 1; fi
  echo "$1: OK"
}

build_pyx "scipy.cluster._vq" "$CLSRC/_vq.pyx" || FAILED="$FAILED _vq"
build_pyx "scipy.cluster._hierarchy" "$CLSRC/_hierarchy.pyx" || FAILED="$FAILED _hierarchy"
build_pyx "scipy.cluster._optimal_leaf_ordering" "$CLSRC/_optimal_leaf_ordering.pyx" || FAILED="$FAILED _optimal_leaf_ordering"
build_pyx "scipy._lib._ccallback_c" "$ND/scipy/_lib/_ccallback_c.pyx" || FAILED="$FAILED _ccallback_c"

# BLAS gemm shim (clean signature -> f2c dgemm_/sgemm_ in lapack_lite).
emcc $CFLAGS "$CS/cython_blas_shim.c" -o "$OUT/cython_blas_shim.o" 2>"$OUT/blas_shim_cc.txt" || FAILED="$FAILED blas_shim"

echo "=== compile done. FAILED:${FAILED:- none} ==="
ls "$OUT"/*.o 2>/dev/null | wc -l
if [ -n "$FAILED" ]; then echo "compile failures — not linking"; exit 1; fi

# ---- link -> build/npcl.{mjs,wasm}
NR="$ROOT/build/nprnd-obj"
EXP='"_PyInit__multiarray_umath","_PyInit__umath_linalg","_wasthon_init","_wasthon_module_create","_malloc","_free","_PyInit__common","_PyInit_bit_generator","_PyInit__mt19937","_PyInit__philox","_PyInit__pcg64","_PyInit__sfc64","_PyInit__bounded_integers","_PyInit__generator","_PyInit_mtrand","_PyInit__vq","_PyInit__hierarchy","_PyInit__optimal_leaf_ordering","_PyInit__ccallback_c"'
CY="$NR/_common.o $NR/bit_generator.o $NR/_mt19937.o $NR/_philox.o $NR/_pcg64.o $NR/_sfc64.o $NR/_bounded_integers.o $NR/_generator.o $NR/mtrand.o"
ALGO="$NR/mt19937.o $NR/mt19937-jump.o $NR/philox.o $NR/pcg64.o $NR/sfc64.o $NR/legacy-distributions.o"
emcc -O1 "$ROOT"/numpy-probe/obj/*.o "$ROOT/build/linalg-obj"/*.o "$ROOT/build/wasthon.o" "$NR/tanh_stub.o" $CY $ALGO "$NR"/npyrandom/*.o "$OUT"/*.o \
  --js-library "$SRC/wasthon.js" --js-library "$CS/cython_support.js" \
  -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -sSTACK_SIZE=5242880 --profiling-funcs \
  -Wl,--allow-multiple-definition -s EXPORTED_FUNCTIONS="[$EXP]" \
  -s EXPORTED_RUNTIME_METHODS='["HEAPU8","HEAP32","UTF8ToString","stringToUTF8","lengthBytesUTF8","wasmTable"]' \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=npcl \
  -o "$ROOT/build/npcl.mjs" 2>"$OUT/link_err.txt"
echo "link exit=$? errors=$(grep -c 'error:' "$OUT/link_err.txt")"
grep "undefined symbol" "$OUT/link_err.txt" | sed 's/.*undefined symbol: //' | sort -u
ls -la "$ROOT/build/npcl.wasm" 2>/dev/null | awk '{print "wasm:", $5, "bytes"}'
