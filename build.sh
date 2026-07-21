#!/usr/bin/env bash
# NumBry — build the numpy/pandas/scipy WASM artifacts. These are NEVER
# committed: they are produced here (locally or in CI) from source.
#
# The generic C-API bridge (src/wasthon.*), Brython and the generic Cython/
# pybind11 support layer (cython-support/) come from the wasthon repo (@main);
# the package build recipes, the VFS generators and the loader pages live HERE.
# The scientific source trees are pinned to the exact releases the recipes were
# validated against. Outputs land in build/ + loader/, ready for GitHub Pages.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

WASTHON_REPO="${WASTHON_REPO:-https://github.com/fgallaire/wasthon.git}"
WASTHON_REF="${WASTHON_REF:-main}"
EMSCRIPTEN_VERSION="${EMSCRIPTEN_VERSION:-5.0.7}"
NUMPY_TAG="v2.5.1"
PANDAS_TAG="v2.2.3"
SCIPY_TAG="v1.14.1"
MPL_TAG="v3.9.2"
SEABORN_TAG="v0.13.2"
PILLOW_TAG="11.0.0"     # python-pillow/Pillow (PNG-only C core, no libjpeg/etc.)
KIWI_TAG="1.4.7"        # nucleic/kiwi (kiwisolver's home repo)
SYMPY_PIN="1.14.0"      # torch requires sympy>=1.13.3; pulls mpmath (both pure Python)
MPMATH_PIN="1.4.1"      # OVERRIDES sympy's mpmath<1.4 pin: 1.3.0's py2-era exec-templated
                        # operators lose int_types under Brython (runtime NameError in the
                        # torch opinfo/gradcheck paths); 1.4.1 is the py3 rewrite the local
                        # dashboards were validated on
PYBIND11_PIN="2.13.6"   # EXACTLY: mplbuild.sh's header seds are calibrated on it
CYTHON_COMMIT="1fcb9f4c0cb0a67148f5bb4551cf10571cb7b569"   # fgallaire/cython fix-argsslice-fastcall (3.3 master + ArgsSlice fix) — scipy
CYTHON30_TAG="3.0.11"   # upstream — numpy.random + pandas were validated against 3.0.11 output (3.3 crashes on pandas' fused types)

W="$HERE/.wasthon"

echo "=== clone wasthon @ ${WASTHON_REF} (bridge + Brython + generic cython-support) ==="
rm -rf "$W"
git clone --depth 1 -b "$WASTHON_REF" "$WASTHON_REPO" "$W"

echo "=== install emsdk ${EMSCRIPTEN_VERSION} (the recipes source external/emsdk) ==="
git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$W/external/emsdk"
( cd "$W/external/emsdk" && ./emsdk install "$EMSCRIPTEN_VERSION" && ./emsdk activate "$EMSCRIPTEN_VERSION" )
# put emcc on PATH for every recipe below (emsdk_env may chdir: restore it)
source "$W/external/emsdk/emsdk_env.sh" >/dev/null 2>&1
cd "$HERE"

# Pin an external source tree to an exact commit/tag (fetch-by-ref).
pin() {  # url dir ref
    local url="$1" dir="$2" ref="$3"
    echo "=== pin $(basename "$dir") @ ${ref} ==="
    rm -rf "$dir"; mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    git -C "$dir" fetch -q --depth 1 origin "$ref"
    git -C "$dir" checkout -q FETCH_HEAD
}
NP="$W/numpy-src";  pin https://github.com/numpy/numpy.git   "$NP" "$NUMPY_TAG"
# numpy vendors build-time submodules the sdist embeds but a tag clone does
# not: the pythoncapi-compat header, the highway SIMD tree, and pocketfft
# (numpy.fft's header-only C++ backend, compiled by ndbuild.sh).
git -C "$NP" submodule update --init --depth 1 \
    numpy/_core/src/common/pythoncapi-compat numpy/_core/src/highway \
    numpy/fft/pocketfft
