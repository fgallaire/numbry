# NumBry

**The scientific Python stack — real NumPy, pandas, SciPy, matplotlib,
seaborn, Pillow and SymPy — running in the browser**, on top of
[Brython](https://github.com/brython-dev/brython) through the
[Wasthon](https://github.com/fgallaire/wasthon) C-API bridge.

Not reimplementations: the upstream C/Cython/C++ extension modules themselves
(numpy's `_multiarray_umath` + f2c'd LAPACK-lite, the 9 `numpy.random` Cython
modules, the 43 `pandas._libs` extensions, scipy.ndimage's
`_nd_image`/`_ni_label`, matplotlib's Agg renderer + FreeType + kiwisolver,
Pillow's `_imaging` core + 68 `libImaging` codecs) compiled to WebAssembly,
with each package's own pure-Python layer served as a Brython VFS.

Validated against the upstream projects' **own test suites**, run in-browser:

- **numpy 2.5.1** — suite dashboard across `numpy/**/tests` (+ bit-exact
  MT19937 vs upstream)
- **pandas 2.2.3** — `pandas/tests/tslibs` + `libs` dashboards, 20/20 smoke
- **SciPy 1.14.1** — `scipy/ndimage/tests` dashboard (~98% passing), 19/19 smoke
- **matplotlib 3.9.2** — draws a real figure (Agg + FreeType text) and blits
  `buffer_rgba()` onto a canvas
- **seaborn 0.13.2** — lineplot/histplot/kdeplot/regplot on the full stack in
  ONE wasm module, with live `np.linalg` (cholesky/inv/det, pinv)
- **Pillow 11.0.0** — the `_imaging` C core in wasm, PNG read/write via zlib:
  new/convert/resize/rotate/ImageDraw + pixel-exact PNG round-trip (19/19 smoke)
- **SymPy 1.14.0** — pure Python (with mpmath), served as a Brython VFS loaded
  on demand: `symbols`/`expand`/`diff` and the symbolic algebra core. Doubles
  as torch's `symbolic_shapes` dependency for BryTorch's `torch._refs.*`

## Layout

- `src/numpy-probe/` — the numpy C-core build recipe (codegen + compile), the
  f2c'd LAPACK-lite build, and the numpy VFS generator.
- `src/cython-support/` — the per-package recipes (`nprnd.sh`, `pdbuild.sh`,
  `ndbuild.sh`, `mplbuild.sh`, `sblink.sh`, `pilbuild.sh`), the pandas/scipy/
  matplotlib/seaborn/pillow VFS generators and the browser stubs. At build time these overlay the
  **generic** `cython-support/` layer that ships with Wasthon (compat headers,
  `cybuild.sh`, the Cython js-library).
- `src/gen_sympy_vfs.mjs` — the SymPy VFS generator (pure Python, no compile
  step, so it lives outside `cython-support/`).
- `loader/` — the pages: suite dashboards (`test-*-all.html`), single-module
  runners and smoke tests, indexed by `index.html`.
- `build.sh` — clones wasthon@main (bridge + Brython + generic support layer),
  pins numpy/pandas/scipy/matplotlib/seaborn/Pillow/SymPy/Cython to exact
  releases, builds everything from source. **No committed blobs**: artifacts
  land in `build/` (git-ignored).

## Build

```sh
./build.sh          # ~30-45 min cold: emsdk + numpy codegen + 50+ Cython modules
python3 -m http.server
# open http://localhost:8000/loader/
```

CI (`.github/workflows/deploy.yml`) runs the same script and publishes to
GitHub Pages.

## License

Copyright (C) 2026 Florent Gallaire <fgallaire@gmail.com>

BSD 3-Clause License — same as Brython. See `LICENSE` for the full text.
