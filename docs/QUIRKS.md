# QUIRKS — build & runtime oddities

Things that surprised us and cost real debugging time. Documented so future-us
doesn't re-chase them. Newest first.

---

## `scipy.special` `test_errstate_cpp_scipy_special`: passes on CI, fails on a local build (7/3 vs 6/4)

**Symptom.** The **deployed** dashboard (GitHub Pages, built by CI) shows
`scipy.special.tests.test_sf_error` at **7/3** — `test_errstate_cpp_scipy_special`
*passes*. A **locally**-built `npsp.mjs` shows **6/4** — that one test fails with
`AssertionError: DID NOT RAISE (SpecialFunctionError)`. The other three errstate
tests (`test_errstate_all_but_one`, `test_errstate_c_basic`,
`test_sf_error_special_refcount`) fail in **both** builds.

**What it is.** `test_errstate_cpp_scipy_special` checks that a **C++** special
ufunc raises `SpecialFunctionError` when called under `sc.errstate(all='raise')`.
Whether the C++ exception → `PyErr` propagation actually fires is sensitive to the
exact toolchain build (emscripten's C++ exception handling / optimization). The
**clean, from-scratch CI build** (fresh emsdk 5.0.7, all objects compiled
together) makes it raise; some local build states do not.

**What it is NOT — a code regression.** Ruled out exhaustively: `npsp` relinked
against every recent bridge — `58de01b` (matplotlib base) → `2ee1f88` →
`7f58e4d` → `56fcfc9` (current `main`) — **all give 6/4 locally**, so no bridge
commit flipped it; the pre-`y*` bridge is 6/4 too; and an A/B with vs. without the
`scipy.sparse.issparse` stub is byte-identical on `sf_error`. The original
`scipy.special` port already measured **6/4 locally** while its CI deployed
**7/3** — the gap predates everything.

**Takeaway.** For this test the **CI / deployed dashboard is the source of
truth**. A local `npsp` that disagrees with the deployed by *exactly*
`test_errstate_cpp_scipy_special` is this quirk, not a regression — don't chase
it. The next CI rebuild deploys 7/3 unchanged.
