#!/usr/bin/env bash
# Build numpy.linalg's C extension (_umath_linalg) for wasm into
# build/linalg-obj/*.o — the f2c'd LAPACK (lapack_lite, pure C, NO Fortran,
# NO external BLAS/LAPACK) plus umath_linalg.cpp. Link these into the numpy
# module (core dashboard wasm, nprnd, and npmpl) alongside numpy-probe/obj so
# they share PyArray_API and npymath, then wire the loader to run
# _PyInit__umath_linalg for `numpy.linalg._umath_linalg` INSTEAD of the
# _umath_linalg_stub.py — real inv/det/eig/svd/solve/lstsq/cholesky.
#
# Usage: ./numpy-probe/linalg.sh <numpy-2.5.1-source-tree>
#
# Prerequisite: numpy-probe/gen (generated headers) — produced by probe.sh.
set -u
NP="${1:?path to numpy 2.5.1 source tree}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
OUT="$ROOT/build/linalg-obj"; mkdir -p "$OUT"
cd "$ROOT" && source external/emsdk/emsdk_env.sh >/dev/null 2>&1

L="$NP/numpy/linalg"
NPINC="-I $HERE/gen -I $HERE -I $NP/numpy/_core/include -I $NP/numpy/_core/include/numpy -I $NP/numpy/_core/src/common"
CFLAGS="-O1 -c -I $ROOT/src -I $L/lapack_lite $NPINC"

FAIL=""
# the 8 f2c LAPACK/BLAS units (have_lapack=false path from linalg/meson.build)
for f in f2c f2c_config f2c_blas f2c_lapack f2c_s_lapack f2c_d_lapack f2c_c_lapack f2c_z_lapack; do
  emcc $CFLAGS "$L/lapack_lite/$f.c" -o "$OUT/$f.o" 2>"$OUT/$f.txt" || FAIL="$FAIL $f"
done
emcc $CFLAGS "$L/lapack_lite/python_xerbla.c" -o "$OUT/python_xerbla.o" 2>"$OUT/python_xerbla.txt" || FAIL="$FAIL python_xerbla"
# the gufunc wrapper (C++)
em++ -O1 -std=c++17 -c -DNPY_NO_DEPRECATED_API=0 -I "$ROOT/src" -I "$L/lapack_lite" $NPINC \
  "$L/umath_linalg.cpp" -o "$OUT/umath_linalg.o" 2>"$OUT/umath_linalg.txt" || FAIL="$FAIL umath_linalg"

echo "linalg objects: $(ls "$OUT"/*.o 2>/dev/null | wc -l); failed:${FAIL:- none}"
[ -n "$FAIL" ] && exit 1
echo "→ link build/linalg-obj/*.o into the numpy module and export _PyInit__umath_linalg"
