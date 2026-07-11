#!/usr/bin/env bash
# Build the combined numpy + pandas._libs wasm (build/nppd.{mjs,wasm}): the
# numpy C core, the 9 numpy.random extensions AND all 45 pandas._libs
# extensions in ONE module (one shared memory: _ARRAY_API, the pandas
# datetime capsule and ujson's module state are valid cross-module). This is
# what loader/test-pandas.html loads.
#
# Usage: ./pdbuild.sh <pandas-2.2.3-source-tree> <numpy-2.5.1-source-tree>
#
# Prerequisites:
#   - numpy-probe/obj/*.o   — run  numpy-probe/probe.sh <numpy-src>  first.
#   - build/nprnd-obj/*.o   — run  cython-support/nprnd.sh <numpy-src>.
#   - build/wasthon.o       — any build.sh target compiles it.
#   - Cython 3.0.x importable by python3 (or CYTHON_PYTHONPATH set).
#
# The per-file patches mirror nprnd.sh's P1-P4 plus:
#   P5  FASTCALL args-slice: the portability fallback reads the C args array
#       as a tuple handle; use the FromArray variant.
#   P6  direct PySliceObject field reads are garbage on bridge handles;
#       route through the __wasthon_slice_* helpers.
#   PDRN  four plain-C symbols collide with numpy's own (one with a
#       DIFFERENT signature: wasm-ld resolved its address to 0 and every
#       get_unit_from_dtype call trapped "null function") — rename pandas'.
#   UNIQUE_SYMBOL hoist: the pandas C sources include their own header
#       (which reaches numpy's __multiarray_api.h) BEFORE their
#       NO_IMPORT_ARRAY/PY_ARRAY_UNIQUE_SYMBOL defines, so each unit got the
#       static PyArray_RUNTIME_VERSION=0 copy and clang constant-folded the
#       npy_2_compat accessors to the 1.x struct layout (dtype metadata read
#       at the wrong offset -> datetime units always 0).
set -u
PD="${1:?path to pandas 2.2.3 source tree}"
NP="${2:?path to numpy 2.5.1 source tree}"
CS="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$CS/.." && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/build/pd-obj"; mkdir -p "$OUT"
W="$ROOT"
cd "$ROOT" && source external/emsdk/emsdk_env.sh >/dev/null 2>&1

PP="-DCYTHON_USE_TYPE_SPECS=1 -DCYTHON_USE_MODULE_STATE=0 -DCYTHON_FAST_THREAD_STATE=0 -DCYTHON_USE_EXC_INFO_STACK=0 -DCYTHON_USE_TYPE_SLOTS=0 -DCYTHON_USE_PYTYPE_LOOKUP=0 -DCYTHON_USE_UNICODE_INTERNALS=0 -DCYTHON_USE_PYLONG_INTERNALS=0 -DCYTHON_USE_PYLIST_INTERNALS=0 -DCYTHON_ASSUME_SAFE_MACROS=0 -DCYTHON_UNPACK_METHODS=0 -DCYTHON_AVOID_BORROWED_REFS=1 -DPy_OptimizeFlag=0"
PDINC="-I $SRC -I $CS -I $ROOT/numpy-probe/gen -I $ROOT/numpy-probe -I $NP/numpy/_core/include -I $NP/numpy/_core/include/numpy -I $NP/numpy/_core/src/common -I $PD/pandas/_libs/include -I $PD/pandas/_libs"
CFLAGS="-O1 -c -DNDEBUG -DPy_PYTHON_H -DNPY_NO_DEPRECATED_API=0 $PP -Wno-macro-redefined -Wno-int-conversion -Wno-incompatible-pointer-types -include $SRC/patchlevel.h -include $CS/cython_compat.h $PDINC"

# import-required Cython modules, in import-dependency order.
# tslibs first (pandas._libs.__init__ pulls interval+tslibs), then the core lot.
TSLIBS="base ccalendar np_datetime dtypes timezones nattype conversion timedeltas tzconversion timestamps fields offsets parsing period strptime vectorized"
LIBS="interval hashtable missing lib tslib algos arrays groupby hashing index indexing internals join ops ops_dispatch properties reshape sparse writers"

