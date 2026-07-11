#!/usr/bin/env bash
# Build the combined numpy + numpy.random wasm (build/nprnd.{mjs,wasm}): the
# numpy C core plus all 9 numpy.random Cython extensions in ONE module (one
# shared memory, so the _ARRAY_API and "BitGenerator" capsules are valid
# cross-module). This is what loader/numpy.html, test-numpy-random.html and
# the numpy.random rows of test-numpy-all.html load.
#
# Usage: ./nprnd.sh <numpy-2.5.1-source-tree>
#
# Prerequisites:
#   - numpy-probe/obj/*.o — run  numpy-probe/probe.sh <numpy-src>  first
#     (compiles the ~150-file numpy core against the bridge).
#   - Cython 3.0.x importable by python3 (or CYTHON_PYTHONPATH set).
#   - emcc (external/emsdk, auto-sourced).
set -u
NP="${1:?path to numpy 2.5.1 source tree}"
CS="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$CS/.." && pwd)"
SRC="$ROOT/src"; GEN="$ROOT/numpy-probe/gen"; OBJ="$ROOT/numpy-probe/obj"
R="$NP/numpy/random"
OUT="$ROOT/build/nprnd-obj"; mkdir -p "$OUT"
command -v emcc >/dev/null 2>&1 || source "$ROOT/external/emsdk/emsdk_env.sh" 2>/dev/null
[ -d "$OBJ" ] && [ -n "$(ls "$OBJ"/*.o 2>/dev/null)" ] || { echo "FATAL: $OBJ empty — run numpy-probe/probe.sh first"; exit 1; }

# ---- source prep 1: tempita-generate _bounded_integers.{pyx,pxd} from .in.
# Template.from_filename chokes on bytes; feed it the text ourselves.
tempita() {
  PYTHONPATH="${CYTHON_PYTHONPATH:-}" python3 -c "
import sys
from Cython import Tempita
open(sys.argv[2], 'w').write(Tempita.Template(open(sys.argv[1]).read()).substitute())
" "$1" "$2"
}
for f in _bounded_integers.pyx _bounded_integers.pxd; do
  if [ ! -f "$R/$f" ] || [ "$R/$f.in" -nt "$R/$f" ]; then
    tempita "$R/$f.in" "$R/$f" && echo "tempita: $f generated"
  fi
done

# ---- the 9 Cython modules: cythonize (full dotted module name so the def
# carries it) + P1-P4 recipe patches + compile against numpy's headers.
NPINC="-I $SRC -I $CS -I $GEN -I $NP/numpy/_core/include -I $NP/numpy/_core/include/numpy -I $NP/numpy/_core/src/common -I $R -I $R/src"
PP="-DCYTHON_USE_TYPE_SPECS=1 -DCYTHON_USE_MODULE_STATE=0 -DCYTHON_FAST_THREAD_STATE=0 -DCYTHON_USE_EXC_INFO_STACK=0 -DCYTHON_USE_TYPE_SLOTS=0 -DCYTHON_USE_PYTYPE_LOOKUP=0 -DCYTHON_USE_UNICODE_INTERNALS=0 -DCYTHON_USE_PYLONG_INTERNALS=0 -DCYTHON_USE_PYLIST_INTERNALS=0 -DCYTHON_ASSUME_SAFE_MACROS=0 -DCYTHON_UNPACK_METHODS=0 -DCYTHON_AVOID_BORROWED_REFS=1 -DPy_OptimizeFlag=0"
CFLAGS="-O1 -c -DNDEBUG -DPy_PYTHON_H -DNPY_NO_DEPRECATED_API=0 -DCYTHON_VECTORCALL_TPNEW=0 $PP -Wno-macro-redefined -Wno-int-conversion -Wno-incompatible-pointer-types -include $SRC/patchlevel.h -include $CS/cython_compat.h -include $CS/scipy_compat.h $NPINC"
MODS="_common bit_generator _bounded_integers _mt19937 _philox _pcg64 _sfc64 _generator mtrand"
for MOD in $MODS; do
  C="$OUT/$MOD.c"
  rm -f "$C"
  PYTHONPATH="${CYTHON_PYTHONPATH:-}" python3 -m cython -3 -I "$NP" -I "$R" \
    --module-name "numpy.random.$MOD" "$R/$MOD.pyx" -o "$C" 2>"$OUT/${MOD}_cy.txt"
  [ -f "$C" ] || { echo "$MOD: CYTHONIZE FAIL"; tail -5 "$OUT/${MOD}_cy.txt"; exit 1; }
  # P1-P4 — same patches as cybuild.sh (see the comments there).
  sed -i 's/def->ml_meth(/((PyCFunction)def->ml_meth)(/g' "$C"
  perl -0pi -e 's/__Pyx_copy_object_array\(src, \(\(PyListObject\*\)res\)->ob_item, n\);/{ Py_ssize_t _i; for(_i=0;_i<n;_i++){ Py_INCREF(src[_i]); PyList_SET_ITEM(res,_i,src[_i]); } }/g' "$C"
  sed -i 's/basicsize = PyLong_AsSsize_t(py_basicsize);/basicsize = PyLong_AsSsize_t(py_basicsize); basicsize = (Py_ssize_t)size;/' "$C"
  perl -0pi -e 's/\(\(size_t\)\(basicsize \+ itemsize\) < size\)/(0)/g' "$C"
  perl -0pi -e 's/if \(basicsize != expected_basicsize\) \{/if (0) {/g' "$C"
  L=$(grep -n "^  #define CYTHON_COMPILING_IN_CPYTHON 1$" "$C" | head -1 | cut -d: -f1)
  [ -n "$L" ] && sed -i "${L}s/#define CYTHON_COMPILING_IN_CPYTHON 1/#define CYTHON_COMPILING_IN_CPYTHON 0/" "$C" \
    || echo "$MOD: WARN no IN_CPYTHON line"
  emcc $CFLAGS "$C" -o "$OUT/$MOD.o" 2>"$OUT/${MOD}_cc.txt"
  NE=$(grep -c "error:" "$OUT/${MOD}_cc.txt" || true)
  echo "$MOD: compile errors=$NE"
  [ "$NE" = "0" ] || { grep "error:" "$OUT/${MOD}_cc.txt" | head -6; exit 1; }
