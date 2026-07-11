/* Baseline scalar tanh ufunc loops (loops_hyperbolic.dispatch is C++/SIMD and
 * not built for WASM baseline). numpy.random never calls np.tanh; this just
 * completes the umath link with a correct libm loop. */
#include <math.h>
#include "numpy/npy_common.h"
void DOUBLE_tanh(char **args, npy_intp *dimensions, npy_intp *steps, void *func){
  char *ip=args[0], *op=args[1]; npy_intp n=dimensions[0], is=steps[0], os=steps[1], i;
  for(i=0;i<n;i++,ip+=is,op+=os) *(double*)op = tanh(*(const double*)ip);
}
void FLOAT_tanh(char **args, npy_intp *dimensions, npy_intp *steps, void *func){
  char *ip=args[0], *op=args[1]; npy_intp n=dimensions[0], is=steps[0], os=steps[1], i;
  for(i=0;i<n;i++,ip+=is,op+=os) *(float*)op = tanhf(*(const float*)ip);
}