build_pyx() {  # $1 = dotted module name, $2 = pyx path
  local MOD="${1##*.}" EXT="${3:-c}" CYX=""
  local C="$OUT/${1//./_}.$EXT"
  [ "$EXT" = "cpp" ] && CYX="--cplus -X always_allow_keywords=true"
  rm -f "$C"
  PYTHONPATH="${CYTHON_PYTHONPATH:-}" python3 -m cython -3 $CYX -I "$NP" -I "$PD" \
    --module-name "$1" "$2" -o "$C" 2>"$OUT/${MOD}_cy.txt"
  if [ ! -f "$C" ]; then echo "$1: CYTHONIZE FAIL"; grep -m3 "error" "$OUT/${MOD}_cy.txt"; return 1; fi
  sed -i 's/def->ml_meth(/((PyCFunction)def->ml_meth)(/g' "$C"
  perl -0pi -e 's/__Pyx_copy_object_array\(src, \(\(PyListObject\*\)res\)->ob_item, n\);/{ Py_ssize_t _i; for(_i=0;_i<n;_i++){ Py_INCREF(src[_i]); PyList_SET_ITEM(res,_i,src[_i]); } }/g' "$C"
  # P5: FASTCALL args are a C array, never a tuple — the portability fallback
  # PyTuple_GetSlice(args,...) reads the array pointer as a handle (NAType()
  # returned NULL with no exception). Use the FromArray variant, un-gate its
  # definition, and route the tuple-struct write through PyTuple_SET_ITEM.
  perl -0pi -e 's/#define __Pyx_ArgsSlice_FASTCALL\(args, start, stop\) PyTuple_GetSlice\(args, start, stop\)/#define __Pyx_ArgsSlice_FASTCALL(args, start, stop) __Pyx_PyTuple_FromArray(&__Pyx_Arg_FASTCALL(args, start), stop - start)/g' "$C"
  perl -0pi -e 's|(/\* TupleAndListFromArray(?:\.proto)? \*/\n)#if CYTHON_COMPILING_IN_CPYTHON|${1}#if 1|g' "$C"
  perl -0pi -e 's/__Pyx_copy_object_array\(src, \(\(PyTupleObject\*\)res\)->ob_item, n\);/{ Py_ssize_t _i; for(_i=0;_i<n;_i++){ Py_INCREF(src[_i]); __Pyx_PyTuple_SET_ITEM(res,_i,src[_i]); } }/g' "$C"
  sed -i 's/basicsize = PyLong_AsSsize_t(py_basicsize);/basicsize = PyLong_AsSsize_t(py_basicsize); basicsize = (Py_ssize_t)size;/' "$C"
  # P6: direct PySliceObject field reads are garbage on bridge handles
  perl -0pi -e 's/\(\(PySliceObject\*\)([A-Za-z0-9_]+)\)->(start|stop|step)/__wasthon_slice_$2($1)/g' "$C"
  perl -0pi -e 's/\(\(size_t\)\(basicsize \+ itemsize\) < size\)/(0)/g' "$C"
  perl -0pi -e 's/if \(basicsize != expected_basicsize\) \{/if (0) {/g' "$C"
  local L=$(grep -n "^  #define CYTHON_COMPILING_IN_CPYTHON 1$" "$C" | head -1 | cut -d: -f1)
  [ -n "$L" ] && sed -i "${L}s/#define CYTHON_COMPILING_IN_CPYTHON 1/#define CYTHON_COMPILING_IN_CPYTHON 0/" "$C"
  if [ "$EXT" = "cpp" ]; then
    # C++ refuses the implicit conversions C allowed: wasthon.h's PyMethodDef
    # ml_meth is void*, so the initializer's final (PyCFunction) cast must
    # become void*; same for PyCodeObject* = PyObject* in __Pyx_PyCode_New.
    sed -i 's/, (PyCFunction)(void\*)(__Pyx_PyCFunction_FastCallWithKeywords)/, (void*)(__Pyx_PyCFunction_FastCallWithKeywords)/g' "$C"
    sed -i 's/, (PyCFunction)__pyx_/, (void*)(PyCFunction)__pyx_/g' "$C"
    sed -i 's/, (PyCFunction)__Pyx_/, (void*)(PyCFunction)__Pyx_/g' "$C"
    perl -0pi -e 's/(\n    result =\n      #if PY_VERSION_HEX)/\n    result = (PyCodeObject *)\n      #if PY_VERSION_HEX/' "$C"
    sed -i 's/vectorcallfunc f = PyVectorcall_Function(func);/vectorcallfunc f = (vectorcallfunc)PyVectorcall_Function(func);/' "$C"
    sed -i 's/__Pyx_CyFunction_func_vectorcall(op) = __Pyx_CyFunction_Vectorcall_/__Pyx_CyFunction_func_vectorcall(op) = (void*)__Pyx_CyFunction_Vectorcall_/g' "$C"
    sed -i 's/PyCFunction meth = f->m_ml->ml_meth;/PyCFunction meth = (PyCFunction)f->m_ml->ml_meth;/' "$C"
    sed -i 's/__pyx_vectorcallfunc vc = __Pyx_CyFunction_func_vectorcall(cyfunc);/__pyx_vectorcallfunc vc = (__pyx_vectorcallfunc)__Pyx_CyFunction_func_vectorcall(cyfunc);/' "$C"
    # the module init must have C linkage or the PyInit_* export is mangled
    sed -i 's/#define __PYX_EXTERN_C extern "C++"/#define __PYX_EXTERN_C extern "C"/' "$C"
  fi
  emcc $CFLAGS "$C" -o "${C%.$EXT}.o" 2>"$OUT/${MOD}_cc.txt"
  local NE=$(grep -c "error:" "$OUT/${MOD}_cc.txt" || true)
  if [ "$NE" != "0" ]; then echo "$1: compile errors=$NE"; grep -m3 "error:" "$OUT/${MOD}_cc.txt"; return 1; fi
  echo "$1: OK"
}

