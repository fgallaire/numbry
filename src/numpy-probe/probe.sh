#!/usr/bin/env bash
# numpy 2.5.1 FULL-CORE compile + probe link — phase-2 state (2026-07-06).
# Usage: ./probe.sh <numpy-2.5.1-source-tree>
# State when written: every core file compiles (multiarray 56/56, umath +
# baseline dispatch, npymath C++, npysort over vendored highway, stringdtype,
# textreading) and the link leaves EXACTLY the 87 symbols of
# link_contract.txt (100% Py*) = the phase-3 implementation contract.
# emcc must be on PATH (external/emsdk/upstream/emscripten).
set -u
NP="${1:?path to numpy 2.5.1 source tree}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
SRC="$ROOT/src"; GEN="$HERE/gen"; OBJ="$HERE/obj"
mkdir -p "$GEN" "$OBJ"
cp "$HERE"/config.h "$HERE"/_numpyconfig.h "$HERE"/npy_cpu_dispatch_config.h "$GEN"/

# 0. numpy-side recipe patches (3 files / 5 direct ->ob_type sites)
( cd "$NP" && patch -p1 -N < "$HERE/recipe-patches.diff" ) || true

# 1. numpy's standalone generators (note the -o semantics: the api
#    generators take a DIRECTORY, the umath ones take a FILE path)
( cd "$NP/numpy/_core" &&
  python3 -m code_generators.generate_numpy_api -o "$GEN" &&
  python3 -m code_generators.generate_ufunc_api -o "$GEN" &&
  python3 -m code_generators.generate_umath -o "$GEN/__umath_generated.c" &&
  python3 -m code_generators.generate_umath_doc -o "$GEN/_umath_doc_generated.h" )

# 2. templates: all non-dispatch .src (funcs.inc.src included — funcs.inc is
#    #included by umathmodule.c) + the dispatch .c.src -> .c
( cd "$NP"
  for f in $(find numpy/_core/src -name "*.src" | grep -v dispatch); do
    python3 numpy/_build_utils/process_src_template.py "$f" -o "$GEN/$(basename "${f%.src}")"
  done
  for f in $(find numpy/_core/src -name "*.dispatch.c.src"); do
    python3 numpy/_build_utils/process_src_template.py "$f" -o "$GEN/$(basename "${f%.c.src}").c"
  done )

# 3. baseline-empty per-file dispatch headers (meson multi_targets() shape,
#    no SIMD targets) for EVERY *.dispatch.h name referenced anywhere
cat > "$GEN/_dispatch_stub.h" <<'EOH'
#undef NPY_MTARGETS_CONF_BASELINE
#undef NPY_MTARGETS_CONF_DISPATCH
#define NPY_MTARGETS_CONF_BASELINE(CB, ...) NPY__CPU_EXPAND(CB(__VA_ARGS__))
#define NPY_MTARGETS_CONF_DISPATCH(CHK_CB, CB, ...)
EOH
( cd "$NP" && grep -rh 'include "[a-z_0-9]*\.dispatch\.h"' numpy/_core/src \
  | grep -oE '[a-z_0-9]+\.dispatch\.h' | sort -u ) \
  | while read -r h; do cp "$GEN/_dispatch_stub.h" "$GEN/$h"; done

# np.dtype(str)/astype(str): `typ == &PyUnicode_Type` misses through the
# bridge (wrap(str) is never the extern struct) so both mapped to OBJECT —
# OR-in the live-class identity (descriptor.c _convert_from_type).
sed -i 's/else if (typ == &PyBytes_Type) {/else if (typ == \&PyBytes_Type || __wasthon_type_is_builtin((PyObject *)typ, 2)) {/; s/else if (typ == &PyUnicode_Type) {/else if (typ == \&PyUnicode_Type || __wasthon_type_is_builtin((PyObject *)typ, 1)) {/' "$NP/numpy/_core/src/multiarray/descriptor.c"

