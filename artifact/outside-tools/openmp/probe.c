// omp.sh's gate probe: two threads of one parallel region write the same int (-DRACY) or each its own cache line.
#include <omp.h>
#include <stdio.h>

int x;
long y[2][8];

int main(void) {
#pragma omp parallel num_threads(2)
  {
    int t = omp_get_thread_num();
#ifdef RACY
    x = t + 1;
#else
    y[t][0] = t + 1;
#endif
  }
  printf("%d %ld\n", x, y[0][0] + y[1][0]);
  return 0;
}