done

# ---- the bit-generator algorithm C + npyrandom distributions (plain C).
for f in mt19937/mt19937 mt19937/mt19937-jump philox/philox pcg64/pcg64 sfc64/sfc64 legacy/legacy-distributions; do
  b=$(basename "$f")
  emcc $CFLAGS "$R/src/$f.c" -o "$OUT/$b.o" 2>"$OUT/${b}_cc.txt" \
    || { echo "$b: COMPILE FAIL"; grep "error:" "$OUT/${b}_cc.txt" | head -4; exit 1; }
done
mkdir -p "$OUT/npyrandom"
for f in distributions logfactorial random_hypergeometric random_mvhg_count random_mvhg_marginals; do
  emcc $CFLAGS "$R/src/distributions/$f.c" -o "$OUT/npyrandom/$f.o" 2>"$OUT/npyrandom/${f}_cc.txt" \
    || { echo "npyrandom/$f: COMPILE FAIL"; grep "error:" "$OUT/npyrandom/${f}_cc.txt" | head -4; exit 1; }
done
echo "algo + npyrandom: OK"

# ---- tanh stub (numpy core's loops_hyperbolic dispatch isn't built) + wasthon.o.
emcc $CFLAGS "$CS/tanh_stub.c" -o "$OUT/tanh_stub.o"
if [ ! -f "$ROOT/build/wasthon.o" ]; then
  # wasthon.c must be compiled from the repo root (its include of wasthon.h
  # resolves against -I . -I src; compiling from build/ breaks it).
  (cd "$ROOT" && cp src/wasthon.c . && emcc -O3 -c -I . -I src wasthon.c -o build/wasthon.o && rm -f wasthon.c)
  echo "build/wasthon.o: built"
fi

# ---- link: numpy core + the 9 modules + algo + npyrandom, every PyInit exported.
EXP='["_PyInit__multiarray_umath","_PyInit__common","_PyInit_bit_generator","_PyInit__mt19937","_PyInit__philox","_PyInit__pcg64","_PyInit__sfc64","_PyInit__bounded_integers","_PyInit__generator","_PyInit_mtrand","_wasthon_init","_wasthon_module_create","_malloc","_free"]'
CY=""; for MOD in $MODS; do CY="$CY $OUT/$MOD.o"; done
ALGO="$OUT/mt19937.o $OUT/mt19937-jump.o $OUT/philox.o $OUT/pcg64.o $OUT/sfc64.o $OUT/legacy-distributions.o"
emcc -O1 $OBJ/*.o $OUT/tanh_stub.o $CY $ALGO "$OUT"/npyrandom/*.o "$ROOT/build/wasthon.o" \
  --js-library "$SRC/wasthon.js" --js-library "$CS/cython_support.js" \
  -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -sSTACK_SIZE=5242880 \
  -s EXPORTED_FUNCTIONS="$EXP" -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=nprnd \
  -o "$ROOT/build/nprnd.mjs" 2>"$OUT/link_err.txt"
RC=$?
echo "link exit=$RC  undefined=$(grep -c 'undefined symbol' "$OUT/link_err.txt")  errors=$(grep -c 'error:' "$OUT/link_err.txt")"
grep -E "undefined symbol|error:" "$OUT/link_err.txt" | head -12
ls -la "$ROOT/build/nprnd.wasm" 2>/dev/null | awk '{print "wasm:", $5, "bytes"}'
exit $RC
