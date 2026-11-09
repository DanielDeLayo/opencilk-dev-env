# Recipes for the outside tools in Table 1

How each outside tool is obtained, changed, built and run. No third-party code is included: each tool is fetched
from the source given below into `third_party/`, which .gitignore drops.

**Rules we applied:**
- Each tool is run as shipped, at -O2 or higher.
- A change to their code is allowed only if it is at most 5 lines and fixes a build or run that is far from the
  authors' intent. Exceptions are noted.
- Build-environment fixes (compiler flags on the make command line, missing tools in the image, how an archive is
  indexed) leave their sources unchanged. They are listed separately.

**Machine:** the paper's numbers come from a 24-core x86-64 Linux machine: builds on 24 cores, timing on the whole
machine with nothing else running.

## Build treatment against our rows

Every comparison gives each tool the same build treatment as ours, or says how it differs.

**Our rows** (This paper and Cilksan):
- `-O3 -g -D_GNU_SOURCE -fopencilk`, `-no-pie` at link, for the tool builds and the notool baseline alike.
- The tool's hooks are linked as bitcode (`-mllvm -cilksan-bc-path=…/libcilkprace.bc`, or `libcilksan.bc` for
  Cilksan) and inlined into the program at compile time: LTO of the hooks without `-flto`.
- The rest of the tool runtime is a static archive. The allocator is glibc malloc.

**Per row.** "Within the row" means the tool and its own baseline get the same treatment, so the row's ratio is like
for like, even where both differ from ours.

| Row | Tool build | Baseline build | Hooks reach the tool by | Differs from ours | Within the row |
|---|---|---|---|---|---|
| STINT | `-O3 -g -flto -fno-omit-frame-pointer -fcilkplus`; tcmalloc; static libcilkrts.a | same flags, without `-fsanitize=cilk -DEND_OF_COMPUTATION` and the tool objects | LTO: the tool objects are compiled with the same `-flto` flags (their `benchmarks/sync/Makefile`, TOOL_FLAGS) | tcmalloc, frame pointer, Cilk Plus runtime | same |
| C-RACER | `-O3 -g -flto -fno-omit-frame-pointer -fcilkplus -fcilk-no-inline`; tcmalloc; rdtool and the Cilk Plus runtime built `-flto`, archive indexed with the gold plugin | `base`: the same flags, runtime and malloc, without `-DRACEDETECT -fcilktool -fsanitize=thread` and librd.a (`rdtool/common.mk`, `rdtool/test/bench/Makefile` at 033f0bc0) | LTO | tcmalloc, frame pointer, `-fcilk-no-inline` | same |
| PINT | `-O3 -g -flto -fno-omit-frame-pointer -fcilkplus`; tcmalloc; static libcilkrts.a | the same, without `-fsanitize=cilk -DRD_TOOL` and the tool objects | LTO: the tool objects are LLVM IR bitcode | tcmalloc, frame pointer | same |
| SPD3 port, PTRacer, FastRacer (2 programs) | our clang 21.1.3, `-O3 -std=c++11 -fgnuc-version=5.4.0`, TBB 4.3 include copy with the one-line enum fix; hand-placed RecordMem calls, no `-ftaskdebug`; linked with g++ 5.4 against dynamic libftdebug.so (built with g++ 5.4 at -O3, their library Makefiles) and libtbb.so.2 | the same compiler and flags, no RecordMem (`d9notool.h`), `d9stub.o`, the notool libftdebug.so and libtbb.so.2 | out-of-line calls through the PLT into a shared library | no LTO of the hooks; dynamic tool library | same (same compiler, flags and headers; both dynamic) |
| SPD3 port, PTRacer (every access) | our compiler, `-O3 -ftapir=lambda -cilksan-ptracer-hooks`; shim built with clang 3.7 `-O2`; dynamic libftdebug.so | notool-lambda: the same compiler and flags, the shim's notool build, no tool library | out-of-line calls into the shim, then into the shared library | no LTO of the hooks; dynamic tool library | same compiler and flags |
| TSan-spd3, Archer | clang 15, `-O3 -g -fopenmp -D_GNU_SOURCE -fsanitize=thread`, `-no-pie` at link; static TSan runtime; dynamic libomp (and libarcher.so for Archer) | notool / notoolpc: the same without `-fsanitize=thread` | out-of-line calls into the TSan runtime; compiler-rt builds sanitizer runtimes with `-fno-lto` (compiler-rt/CMakeLists.txt, `SANITIZER_COMMON_CFLAGS`) | no LTO of the hooks; libomp dynamic | same |
| Task-centric Archer | the image's clang 15.0.7, `-O3 -g -fopenmp -D_GNU_SOURCE -fno-omit-frame-pointer -fsanitize=thread`, `-no-pie` at link; libstdc++ | notool-jenke: `-O3 -g -fopenmp -D_GNU_SOURCE`, `-no-pie` at link, no frame-pointer flag | as TSan-spd3 | as TSan-spd3, plus libstdc++ | **not** quite: the frame-pointer flag is on the tool side only, as in the artifact's `clang_tsan_*.def` files |

