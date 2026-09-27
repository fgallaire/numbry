# Third-party components

NumBry redistributes, links, or otherwise depends on the following
third-party components, each governed by its own license. Their copyright
notices and licenses are preserved. `build.sh` pins every one of them to the
exact release it builds.

## Compiled into the `.wasm` modules

- **NumPy 2.5.1** — BSD 3-Clause License, (C) 2005-2025 NumPy Developers.
  With the components it bundles, among them LAPACK-lite (f2c-translated
  LAPACK, BSD 3-Clause), pocketfft (BSD 3-Clause) and Google Highway
  (Apache-2.0 or BSD 3-Clause). <https://numpy.org/>
- **SciPy 1.14.1** (`ndimage`, `special`, `fft`, `cluster`) — BSD 3-Clause
  License, (C) 2001-2002 Enthought, Inc., 2003-2024 SciPy Developers. With the
  components listed in its `LICENSES_bundled.txt`, among them Boost.Math
  (Boost Software License 1.0), Cephes (BSD 3-Clause), Faddeeva (MIT) and
  pypocketfft (BSD 3-Clause). <https://scipy.org/>
- **pandas 2.2.3** — BSD 3-Clause License, (C) 2008-2011 AQR Capital
  Management, LLC, Lambda Foundry, Inc. and PyData Development Team,
  2011-2023 open source contributors. With the components listed in its
  `LICENSES/` directory. <https://pandas.pydata.org/>
- **CPython 3.14.6's `_datetime`** (`Modules/_datetimemodule.c` and
  `Include/datetime.h`, compiled into `nppd.wasm`) — Python Software
  Foundation License v2, (C) 2001-present Python Software Foundation.
  <https://docs.python.org/3/license.html>
- **matplotlib 3.9.2** — Matplotlib License (PSF-based), (C) 2012-
  Matplotlib Development Team, (C) 2002-2011 John D. Hunter.
  <https://matplotlib.org/>
  - **Anti-Grain Geometry 2.4**, vendored in matplotlib — (C) 2002-2005
    Maxim Shemanarev; permission to copy, use, modify, sell and distribute
    is granted provided this copyright notice appears in all copies.
  - **FreeType** — FreeType License (FTL). Portions of this software are
    copyright © The FreeType Project (www.freetype.org). All rights reserved.
- **Pillow 11.0.0** — MIT-CMU (HPND) License, (C) 1997-2011 Secret Labs AB,
  (C) 1995-2011 Fredrik Lundh and contributors, (C) 2010-2024 Jeffrey A.
  Clark and contributors. <https://python-pillow.org/>
- **zlib** — zlib License, (C) Jean-loup Gailly and Mark Adler (Pillow,
  FreeType). <https://zlib.net/>
- **kiwisolver 1.4.7** and **cppy** — BSD 3-Clause License, (C) 2013-2024
  Nucleic Development Team. <https://github.com/nucleic/kiwi>
- **pybind11 2.13.6** — BSD 3-Clause License, (C) Wenzel Jakob.
  <https://github.com/pybind/pybind11>
- **Cython** — Apache License 2.0; the C it generates, utility code
  included, is compiled into the Cython extension modules.
  <https://cython.org/>

## Served in the VFS blobs (Python source and data)

- The Python layers of the packages above.
- **seaborn 0.13.2** — BSD 3-Clause License, (C) 2012-2023 Michael L. Waskom.
- **SymPy 1.14** — BSD 3-Clause License, (C) SymPy Development Team.
- **mpmath 1.4.1** — BSD 3-Clause License, (C) Fredrik Johansson and mpmath
  contributors.
- **python-dateutil** — Apache License 2.0 or BSD 3-Clause License,
  (C) the dateutil contributors; with the IANA time zone database (public
  domain).
- **pytz** — MIT License, (C) Stuart Bishop.
- **six** — MIT License, (C) Benjamin Peterson.
- **cycler** — BSD 3-Clause License, (C) the Matplotlib Development Team.
- **pyparsing** — MIT License, (C) Paul McGuire.
- **packaging** — Apache License 2.0 or BSD 2-Clause License, (C) Donald
  Stufft and individual contributors.
- **DejaVu Sans fonts** (matplotlib's `mpl-data`) — Bitstream Vera Fonts
  License, (C) 2003 Bitstream, Inc.; DejaVu changes in the public domain.
- `loader/data/` — test vectors from the NumPy and SciPy source trees, under
  their licenses above.

## Brython — BSD 3-Clause License

- `loader/brython/` — the Brython build the pages run on, copied at build
  time from the [wasthon](https://github.com/fgallaire/wasthon) repository.
  (C) Pierre Quentel and contributors. <https://brython.info/>

## Build-time tooling

- **Emscripten / emsdk** — MIT and University of Illinois/NCSA Open Source
  License. Compiles C to WebAssembly; its runtime (JS glue, musl libc,
  libc++) is linked into the outputs. <https://emscripten.org/>
