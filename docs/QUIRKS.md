# QUIRKS — build & runtime oddities

Things that surprised us and cost real debugging time. Documented so future-us
doesn't re-chase them. Newest first.

---

## RESOLVED — `scipy.special` `test_sf_error` errstate tests (was 6/4 local, 7/3 CI)

**History.** `test_sf_error` used to fail its four `errstate` tests
(`test_errstate_c_basic`, `test_errstate_all_but_one`,
`test_sf_error_special_refcount`, and — locally only — `test_errstate_cpp_scipy_special`),
with a puzzling local↔CI split (6/4 vs 7/3). An earlier version of this file
guessed the split was "C++ exception propagation sensitive to the toolchain."
That guess was wrong.

**Real root cause.** scipy 1.14's xsf `special/error.h` compiles
`special::set_error()` as an **inline no-op** unless `-DSP_SPECFUN_ERROR` is
defined; the real implementation (which looks up the errstate action and
raises) lives once in `sf_error.cc`. The recipe only passed the flag to three
TUs (`sf_error`, `_special_ufuncs`, `_gufuncs`), so a domain error inside a
kernel compiled **without** it — e.g. `cephes_spence` in
`special_wrappers.cpp` — was silently swallowed: `sc.spence(-1)` returned NaN
and `sc.errstate(domain='raise')` never raised.

**Fix.** `-DSP_SPECFUN_ERROR` in the base `CFLAGS`/`CXXFLAGS` (spbuild.sh), so
every TU gets it — matching meson, where `sf_error_state_dep` carries the flag
to all special targets. Now **10/0 deterministically**, local and CI. Safe:
under the default errstate (everything `ignore`) `set_error` returns at the
IGNORE check, so nothing changes except that errstate now works.

**Lesson.** A local↔CI split on a *numeric*/raise test can be a missing
compile-time `-D`, not inherent "toolchain sensitivity" — chase the flag
before theorising about the toolchain.
