# NumBry

**The scientific Python stack — real NumPy, pandas and SciPy — running in the
browser**, on top of [Brython](https://github.com/brython-dev/brython) through
the [Wasthon](https://github.com/fgallaire/wasthon) C-API bridge.

Not reimplementations: the upstream C/Cython extension modules themselves
(numpy's `_multiarray_umath`, the 9 `numpy.random` Cython modules, the 43
`pandas._libs` extensions, scipy.ndimage's `_nd_image`/`_ni_label`) compiled to
WebAssembly, with each package's own pure-Python layer served as a Brython VFS.

Validated against the upstream projects' **own test suites**, run in-browser:

- **numpy 2.5.1** — suite dashboard across `numpy/**/tests` (+ bit-exact
  MT19937 vs upstream)
- **pandas 2.2.3** — `pandas/tests/tslibs` + `libs` dashboards, 20/20 smoke
- **SciPy 1.14.1** — `scipy/ndimage/tests` dashboard (~98% passing), 19/19 smoke

## Layout

- `src/numpy-probe/` — the numpy C-core build recipe (codegen + compile), the
  f2c'd LAPACK-lite build, and the numpy VFS generator.
- `src/cython-support/` — the per-package recipes (`nprnd.sh`, `pdbuild.sh`,
  `ndbuild.sh`, `mplbuild.sh`), the pandas/scipy VFS generators and the browser
  stubs. At build time these overlay the **generic** `cython-support/` layer
  that ships with Wasthon (compat headers, `cybuild.sh`, the Cython js-library).
- `loader/` — the pages: suite dashboards (`test-*-all.html`), single-module
  runners and smoke tests, indexed by `index.html`.
- `build.sh` — clones wasthon@main (bridge + Brython + generic support layer),
  pins numpy/pandas/scipy/Cython to exact releases, builds everything from
  source. **No committed blobs**: artifacts land in `build/` (git-ignored).

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
