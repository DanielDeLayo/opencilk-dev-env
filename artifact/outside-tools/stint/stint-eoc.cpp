// stint-eoc.cpp (stint.sh ours): STINT's END_OF_COMPUTATION hook for the ported programs, callable from C.
// Their benchmarks call global_trace.end_of_computation() at the end of main (prints "###stats:###"); ours call this.
#include "trace.h"
extern "C" void stint_end_of_computation(void) { global_trace.end_of_computation(); }