PD="$W/pandas-src"; pin https://github.com/pandas-dev/pandas "$PD" "$PANDAS_TAG"
SC="$W/scipy-src";  pin https://github.com/scipy/scipy.git   "$SC" "$SCIPY_TAG"
MPL="$W/matplotlib-src"; pin https://github.com/matplotlib/matplotlib.git "$MPL" "$MPL_TAG"
SB="$W/seaborn-src"; pin https://github.com/mwaskom/seaborn.git "$SB" "$SEABORN_TAG"
PIL="$W/pillow-src"; pin https://github.com/python-pillow/Pillow.git "$PIL" "$PILLOW_TAG"
KIWI="$W/kiwisolver-src"; pin https://github.com/nucleic/kiwi.git "$KIWI" "$KIWI_TAG"
CY="$W/cython-src";   pin https://github.com/fgallaire/cython.git "$CY" "$CYTHON_COMMIT"
CY30="$W/cython30-src"; pin https://github.com/cython/cython.git "$CY30" "$CYTHON30_TAG"

echo "=== pure-python runtime deps for the pandas VFS (dateutil/pytz/six) ==="
DEPS="$W/pdeps"
python3 -m pip install -q --target "$DEPS" python-dateutil pytz six

echo "=== sympy + mpmath (pure Python, torch's symbolic-shapes dep + Jubryter) ==="
SYMPYDEPS="$W/sympydeps"
python3 -m pip install -q --target "$SYMPYDEPS" "sympy==$SYMPY_PIN"
python3 -m pip install -q --target "$SYMPYDEPS" --upgrade "mpmath==$MPMATH_PIN"

echo "=== matplotlib deps: VFS packages + pybind11/cppy headers ==="
MPLDEPS="$W/mpldeps"
python3 -m pip install -q --target "$MPLDEPS" cycler==0.12.1 pyparsing==3.3.2 packaging==26.2
PYTOOLS="$W/pytools"
python3 -m pip install -q --target "$PYTOOLS" "pybind11==$PYBIND11_PIN" cppy

# The package recipes live in THIS repo; overlay them onto the clone so they
# run with the exact historical layout (CS/ROOT resolve inside the clone,
# where the generic cython-support headers from wasthon@main already sit).
cp -r "$HERE/src/cython-support/." "$W/cython-support/"
mkdir -p "$W/numpy-probe"
cp -r "$HERE/src/numpy-probe/."    "$W/numpy-probe/"

echo "=== compile the bridge (build/wasthon.o) ==="
( cd "$W" && source external/emsdk/emsdk_env.sh >/dev/null 2>&1 && mkdir -p build \
  && cp src/wasthon.c . && emcc -O3 -c -I . -I src wasthon.c -o build/wasthon.o && rm -f wasthon.c )

echo "=== numpy C core (codegen + ~90 objects) ==="
bash "$W/numpy-probe/probe.sh" "$NP"
echo "=== numpy.linalg (f2c'd lapack_lite, pure C) ==="
bash "$W/numpy-probe/linalg.sh" "$NP"
echo "=== numpy.random (9 Cython modules) -> build/nprnd.mjs ==="
CYTHON_PYTHONPATH="$CY30" bash "$W/cython-support/nprnd.sh" "$NP"