CFLAGS="-O1 -c -DNDEBUG -DNPY_INTERNAL_BUILD -DHAVE_NPY_CONFIG_H -D_FILE_OFFSET_BITS=64
  -Wno-error=incompatible-pointer-types -Wno-error=int-conversion
  -I $SRC -I $GEN
  -I $NP/numpy/_core/src/common -I $NP/numpy/_core/src/multiarray
  -I $NP/numpy/_core/src/umath -I $NP/numpy/_core/src/npymath
  -I $NP/numpy/_core/src/npysort -I $NP/numpy/_core/src/multiarray/stringdtype
  -I $NP/numpy/_core/src/highway
  -I $NP/numpy/_core/include -I $NP/numpy/_core/include/numpy"

# 4. compile everything. Exclusions: x86_simd_qsort* (AVX-only, generic sort
#    falls back), _simd.dispatch (the _simd test module), *_tests modules.
#    NEVER standalone-compile the #include-files: __multiarray_api.c,
#    __ufunc_api.c, __umath_generated.c, funcs.inc, and GEN/ieee754.c
#    (the tree's ieee754.cpp is the real one — same-name .o collision).
OK=0; FAIL=0; : > "$HERE/errors.txt"
for f in "$NP"/numpy/_core/src/multiarray/*.c \
         "$NP"/numpy/_core/src/multiarray/*.cpp \
         "$NP"/numpy/_core/src/multiarray/stringdtype/*.c \
         "$NP"/numpy/_core/src/multiarray/stringdtype/*.cpp \
         "$NP"/numpy/_core/src/multiarray/textreading/*.c \
         "$NP"/numpy/_core/src/multiarray/textreading/*.cpp \
         "$NP"/numpy/_core/src/umath/*.c "$NP"/numpy/_core/src/umath/*.cpp \
         "$NP"/numpy/_core/src/common/*.c "$NP"/numpy/_core/src/common/*.cpp \
         "$NP"/numpy/_core/src/npymath/npy_math.c \
         "$NP"/numpy/_core/src/npymath/halffloat.cpp \
         "$NP"/numpy/_core/src/npymath/ieee754.cpp \
         "$NP"/numpy/_core/src/npysort/*.cpp \
         "$GEN"/*.dispatch.c \
         "$GEN"/scalartypes.c "$GEN"/arraytypes.c "$GEN"/loops.c \
         "$GEN"/matmul.c "$GEN"/scalarmath.c "$GEN"/npy_math_complex.c \
         "$GEN"/einsum.c "$GEN"/einsum_sumprod.c \
         "$GEN"/lowlevel_strided_loops.c "$GEN"/nditer_templ.c; do
  [ -f "$f" ] || continue
  case "$f" in
    *x86_simd*|*_simd.dispatch*|*_rational_tests*|*_operand_flag*|*_struct_ufunc*|*_umath_tests*|*_multiarray_tests*) continue;;
  esac
  if emcc $CFLAGS "$f" -o "$OBJ/$(basename "$f" | sed 's/\.[a-z]*$//').o" 2>>"$HERE/errors.txt"
  then OK=$((OK+1)); else FAIL=$((FAIL+1)); echo "FAIL:$(basename "$f")" >>"$HERE/errors.txt"; fi
done
echo "compile: OK=$OK FAIL=$FAIL (expected when written: 90+/0)"

# 5. the probe link — undefined list = what wasthon.js must implement.
#    build/wasthon.o comes from any prior module build (./build.sh _pickle).
emcc -O1 "$OBJ"/*.o "$ROOT/build/wasthon.o" --js-library "$SRC/wasthon.js" \
  -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 \
  -s EXPORTED_FUNCTIONS='["_PyInit__multiarray_umath","_wasthon_init","_wasthon_module_create","_malloc","_free"]' \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=numpy_probe \
  -o "$HERE/npprobe.mjs" -Wl,--error-limit=0 2>&1 \
  | grep -oE "undefined symbol: [A-Za-z_0-9]+" | sed 's/undefined symbol: //' | sort -u \
  | tee "$HERE/link_undefined_now.txt"
echo "(diff against link_contract.txt to see progress)"