**Asymmetries that favor our rows:** the TBB and OpenMP rows reach their tools through out-of-line calls, while ours
inline the hooks from bitcode. STINT, C-RACER and PINT get the same inlining from `-flto`. The TBB repository builds
karatsuba at -O2 and sort at -O0; Table 1's TBB rows are at -O3 with our compiler, like ours.

**Asymmetries within a row:** only Task-centric Archer's frame-pointer flag, which costs its tool side a little.

**PIE:** every OpenMP binary, tool and baseline alike (including Task-centric Archer's), links `-no-pie` like ours;
code generation stays at the compiler default. The TBB binaries link with g++ 5.4 on Ubuntu 16.04, which is non-PIE
by default (the two-program rows were not checked with `file`).

## STINT (Cilk Plus, serial)

**Origin:**
- Source: github.com/wustl-pctg/STINT at 9b3ca93.
- Image: the repo's own Dockerfile (Ubuntu 18.04), as a Singularity/Apptainer image built with `--fakeroot` from
  `stint/stint.def`.

**Changes:** none to their sources. `stint/stint.diff` pins the compiler commit and passes the build's parallelism.

**Build:**
1. `build-tapir.sh`, which builds their Tapir LLVM 9 fork;
2. `build-rts.sh`;
3. `make all` in each benchmark directory.

**Run:** inputs are in `stint/stint-bench.txt`: chol -n 2000 -z 20000; sort -n 25000000; fft -n 67108864;
heat -nx 2048 -ny 2048; mmul -n 2048; stra -n 2048; straz -n 2048. 3 rounds, interleaved, using the program's own
timer; peak RSS at P=1.

**Reproduce:** `stint/stint.sh` (build, then run) does all of the above from a clean directory: image, clone at
9b3ca93, `stint/stint.diff`, build, timing sweep, peak RSS, summary.

### Our ports (the STINT sub-row)

STINT on our 14 benchmark cases, serial, against STINT's own uninstrumented build of the same port. The row is
"our ports": STINT's compiler (LLVM 9 Tapir, `-fcilkplus`) does not take our sources as they are.

**Changes:** `stint/port.py` makes three mechanical edits and leaves every other byte alone:
1. `cilk_scope { B }` becomes `{ B cilk_sync; }` (that compiler has no `cilk_scope`);
2. the `#ifdef SERIAL` include of OpenCilk's `cilk_stub.h` is dropped (SERIAL is never defined);
3. STINT's END_OF_COMPUTATION hook goes before main's last return, calling `stint/stint-eoc.cpp`, which calls
   `global_trace.end_of_computation()` as STINT's own benchmarks do.

**Build:** STINT's compiler, runtime and flags from `benchmarks/sync/Makefile`. `-ori` uses TOOL_FLAGS; `-rd` adds
`-fsanitize=cilk -DEND_OF_COMPUTATION` and links STINT's tool objects. C sources take TOOL_FLAGS without `-std=c++11`,
plus `-D_GNU_SOURCE` as in our builds. getoptions.c stays uninstrumented, like their getoptions.o.

**Gate:** 1 worker, `-i 1`. Both builds must exit 0, report no race, print no failure, and print the same answer lines
as our f64-notool binary. `-rd` must print STINT's `###stats:###` and `-ori` must not. matmul (backend "Broken function
found") and spp_sort (LTO "Broken module found") do not build with STINT's compiler, and nqueens' `-rd` build aborts;
the script drops such programs and lists them.

**Run:** our default inputs, `-i 3` (the program prints the fastest of 3 iterations), qsort with seeds 1 and 2. 3
rounds, interleaved and reversed, 1 worker; peak RSS at `-i 1`. fib is not counted in the geomeans, because under
STINT's compiler our timer captures none of its work.

**Reproduce:** `stint/stint.sh ours`, after `stint.sh build`, with BENCH set to our benchmark sources and NOTOOL to the
f64-notool binaries from `ours/ours.sh`.

**Redistributable:** check STINT's repository for its license; we redistribute nothing.

## C-RACER (Cilk Plus), the original implementation

**Origin:**
- Tool and its modified Cilk Plus runtime: github.com/wustl-pctg/cracer at 033f0bc0 (2019-06-30).
- Compiler: gitlab.com/wustl-pctg-pub/llvm-cilk, branch cilkplus, at a7582a488514, with clang-cilk and compiler-rt
  b696762.
- Image: built from docker://ubuntu:14.04 by `cracer/cracer.def`.

**Changes:**
- **Config only:** rdtool's `config.mk` takes the README's LTO values, so `RUNTIME_LIB` points at the LTO runtime
  (`cracer/cracer.diff`, which also adds the race probe the gate uses).
- **Build-environment fixes:**
  - LLVM is configured with `--with-binutils-include=/usr/include` so that LLVMgold.so gets built.
  - A no-op `groff` stub is put on PATH so that `make install` gets past the man page.
  - `cracer.def` installs Ubuntu's `python` package (2.7, as `/usr/bin/python`), since LLVM 3.4's configure looks
    for `python`.
  - A copy of the `-flto` runtime archive is indexed with `ranlib --plugin LLVMgold.so`.

**Run:** a gate, then 3 rounds at P=1 and 24, and peak RSS at P=1. The program's time is the one all-digit line of
its output (matmul prints "Max error" first). The other 8 programs abort at every optimization level (note b).

**Reproduce:** `cracer/cracer.sh` (build, then run) does the Table 1 configuration from a clean directory: image
`cracer/cracer.def`, the four clones at their pins, `cracer/cracer.diff`, compiler, `-flto` runtime with the indexed
archive, rdtool, gate, sweep at P=1 and 24, peak RSS and summary.

**Redistributable:** license not checked; we redistribute nothing. A third party fetches the four repositories at
the pinned commits.

## SPD3 C++ port, PTRacer and FastRacer (TBB)

All three come from one artifact.

**Origin:**
- Source: github.com/prospar/fastracer-pmam-2022 at 5f57d728 (2022-03-26).
  - spd3-lib is the SPD3 port.
  - tdebug-lib is PTRacer. PTRacer's own repository, github.com/rutgers-apl/PTRacer, was not used.
  - The FastRacer library is the third.
- TBB 4.3 comes from the same tree.
- Image: buildpack-deps:xenial (Ubuntu 16.04, GCC 5.4), pinned as
  `docker://buildpack-deps@sha256:415c4103ddc94a0ba15cfc220a261f43f8000d0e8f6c7af73ded0c66e63e3a1b`, plus cmake
  3.10.3.

**Build-environment fixes:**
- spd3-lib is built with `CXX="g++ -std=c++11"`, because its Makefile alone omits C++11.
- TBB is built with `tdvars.sh` sourced, as their `build_notool.sh` does.
- In the image: the three tool libftdebug.so with g++ 5.4 at their Makefiles' `-O3 -fPIC -g` (notool's from its own
  Makefile), and libtbb.so.2 as TBB's release build (g++ 5.4, `-g -O2`, their `build/linux.gcc.inc`).