FAILED=""
for M in $TSLIBS; do
  build_pyx "pandas._libs.tslibs.$M" "$PD/pandas/_libs/tslibs/$M.pyx" || FAILED="$FAILED tslibs.$M"
done
for M in $LIBS; do
  build_pyx "pandas._libs.$M" "$PD/pandas/_libs/$M.pyx" || FAILED="$FAILED $M"
done

# window: indexers is plain C, aggregations is Cython C++ (meson cython_language=cpp)
build_pyx "pandas._libs.window.indexers" "$PD/pandas/_libs/window/indexers.pyx" || FAILED="$FAILED window.indexers"
build_pyx "pandas._libs.window.aggregations" "$PD/pandas/_libs/window/aggregations.pyx" cpp || FAILED="$FAILED window.aggregations"

# io lot: testing + parsers (Cython) + the vendored ujson C module (PyInit_json)
build_pyx "pandas._libs.testing" "$PD/pandas/_libs/testing.pyx" || FAILED="$FAILED testing"
build_pyx "pandas._libs.parsers" "$PD/pandas/_libs/parsers.pyx" || FAILED="$FAILED parsers"
UJ=$PD/pandas/_libs/src/vendored/ujson
for F in python/ujson python/objToJSON python/JSONtoObj lib/ultrajsonenc lib/ultrajsondec; do
  B=$(basename $F)
  UJNP=""
  [ "$F" = "python/ujson" ] && UJNP="-DPY_ARRAY_UNIQUE_SYMBOL=UJSON_NUMPY"
  [ "$F" = "python/objToJSON" ] && UJNP="-DNO_IMPORT_ARRAY -DPY_ARRAY_UNIQUE_SYMBOL=UJSON_NUMPY"
  emcc $CFLAGS $UJNP -I "$UJ/lib" "$UJ/$F.c" -o "$OUT/c_ujson_$B.o" 2>"$OUT/c_ujson_${B}_cc.txt" || FAILED="$FAILED ujson_$B"
  N=$(grep -c 'error:' "$OUT/c_ujson_${B}_cc.txt" || true)
  [ "$N" != "0" ] && { echo "ujson_$B: errors=$N"; grep -m3 'error:' "$OUT/c_ujson_${B}_cc.txt"; FAILED="$FAILED ujson_$B"; }
done

