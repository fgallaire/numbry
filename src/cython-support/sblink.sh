#!/usr/bin/env bash
# sblink.sh — link the seaborn page's combined module: numpy C core +
# lapack_lite/umath_linalg + numpy.random + pandas._libs (43 ext) +
# matplotlib Agg/FreeType + kiwisolver, ONE wasm -> build/npsb.{mjs,wasm}.
# seaborn itself is pure Python (sb_vfs.js); this is link-only and reuses
# every object the earlier phases produced (probe.sh, linalg.sh, nprnd.sh,
# pdbuild.sh, mplbuild.sh must all have run).
set -euo pipefail
CS="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$CS/.." && pwd)"
SRC="$ROOT/src"
W="$ROOT"
source "$W/external/emsdk/emsdk_env.sh" >/dev/null 2>&1
cd "$W"

FT='-sUSE_FREETYPE=1 -DFREETYPE_BUILD_TYPE="system"'
NR="$W/build/nprnd-obj"; PDOBJ="$W/build/pd-obj"; MPLOBJ="$W/build/mpl-obj"

TSLIBS="base ccalendar np_datetime dtypes timezones nattype conversion timedeltas tzconversion timestamps fields offsets parsing period strptime vectorized"
LIBS="interval hashtable missing lib tslib algos arrays groupby hashing index indexing internals join ops ops_dispatch properties reshape sparse writers"
EXP='"_PyInit__multiarray_umath","_PyInit__umath_linalg","_PyInit_ft2font","_PyInit__backend_agg","_PyInit__image","_PyInit__path","_PyInit__c_internal_utils","_PyInit__cext","_wasthon_init","_wasthon_module_create","_malloc","_free","_PyInit_pandas_datetime","_PyInit_pandas_parser","_PyInit__common","_PyInit_bit_generator","_PyInit__mt19937","_PyInit__philox","_PyInit__pcg64","_PyInit__sfc64","_PyInit__bounded_integers","_PyInit__generator","_PyInit_mtrand"'
for M in $TSLIBS $LIBS indexers aggregations testing parsers json; do EXP="$EXP,\"_PyInit_$M\""; done
CY="$NR/_common.o $NR/bit_generator.o $NR/_mt19937.o $NR/_philox.o $NR/_pcg64.o $NR/_sfc64.o $NR/_bounded_integers.o $NR/_generator.o $NR/mtrand.o"
ALGO="$NR/mt19937.o $NR/mt19937-jump.o $NR/philox.o $NR/pcg64.o $NR/sfc64.o $NR/legacy-distributions.o $NR/legacy_rand_shims.o"

# shellcheck disable=SC2086
emcc -O1 $FT "$W"/numpy-probe/obj/*.o "$W"/build/linalg-obj/*.o "$NR/tanh_stub.o" \
  $CY $ALGO "$NR"/npyrandom/*.o "$PDOBJ"/*.o "$MPLOBJ"/*.o "$W/build/wasthon.o" \
  --js-library "$SRC/wasthon.js" --js-library "$CS/cython_support.js" \
  -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -sSTACK_SIZE=5242880 --profiling-funcs \
  -Wl,--allow-multiple-definition -s ERROR_ON_UNDEFINED_SYMBOLS=1 \
  -s EXPORTED_FUNCTIONS="[$EXP]" \
  -s EXPORTED_RUNTIME_METHODS='["HEAPU8","HEAP32","UTF8ToString","stringToUTF8","lengthBytesUTF8","wasmTable","FS"]' \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=npsb \
  -o "$W/build/npsb.mjs" || { echo "LINK FAILED"; exit 1; }
echo "built build/npsb.{mjs,wasm}  ($(du -h "$W/build/npsb.wasm" | cut -f1))"