**Programs (Table 1's two-program rows):** their karatsuba and sort, with their hand-placed RecordMem calls unchanged,
compiled by the paper's clang 21.1.3 instead of their clang 3.7 (no `-ftaskdebug`):
```
clang++ --sysroot=<the image's /usr/include and /usr/lib/gcc/x86_64-linux-gnu> -target x86_64-unknown-linux-gnu \
  -fgnuc-version=5.4.0 -std=c++11 -O3 [-include d9notool.h] -I<tool lib>/include -I<TBB include copy> -c <prog>.cpp
g++ <prog>.o [d9stub.o] -L<tool lib>/obj -lftdebug -L<TBB lib> -ltbb -lpthread -lm -ldl -o <prog>   # in the image
```
- `<tool lib>` is notool, spd3-lib, tdebug-lib or fastracer; the sysroot must make clang select the image's GCC 5.4
  (`clang++ -v` shows "Selected GCC installation: …/5" and no host headers).
- **TBB include copy:** `enum kind_type {` (`tbb/task.h:321`) becomes `enum kind_type : unsigned {`, in a copy of the
  include dir; the libraries keep the unpatched headers. clang 21 rejects `kind_type(bound+1)` in a constant
  expression (task.h:517). g++ already gives this enum an unsigned int underlying type; a layout check (g++ with the
  unpatched headers vs clang 21 with the copy, printing the sizes and offsets of TBB's task types) must print
  identical output.
- **`-fgnuc-version=5.4.0`:** clang reports GNU 4.2.1 by default, so sort's `test_sort.cpp:13-21` declares its own
  lvalue-returning `std::move` (meant for compilers older than GNU 4.4.3), which clang 21 picks inside libstdc++ 5's
  `basic_filebuf` move constructor (`fstream.tcc:97`, a hard error). Reporting 5.4.0, the g++ that built libtbb.so.2
  and the tool libraries, makes sort use the real `std::move`. The tool builds execute the same RecordMem calls as
  under clang 3.7 (karatsuba 4,242,780, sort 11,033,792 at P=1).
- The notool baseline gets the same compiler, flags and headers.

**Harness additions (all ours, outside their tree):**
- `d9notool.h`, force-included in the notool build: `#define RecordMem(...) ((void)0)`. Their programs call
  RecordMem unguarded, and the notool library declares none.
- `d9stub.cpp`, linked into the notool build: `extern "C" void TD_Activate() {}` and `extern "C" void Fini() {}`,
  which the programs call and notool does not define.

**Run:** P=1 and P=24, P set with `taskset` masks; 3 interleaved rounds; minimum region-of-interest time per cell;
peak RSS at P=1.

**Every-access rows:** our 14 Cilk benchmarks ported to TBB, built at -O3 with our compiler, `-ftapir=lambda
-cilksan-ptracer-hooks`, the image's GCC 5.4 as the sysroot. A shim (`lambda-tbb-rts.cpp`, built with their clang 3.7
-O2) maps the lambda runtime onto TBB tasks and RecordMem; it is linked in the image with g++ 5.4 against each tool's
libftdebug.so.

**Redistributable: no.** The repository has no license. A third party clones it at 5f57d728 into `third_party/`.

## TSan-spd3 (OpenMP)

**Origin:**
- Source: github.com/lechenyu/TSan-spd3 at 737549268790a5bb6081b16236d13350cfe53f10 (2022-11-08), the commit the
  paper evaluated (the parent of e06788e). HEAD 3f7cf0e9d serializes tasks at barriers and is not the table row
  (note e).
- Toolchain: clang 15.0.0 built from that commit with the README's cmake line, bootstrapped by the clang 14.0.0
  release.

**Changes:** none.

**Build:** our 11 Cilk benchmarks ported to OpenMP tasks (github.com/kennyzzhang/productivity-tools at b369236f,
`cilkprace/race_detection_examples/omp`), built with `-O3 -g -fopenmp -D_GNU_SOURCE -fsanitize=thread`, `-no-pie` at
link. The baseline notoolpc is built with the same toolchain, without `-fsanitize=thread`.

**Run:** `-i 2` at the default input, 3 rounds at P=1 and 24, interleaved and reversed on odd rounds, under
`setarch -R`, with `TSAN_OPTIONS=ignore_noninstrumented_modules=1 report_bugs=0`; peak RSS at P=1. At `-i 2`, cholesky
exits 66 in its second iteration every run, so its cell is timed at `-i 1` for both spd3pc and notoolpc, in the same
rounds (note f).

**Reproduce:** `openmp/omp.sh` (build, then run) does this row and the Archer row from a clean directory: the clang
14.0.0 release tarball (sha256 pinned), both TSan-spd3 commits, the stock runtime from `openmp/archer.diff`, the 44
binaries (notool, notoolpc, spd3pc, archer), a race gate on `openmp/probe.c`, the sweep and a summary. spd3pc peaks at
36 GB on fib, so it needs about 40 GB of RAM; on a smaller machine `RSSCAP_MB` kills such runs (`rsscap.c`) and the
summary lists them. It needs git, cmake (3.13.4 or later), ninja, curl, xz, python3, GNU time at `/usr/bin/time`,
setarch and network access, on PATH.

**Redistributable:** it is an LLVM fork, so presumably Apache-2.0 with LLVM exceptions; check the repository.

## Archer (OpenMP, thread-centric)

**Origin:** the stock TSan runtime with Archer as the OMPT tool, on the same clang 15 and libomp as the notool
baseline: TSan-spd3 HEAD 3f7cf0e9 with its TSan runtime files put back to llvm-project 232bd331
(`openmp/archer.diff`), the runtime swapped into a copy of the clang resource dir.

**Changes:** none.

**Build and run:** as TSan-spd3, with `-resource-dir` pointing at that copy and `DEFAULT_OMPT_LIB=archer`.

**Reproduce:** `openmp/omp.sh`, together with TSan-spd3 above.

**Redistributable:** yes, it is upstream LLVM.

## Task-centric Archer (Jenke et al., OpenMP)

**Origin:**
- The SC-W'23 artifact image
  `ghcr.io/jprotze/must-archer-ci@sha256:ff41c772b42da60435dd5a9d138aa586788875d89b59345373107ce3442562d5`.
- Its clang 15.0.7 comes from github.com/jprotze/llvm-project at 1a9e4d219dce. That source branch no longer exists,
  so the image is the only source.

**Changes:** none.

**Build:** the same ports and the notool-jenke baseline, built inside the image with `/opt/llvm/bin/clang` and the
flags in the table above (`-no-pie` at link). Unlike the other toolchains, it uses libstdc++.

**Run:** as TSan-spd3, inside the image. Four ARCHER_OPTIONS settings were timed, lazy and direct each 0 or 1;
Table 1 reports lazy=0 direct=0, the best of the four (note h).

**Redistributable:** the image is public. A third party pulls it by digest.

## PINT (Cilk, author-provided)

**Origin:**
- The authors' source, obtained from them. It is not public.
- Compiler: github.com/neboat/opencilk-project (batcher).

**Changes:** two patches, described here only, since the source is not ours to publish.
- Library-call hooks (127 lines): weak no-op hooks so their programs link.
- Wiring (102 lines): wires the parallel detector into the remaining programs. It is over 5 lines, an exception to
  the rule above.

**Build and run:** the table's flags; a gate, then a sweep at P=1 and 24 and peak RSS at P=1.

**Redistributable: no.** A third party must ask the authors for the source.