echo "=== relink the two dashboard modules WITH linalg ==="
( cd "$W" && source external/emsdk/emsdk_env.sh >/dev/null 2>&1
  OBJ="$W/numpy-probe/obj"; NR="$W/build/nprnd-obj"; LA="$W/build/linalg-obj"; SRC="$W/src"; CS="$W/cython-support"
  emcc -O1 "$OBJ"/*.o "$LA"/*.o "$NR/tanh_stub.o" "$W/build/wasthon.o" \
    --js-library "$SRC/wasthon.js" -Wl,--allow-multiple-definition \
    -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 \
    -s EXPORTED_FUNCTIONS='["_PyInit__multiarray_umath","_PyInit__umath_linalg","_wasthon_init","_wasthon_module_create","_malloc","_free","___errno_location","_fetestexcept","_feclearexcept","_feraiseexcept","_wasthon_set_errno_erange"]' \
    -sFORCE_FILESYSTEM=1 -s EXPORTED_RUNTIME_METHODS='["HEAP32","FS"]' \
    -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=numpy_multiarray_umath \
    -o "$W/build/numpy_multiarray_umath.mjs"
  MODS="_common bit_generator _mt19937 _philox _pcg64 _sfc64 _bounded_integers _generator mtrand"
  CYO=""; for M in $MODS; do CYO="$CYO $NR/$M.o"; done
  ALGO="$NR/mt19937.o $NR/mt19937-jump.o $NR/philox.o $NR/pcg64.o $NR/sfc64.o $NR/legacy-distributions.o $NR/legacy_rand_shims.o"
  EXP='["_PyInit__multiarray_umath","_PyInit__umath_linalg","_PyInit__common","_PyInit_bit_generator","_PyInit__mt19937","_PyInit__philox","_PyInit__pcg64","_PyInit__sfc64","_PyInit__bounded_integers","_PyInit__generator","_PyInit_mtrand","_wasthon_init","_wasthon_module_create","_malloc","_free","___errno_location","_fetestexcept","_feclearexcept","_feraiseexcept","_wasthon_set_errno_erange"]'
  emcc -O1 "$OBJ"/*.o "$LA"/*.o "$NR/tanh_stub.o" $CYO $ALGO "$NR"/npyrandom/*.o "$W/build/wasthon.o" \
    --js-library "$SRC/wasthon.js" --js-library "$CS/cython_support.js" -Wl,--allow-multiple-definition \
    -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 \
    -sFORCE_FILESYSTEM=1 -s EXPORTED_RUNTIME_METHODS='["HEAP32","FS"]' \
    -s EXPORTED_FUNCTIONS="$EXP" -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=nprnd \
    -o "$W/build/nprnd.mjs" )

echo "=== pandas._libs (43 extensions) -> build/nppd.mjs ==="
CYTHON_PYTHONPATH="$CY30" bash "$W/cython-support/pdbuild.sh" "$PD" "$NP"
echo "=== scipy.ndimage -> build/npnd.mjs ==="
CYTHON_PYTHONPATH="$CY" bash "$W/cython-support/ndbuild.sh" "$SC" "$NP"
echo "=== scipy.special (9 Fortran-free extensions) -> build/npsp.mjs ==="
# special needs the Boost.Math headers (Faddeeva/wright) — vendored submodule
git -C "$SC" submodule update --init --depth 1 scipy/_lib/boost_math
CYTHON_PYTHONPATH="$CY" bash "$W/cython-support/spbuild.sh" "$SC" "$NP"
echo "=== scipy.fft (pypocketfft pybind11) -> build/npfft.mjs ==="
# fft's pocketfft backend header is a vendored submodule; the pybind11 headers
# were installed above ($PYTOOLS). Reuses _ccallback_c/_pocketfft_umath objects
# the ndimage phase already built, so it must run after ndbuild.
git -C "$SC" submodule update --init --depth 1 scipy/_lib/pocketfft
PYBIND11_INC="$PYTOOLS/pybind11/include" bash "$W/cython-support/fftbuild.sh" "$SC" "$NP"
echo "=== scipy.cluster (3 Cython extensions, Fortran-free) -> build/npcl.mjs ==="
CYTHON_PYTHONPATH="$CY" bash "$W/cython-support/clbuild.sh" "$SC" "$NP"

echo "=== Pillow C core (PNG via zlib) -> build/nppil.mjs ==="
# Pure C, hand-written C-API (no Cython/pybind11/Fortran). Standalone bundle:
# needs only build/wasthon.o + the emscripten zlib port. pil_designate.py
# rewrites Pillow's positional static PyTypeObjects to designated initializers
# (the reordered bridge PyTypeObject needs them); the s*/y* PyArg buffer format
# lands in the bridge (wasthon@main).
bash "$W/cython-support/pilbuild.sh" "$PIL"
node "$W/cython-support/gen_pil_vfs.mjs" "$PIL/src/PIL"

echo "=== matplotlib Agg + kiwisolver -> build/npmpl.mjs ==="
# browser/Brython fixes for the Python layer (\N{...} escapes resolved,
# pickle_super-safe deepcopy, MPLCONFIGDIR trusted, pyparsing PEP-649…)
patch -p1 -s -d "$MPL/lib/matplotlib" < "$W/cython-support/mpl-vfs.patch"
patch -p1 -s -d "$MPLDEPS/pyparsing"  < "$W/cython-support/pyparsing-vfs.patch"
PYBIND11_INC="$PYTOOLS/pybind11/include" CPPY_INC="$PYTOOLS/cppy/include" \
  bash "$W/cython-support/mplbuild.sh" "$MPL" "$NP" "$KIWI"
node "$W/cython-support/gen_mpl_vfs.mjs" "$MPL/lib" "$KIWI/py" "$MPLDEPS" "$DEPS"

echo "=== seaborn (pure Python): combined numpy+pandas+mpl link -> build/npsb.mjs ==="
bash "$W/cython-support/sblink.sh"
node "$W/cython-support/gen_sb_vfs.mjs" "$SB/seaborn"

echo "=== CPython suite dashboard: wasthon-full bundle (25 stdlib C modules) ==="
# wasthon's own build.sh bootstraps its sources (CPython 3.14.6, expat, xz,
# zstd…) and reuses the emsdk already installed in $W/external/emsdk.
( cd "$W" && bash build.sh wasthon-full )

echo "=== VFS blobs (numpy / pandas+tests / scipy+tests) ==="
# a git-tag tree lacks the two meson-generated modules the numpy boot imports
( cd "$NP" && python3 numpy/_build_utils/gitversion.py --write numpy/version.py )
cp "$W/numpy-probe/numpy__config__stub.py" "$NP/numpy/__config__.py"
node "$W/numpy-probe/gen_numpy_vfs.mjs" "$NP/numpy" "$W/build/numpy_vfs.js"
node "$W/cython-support/gen_pandas_vfs.mjs" "$PD" "$DEPS" --tests
node "$W/cython-support/gen_scipy_vfs.mjs" "$SC"
node "$HERE/src/gen_sympy_vfs.mjs" "$SYMPYDEPS" "$W/build/sympy_vfs.js"

echo "=== collect artifacts ==="
mkdir -p "$HERE/build"
for f in numpy_multiarray_umath nprnd npnd npsp npfft npcl nppd npmpl npsb nppil; do
  cp "$W/build/$f.mjs" "$W/build/$f.wasm" "$HERE/build/"
done
cp "$W"/build/numpy_vfs.js "$W"/build/pandas_vfs.js "$W"/build/scipy_ndimage_vfs.js \
   "$W"/build/scipy_special_vfs.js "$W"/build/scipy_fft_vfs.js "$W"/build/scipy_cluster_vfs.js \
   "$W"/build/pil_vfs.js "$W"/build/sympy_vfs.js \
   "$W"/build/dateutil_zoneinfo_data.js "$W"/build/mpl_vfs.js "$W"/build/sb_vfs.js "$HERE/build/"
rm -rf "$HERE/loader/brython"
cp -r "$W/loader/brython" "$HERE/loader/brython"
# numpy.random's data-driven tests (test_direct) XHR ./data/*.csv relative to
# the page: serve the pinned tree's test vectors as loader/data/
mkdir -p "$HERE/loader/data"
cp "$NP"/numpy/random/tests/data/*.csv "$NP"/numpy/random/tests/data/*.pkl.gz "$HERE/loader/data/"
# scipy.ndimage test_measurements loadtxt's its label vectors the same way
# (test-scipy.html's os.path.exists probe resolves them through Brython's open)
cp "$SC"/scipy/ndimage/tests/data/label_*.txt "$HERE/loader/data/"
# CPython suite dashboard: bundle + runner pages + helper scripts + the
# Lib/test files, all straight from the wasthon clone (single source of truth)
cp "$W/build/wasthon-full.mjs" "$W/build/wasthon-full.wasm" "$HERE/build/"
cp "$W"/loader/test-cpython-all.html "$W"/loader/test-cpython.html \
   "$W"/loader/brython-src.js "$W"/loader/wasthon-loader.js \
   "$W"/loader/wasthon-io-write.js "$W"/loader/wasthon-fs.js \
   "$W"/loader/wasthon-dealloc.js "$W"/loader/wasthon-dbm.js "$HERE/loader/"
rm -rf "$HERE/loader/cpython-tests"
cp -r "$W/loader/cpython-tests" "$HERE/loader/"

echo "=== done: build/{numpy_multiarray_umath,nprnd,npnd,nppd}.{mjs,wasm} + 4 VFS blobs + loader/brython ==="
