#!/usr/bin/env bash
# Build Pillow's C core to a STANDALONE wasm bundle build/nppil.{mjs,wasm}:
# _imaging (the ImagingCore engine) + _imagingmath + _imagingmorph. Pure C,
# hand-written CPython C-API — no Cython, no pybind11, no numpy, no Fortran: the
# sqlite3 template, our strong suit. PNG only: ZipDecode/ZipEncode drive zlib
# DIRECTLY (emscripten USE_ZLIB, no libpng); the heavy codecs (Jpeg/Jpeg2K/Tiff/
# imagequant) live under #ifdef HAVE_* and compile to nothing without the defines.
#
# Usage: ./pilbuild.sh <Pillow-11.0.0-source-tree>
#
# Prerequisite: build/wasthon.o (the bridge) already compiled.
#
# loader/test-pillow.html loads build/nppil.mjs + the PIL Python layer, generated
# by:  node cython-support/gen_pil_vfs.mjs <Pillow-src>  -> build/pil_vfs.js
set -u
PIL="${1:?path to Pillow 11.0.0 source tree}"
CS="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$CS/.." && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/build/pil-obj"; mkdir -p "$OUT"
cd "$ROOT" && source external/emsdk/emsdk_env.sh >/dev/null 2>&1

PSRC="$PIL/src"
CFLAGS=( -O2 -c -DNDEBUG -DPy_PYTHON_H -DHAVE_LIBZ '-DPILLOW_VERSION="11.0.0"'
         -DHAVE_PROTOTYPES -DSTDC_HEADERS -DHAVE_UNISTD_H
         -sUSE_ZLIB=1 -Wno-macro-redefined -Wno-incompatible-pointer-types
         -Wno-int-conversion -Wno-implicit-function-declaration
         -include "$SRC/patchlevel.h" -include "$CS/pil_compat.h"
         -I "$SRC" -I "$PSRC" -I "$PSRC/libImaging" )

# Pillow's static PyTypeObjects use positional (CPython-ordered) initializers;
# the wasthon bridge's reordered PyTypeObject needs designated ones. Rewrite the
# eight of them in place (idempotent) before compiling.
python3 "$CS/pil_designate.py" \
  "$PSRC/_imaging.c" "$PSRC/decode.c" "$PSRC/encode.c" "$PSRC/outline.c" "$PSRC/path.c"

FAILED=""
compile() {  # $1 = source path, $2 = obj basename
  emcc "${CFLAGS[@]}" "$1" -o "$OUT/$2.o" 2>"$OUT/$2_cc.txt"
  local NE; NE=$(grep -c "error:" "$OUT/$2_cc.txt" || true)
  if [ "$NE" != "0" ]; then echo "$2: errors=$NE"; grep -m3 "error:" "$OUT/$2_cc.txt"; FAILED="$FAILED $2"; fi
}

# _imaging module = _imaging.c + the six top-level helpers + all of libImaging.
# display.c is Win32/X11-only (compiles near-empty here); drop it if it fights.
for f in _imaging decode encode map outline path _imagingmath _imagingmorph; do
  compile "$PSRC/$f.c" "$f"
done
for f in "$PSRC"/libImaging/*.c; do
  compile "$f" "li_$(basename "${f%.c}")"
done

echo "=== compile done. FAILED:${FAILED:- none} ==="
ls "$OUT"/*.o 2>/dev/null | wc -l
[ -n "$FAILED" ] && { echo "compile failures — not linking"; exit 1; }

EXP='"_PyInit__imaging","_PyInit__imagingmath","_PyInit__imagingmorph","_wasthon_init","_wasthon_module_create","_malloc","_free"'
emcc -O2 "$ROOT/build/wasthon.o" "$OUT"/*.o \
  --js-library "$SRC/wasthon.js" -sUSE_ZLIB=1 \
  -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -sSTACK_SIZE=5242880 --profiling-funcs \
  -Wl,--allow-multiple-definition -s EXPORTED_FUNCTIONS="[$EXP]" \
  -s EXPORTED_RUNTIME_METHODS='["HEAPU8","HEAP32","UTF8ToString","stringToUTF8","lengthBytesUTF8","wasmTable"]' \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=nppil \
  -o "$ROOT/build/nppil.mjs" 2>"$OUT/link_err.txt"
echo "link exit=$? errors=$(grep -c 'error:' "$OUT/link_err.txt")"
grep "undefined symbol" "$OUT/link_err.txt" | sed 's/.*undefined symbol: //' | sort -u
ls -la "$ROOT/build/nppil.wasm" 2>/dev/null | awk '{print "wasm:", $5, "bytes"}'
