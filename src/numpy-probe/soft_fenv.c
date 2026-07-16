/* wasm has no floating-point environment: musl's fenv.c is a no-op
 * (fetestexcept() is always 0), so numpy's npy_set_floatstatus_* /
 * npy_get_floatstatus pair was blind — _umath_linalg reports a failed
 * dpotrf (non-PSD cholesky) by raising FE_INVALID, np.errstate('raise'/
 * 'call'/'warn') reads it back; none of that worked. Keep a process-wide
 * software flag word instead. These definitions live in an object file,
 * so they win over libc.a's no-ops at link time (objects resolve first).
 * Note: wasm instructions still do not set flags — only numpy's explicit
 * npy_set_floatstatus_*() calls land here, which is exactly the intent. */
static int __soft_fexcepts = 0;
int feclearexcept(int mask) { __soft_fexcepts &= ~mask; return 0; }
int feraiseexcept(int mask) { __soft_fexcepts |= mask; return 0; }
int fetestexcept(int mask) { return __soft_fexcepts & mask; }
