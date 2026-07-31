/* wasthon_mallinfo.c -- allocator state for THIS wasm's heap.
 *
 * The dashboards report a heap's size AND how much of it the allocator is
 * actually holding: a size that only grows says nothing about what was
 * reclaimed. torch's npth gets this from brytorch's wasthon_census.cpp, which
 * pulls in torch and pybind11 and so cannot be reused here. mallinfo() needs
 * neither, so numpy's nprnd carries its own copy and the two heaps are read
 * the same way.
 *
 * Same contract as the torch side: what == 0 -> free bytes (fordblks),
 * anything else -> used bytes (uordblks).
 */
#include <malloc.h>

double wasthon_census_mallinfo(int what) {
  struct mallinfo mi = mallinfo();
  return what == 0 ? (double)mi.fordblks : (double)mi.uordblks;
}
