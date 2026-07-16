/* legacy-distributions.c is compiled with -DNP_RANDOM_LEGACY (RAND_INT_TYPE
 * = long, as numpy's meson does for the mtrand module) but must call
 * random_poisson / random_geometric_search from the SHARED distributions.c,
 * compiled without the define (RAND_INT_TYPE = int64_t, used by _generator).
 * These shims bridge the two ABIs; legacy-distributions.c is compiled with
 * -Drandom_poisson=random_poisson_long etc. so its calls land here. */
#include "numpy/random/distributions.h"
long random_poisson_long(bitgen_t *b, double lam) { return (long)random_poisson(b, lam); }
long random_geometric_search_long(bitgen_t *b, double p) { return (long)random_geometric_search(b, p); }