PDRN="-Dget_datetime_metadata_from_dtype=pd_get_datetime_metadata_from_dtype -Dadd_minutes_to_datetimestruct=pd_add_minutes_to_datetimestruct -Dget_datetimestruct_days=pd_get_datetimestruct_days -Dis_leapyear=pd_is_leapyear"
# plain-C extensions required at import: pandas_datetime + pandas_parser
emcc $CFLAGS $PDRN -DNO_IMPORT_ARRAY -DPY_ARRAY_UNIQUE_SYMBOL=PANDAS_DATETIME_NUMPY "$PD/pandas/_libs/src/vendored/numpy/datetime/np_datetime.c" -o "$OUT/c_np_datetime.o" 2>"$OUT/c_np_datetime_cc.txt" || FAILED="$FAILED c_np_datetime"
emcc $CFLAGS $PDRN -DNO_IMPORT_ARRAY -DPY_ARRAY_UNIQUE_SYMBOL=PANDAS_DATETIME_NUMPY "$PD/pandas/_libs/src/vendored/numpy/datetime/np_datetime_strings.c" -o "$OUT/c_np_datetime_strings.o" 2>"$OUT/c_np_datetime_strings_cc.txt" || FAILED="$FAILED c_np_datetime_strings"
emcc $CFLAGS $PDRN -DPY_ARRAY_UNIQUE_SYMBOL=PANDAS_DATETIME_NUMPY "$PD/pandas/_libs/src/datetime/pd_datetime.c" -o "$OUT/c_pd_datetime.o" 2>"$OUT/c_pd_datetime_cc.txt" || FAILED="$FAILED c_pd_datetime"
emcc $CFLAGS $PDRN "$PD/pandas/_libs/src/parser/tokenizer.c" -o "$OUT/c_tokenizer.o" 2>"$OUT/c_tokenizer_cc.txt" || FAILED="$FAILED c_tokenizer"
emcc $CFLAGS $PDRN "$PD/pandas/_libs/src/parser/pd_parser.c" -o "$OUT/c_pd_parser.o" 2>"$OUT/c_pd_parser_cc.txt" || FAILED="$FAILED c_pd_parser"
emcc $CFLAGS $PDRN "$PD/pandas/_libs/src/parser/io.c" -o "$OUT/c_io.o" 2>"$OUT/c_io_cc.txt" || FAILED="$FAILED c_io"
emcc $CFLAGS $PDRN "$PD/pandas/_libs/src/datetime/date_conversions.c" -o "$OUT/c_date_conversions.o" 2>"$OUT/c_date_conversions_cc.txt" || FAILED="$FAILED c_date_conversions"

echo "=== done. FAILED:${FAILED:- none} ==="
ls $OUT/*.o 2>/dev/null | wc -l

# ---- link: numpy core + numpy.random objects (from nprnd.sh) + all pandas
# objects + wasthon.o, every PyInit exported, ONE module -> build/nppd.{mjs,wasm}.
if [ -n "$FAILED" ]; then echo "compile failures — not linking"; exit 1; fi
NR="$ROOT/build/nprnd-obj"
EXP='"_PyInit__multiarray_umath","_wasthon_init","_wasthon_module_create","_malloc","_free","_PyInit_pandas_datetime","_PyInit_pandas_parser","_PyInit__common","_PyInit_bit_generator","_PyInit__mt19937","_PyInit__philox","_PyInit__pcg64","_PyInit__sfc64","_PyInit__bounded_integers","_PyInit__generator","_PyInit_mtrand"'
for M in $TSLIBS $LIBS indexers aggregations testing parsers json; do EXP="$EXP,\"_PyInit_$M\""; done
CY="$NR/_common.o $NR/bit_generator.o $NR/_mt19937.o $NR/_philox.o $NR/_pcg64.o $NR/_sfc64.o $NR/_bounded_integers.o $NR/_generator.o $NR/mtrand.o"
ALGO="$NR/mt19937.o $NR/mt19937-jump.o $NR/philox.o $NR/pcg64.o $NR/sfc64.o $NR/legacy-distributions.o"
emcc -O1 "$ROOT"/numpy-probe/obj/*.o "$ROOT/build/wasthon.o" "$NR/tanh_stub.o" $CY $ALGO "$NR"/npyrandom/*.o "$OUT"/*.o \
  --js-library "$SRC/wasthon.js" --js-library "$CS/cython_support.js" \
  -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -sSTACK_SIZE=5242880 --profiling-funcs \
  -Wl,--allow-multiple-definition -s EXPORTED_FUNCTIONS="[$EXP]" \
  -s EXPORTED_RUNTIME_METHODS='["HEAPU8","HEAP32","UTF8ToString","stringToUTF8","lengthBytesUTF8","wasmTable"]' \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=nppd \
  -o "$ROOT/build/nppd.mjs" 2>"$OUT/link_err.txt"
echo "link exit=$? errors=$(grep -c 'error:' "$OUT/link_err.txt")"
grep "undefined symbol" "$OUT/link_err.txt" | sed 's/.*undefined symbol: //' | sort -u
ls -la "$ROOT/build/nppd.wasm" 2>/dev/null | awk '{print "wasm:", $5, "bytes"}'
