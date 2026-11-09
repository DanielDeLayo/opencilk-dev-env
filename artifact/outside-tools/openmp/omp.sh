#!/bin/bash
# Reproduce Table 1's TSan-spd3 and Archer rows on the 11 OpenMP ports (kennyzzhang/productivity-tools b369236f):
# time at P=1 and P=24 and peak memory at P=1, each over an uninstrumented build with the same toolchain.
#   spd3pc  TSan-spd3 (Yu et al., PLDI 2023) at the paper's commit 7375492; baseline notoolpc.
#   archer  TSan-spd3 HEAD 3f7cf0e9's clang 15 and libomp, with the stock TSan runtime of its upstream base
#           (llvm-project 232bd331, archer.diff) and Archer selected by DEFAULT_OMPT_LIB; baseline notool.
#   omp.sh build   clang 14 + 2 LLVM builds + stock TSan runtime + 44 binaries + gate  (~5 h at JOBS=10, estimate;
#                  Slurm: sbatch -p shared -c $JOBS)
#   omp.sh run     timing sweep with peak RSS + summary  (~1.8 h at ROUNDS=3, PS="1 24"; spd3pc fib peaks at 36 GB,
#                  so ~40 GB of RAM; Slurm: sbatch -p fullmachine)
#   omp.sh         both
# Env: JOBS (build parallelism, default 10), PS (worker counts, default "1 24"), ROUNDS (default 3), TMO (seconds before
#      a run is killed, default 1800), W (work dir, default ./third_party/openmp), OUT (default ./results/openmp),
#      RSSCAP_MB (kill a run whose resident memory passes this, default 0 = no cap; e.g. 28000 on a 31 GB machine,
#      where spd3pc fib would swap; ulimit -v cannot do this, TSan reserves terabytes of address space at startup).
# Needs git, cmake, ninja, curl, xz, python3, GNU time at /usr/bin/time, setarch and network access.
# build resumes: each step is skipped if its output exists.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-10} PS=${PS:-1 24} ROUNDS=${ROUNDS:-3} TMO=${TMO:-1800} RSSCAP_MB=${RSSCAP_MB:-0}
W=$(mkdir -p "${W:-third_party/openmp}" && cd "${W:-third_party/openmp}" && pwd)
OUT=$(mkdir -p "${OUT:-results/openmp}" && cd "${OUT:-results/openmp}" && pwd)
SPD3=https://github.com/lechenyu/TSan-spd3.git
CLANG14=https://github.com/llvm/llvm-project/releases/download/llvmorg-14.0.0/clang%2Bllvm-14.0.0-x86_64-linux-gnu-ubuntu-18.04.tar.xz
BENCHES="cholesky cilksort fib lu matmul nqueens qsort rectmul rectmulred spp_karatsuba strassen"
VARIANTS="notool notoolpc spd3pc archer"   # the paper sweep's order
inst() { case $1 in *pc) echo "$W/install-spd3pc" ;; *) echo "$W/install-spd3" ;; esac; }
flags() { case $1 in spd3pc) echo "-fsanitize=thread" ;; archer) echo "-fsanitize=thread -resource-dir=$W/res-archer" ;; esac; }
# E variant P cmd...: cmd in the variant's environment: its toolchain first on PATH and
# LD_LIBRARY_PATH, P OpenMP threads, Archer as the OMPT tool for archer; TSan checks every access but prints no reports.
E() {
  local v=$1 p=$2 I; shift 2; I=$(inst "$v")
  local a=(PATH="$I/bin:$PATH" LD_LIBRARY_PATH="$I/lib:$I/lib/x86_64-unknown-linux-gnu" OMP_NUM_THREADS="$p"
           TSAN_OPTIONS="${TSAN:-ignore_noninstrumented_modules=1 report_bugs=0}")
  [ "$v" != archer ] || a+=(DEFAULT_OMPT_LIB=archer)
  env "${a[@]}" "$@"
}
# B cmd...: cmd with the bootstrap clang 14 (and its libc++) first.
B() { env PATH="$W/clang14/bin:$PATH" LD_LIBRARY_PATH="$W/clang14/lib/x86_64-unknown-linux-gnu:$W/clang14/lib" "$@"; }
# fetch dir url commit [path]: a depth-1 checkout of one commit (only path, if given).
fetch() {
  [ ! -d "$W/$1" ] || return 0
  rm -rf "$W/$1.tmp" && git init -q "$W/$1.tmp"
  [ -z "${4:-}" ] || git -C "$W/$1.tmp" sparse-checkout set "$4"
  git -C "$W/$1.tmp" fetch -q --depth 1 ${4:+--filter=blob:none} "$2" "$3"
  git -C "$W/$1.tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD && mv "$W/$1.tmp" "$W/$1"
}
# llvm name src: TSan-spd3's README cmake line with these trims (clang only, X86, no 32-bit compiler-rt, no
# libomptarget, 2 parallel links), built by clang 14 and installed to install-<name>.
llvm() {
  [ ! -e "$W/install-$1/.done" ] || return 0
  mkdir -p "$W/build-$1" && cd "$W/build-$1"
  B cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_INSTALL_PREFIX="$W/install-$1" -DLLVM_ENABLE_LIBCXX=ON -DLLVM_LIT_ARGS="-sv -j12" \
    -DCLANG_DEFAULT_CXX_STDLIB=libc++ -DLIBOMPTARGET_ENABLE_DEBUG=ON -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx;compiler-rt;openmp" \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DLLVM_INSTALL_UTILS=ON \
    -DLIBOMPTARGET_BUILD_CUDA_PLUGIN=False -DLIBOMPTARGET_BUILD_AMDGPU_PLUGIN=False \
    -DLIBOMPTARGET_AMDGCN_GFXLIST="" -DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_PARALLEL_LINK_JOBS=2 \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DOPENMP_ENABLE_LIBOMPTARGET=OFF "$W/$2/llvm"
  B ninja -j"$JOBS" install
  touch "$W/install-$1/.done"
}

build() {
  for c in git cmake ninja curl xz python3 setarch; do command -v $c > /dev/null || { echo "omp.sh: needs $c" >&2; exit 1; }; done
  cd "$W"
  if [ ! -x clang14/bin/clang ]; then   # the clang 14.0.0 release, sha256 pinned
    curl -fsSL -o clang14.tar.xz "$CLANG14"
    echo "61582215dafafb7b576ea30cc136be92c877ba1f1c31ddbbd372d6d65622fef5  clang14.tar.xz" | sha256sum -c
    rm -rf clang14 && mkdir clang14 && tar -xJf clang14.tar.xz -C clang14 --strip-components=1 && rm clang14.tar.xz
  fi
  fetch src-spd3pc "$SPD3" 737549268790a5bb6081b16236d13350cfe53f10
  fetch src-spd3 "$SPD3" 3f7cf0e9d99c9be20b18dd733b8b4630a43bf71a
  fetch pt https://github.com/kennyzzhang/productivity-tools.git b369236f3cb1bc192b2edc12b66de9c6d6a0e173 \
    cilkprace/race_detection_examples
  llvm spd3 src-spd3
  llvm spd3pc src-spd3pc
  # Archer's TSan runtime: HEAD's tree with the 11 changed runtime files put back to llvm-project 232bd331 and the 3
  # SPD3 files removed, built as the runtimes build in build-spd3, then swapped into a copy of
  # install-spd3's resource dir.
  cd "$W"
  [ -d src-stock ] || git -C src-spd3 worktree add -q --detach "$W/src-stock" HEAD
  [ -e src-stock/.archer-applied ] || { git -C src-stock apply "$H/archer.diff" && touch src-stock/.archer-applied; }
  if [ ! -e res-archer/.done ]; then
    C=$W/build-spd3/bin
    rm -rf rt-stock && B cmake -GNinja -S src-stock/runtimes -B rt-stock -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$C/clang" -DCMAKE_CXX_COMPILER="$C/clang++" -DCMAKE_ASM_COMPILER="$C/clang" \
      -DCMAKE_C_COMPILER_TARGET=x86_64-unknown-linux-gnu -DCMAKE_CXX_COMPILER_TARGET=x86_64-unknown-linux-gnu \
      -DCMAKE_ASM_COMPILER_TARGET=x86_64-unknown-linux-gnu -DCMAKE_AR="$C/llvm-ar" -DCMAKE_RANLIB="$C/llvm-ranlib" \
      -DCMAKE_NM="$C/llvm-nm" -DCMAKE_OBJCOPY="$C/llvm-objcopy" -DCMAKE_STRIP="$C/llvm-strip" \
      -DCMAKE_C_FLAGS="-fPIC -fno-semantic-interposition" -DCMAKE_CXX_FLAGS="-fPIC -fno-semantic-interposition" \
      -DLLVM_ENABLE_RUNTIMES=compiler-rt -DLLVM_CONFIG_PATH="$C/llvm-config" \
      -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-unknown-linux-gnu -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
      -DPACKAGE_VERSION=15.0.0git -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BUILD_BUILTINS=OFF \
      -DCOMPILER_RT_USE_LIBCXX=ON -DCOMPILER_RT_INCLUDE_TESTS=OFF
    B ninja -C rt-stock tsan
    rm -rf res-archer && cp -a install-spd3/lib/clang/15.0.0 res-archer
    cp rt-stock/lib/clang/15.0.0/lib/x86_64-unknown-linux-gnu/libclang_rt.tsan* res-archer/lib/x86_64-unknown-linux-gnu/
    touch res-archer/.done
  fi
  # The ports: clang -O3 -g -fopenmp, plus -fsanitize=thread for the tools; linked -no-pie, as our rows are (code
  # generation stays at the compiler default).
  S=$W/pt/cilkprace/race_detection_examples
  mkdir -p bin obj
  for v in $VARIANTS; do
    F="-O3 -g -fopenmp -D_GNU_SOURCE $(flags $v)"   # _GNU_SOURCE: timing.h uses RTLD_DEFAULT
    E $v 1 clang $F -c "$S/getoptions.c" -o obj/getoptions.$v.o
    for f in "$S"/omp/*.c "$S"/omp/*.cpp; do
      b=$(basename "${f%.*}"); cc=clang; case $f in *.cpp) cc=clang++ ;; esac
      E $v 1 $cc $F -no-pie "$f" obj/getoptions.$v.o -lm -o bin/$b.$v
    done
  done
  B clang -O2 "$H/../rsscap.c" -o rsscap   # timeout(1) plus an RSS cap; records why a run was killed
  gate
}

# Gate: each tool reports a race between two threads of a parallel region and nothing when they write separate
# cache lines (reports on, P=2), and Archer's OMPT tool loads. Writes $OUT/gate.tsv; exit 1 on any failure.
gate() {
  cd "$W" && mkdir -p probe
  echo -e "variant\tracy\trc\twarnings\ttool_load\tverdict" > "$OUT/gate.tsv"
  fail=0
  for v in spd3pc archer; do for r in 0 1; do
    d=""; [ $r = 0 ] || d=-DRACY
    E $v 2 clang -O1 -g -fopenmp $(flags $v) $d "$H/probe.c" -o probe/$v-$r
    rc=0; o=$(TSAN=ignore_noninstrumented_modules=1 E $v 2 env OMP_TOOL_VERBOSE_INIT=stdout \
      setarch x86_64 -R probe/$v-$r 2>&1 < /dev/null) || rc=$?
    n=$(grep -c 'WARNING: ThreadSanitizer:' <<< "$o" || true)
    t=$(grep -E 'Opening|Success|Tool was started' <<< "$o" | tr '\n\t' '  ' | cut -c1-200 || true)
    ok=PASS
    if [ $r = 1 ] && [ "$n" = 0 ]; then ok=FAIL; fi
    if [ $r = 0 ] && [ "$n" != 0 ]; then ok=FAIL; fi
    if [ $v = archer ] && ! grep -q 'archer.*Success' <<< "$o"; then ok=FAIL; fi
    [ $ok = PASS ] || fail=1
    echo -e "$v\t$r\t$rc\t$n\t${t:--}\t$ok" | tee -a "$OUT/gate.tsv"
  done; done
  echo "GATE $([ $fail = 0 ] && echo PASS || echo FAIL)" | tee -a "$OUT/gate.tsv"
  return $fail
}

run() {
  [ -x /usr/bin/time ] || { echo "omp.sh: run needs GNU time at /usr/bin/time" >&2; exit 1; }
  [ -x "$W/bin/strassen.archer" ] && [ -x "$W/rsscap" ] || { echo "omp.sh: run needs a finished build ($W/bin missing)" >&2; exit 1; }
  cd "$W"
  # Timing: per round, per program and worker count, every variant back to back, in reverse on odd rounds;
  # `<prog> -i 2` at its default input under GNU time and setarch -R, killed after TMO s; the time is the last
  # number-only stdout line (the better of 2 iterations), the memory is time's maximum resident set size.
  # killed: rss (passed RSSCAP_MB), timeout (TMO), or none.
  # spd3pc dies in the second iteration of cholesky (rc 66), so each round also runs cholesky at -i 1 for spd3pc and
  # its baseline notoolpc (iters 1); the TSan-spd3 summary takes cholesky from those runs.
  echo -e "round\tbench\tvariant\tP\titers\trc\tkilled\tsecs\tmaxrss_kb" > "$OUT/sweep.tsv"
  one() {   # one round bench variant P iters
    rm -f "$W/time.txt" "$W/cap.txt"; rc=0
    E $3 $4 /usr/bin/time -v -o "$W/time.txt" "$W/rsscap" "$W/cap.txt" "$TMO" "$RSSCAP_MB" setarch x86_64 -R bin/$2.$3 -i $5 \
      > "$W/stdout.txt" 2> /dev/null < /dev/null || rc=$?
    t=$(grep -E '^[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*$' "$W/stdout.txt" | tail -1 | tr -d ' \t' || true)
    m=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$W/time.txt" 2> /dev/null || true)
    k=$(awk '$1 == "killed" {print $2}' "$W/cap.txt" 2> /dev/null || true)
    echo -e "$1\t$2\t$3\t$4\t$5\t$rc\t${k:--}\t${t:--}\t${m:--}" | tee -a "$OUT/sweep.tsv"
  }
  rev() { echo $* | awk '{for (i = NF; i > 0; i--) printf "%s ", $i}'; }
  for r in $(seq 0 $((ROUNDS - 1))); do
    order=$VARIANTS o1="notoolpc spd3pc"; [ $((r % 2)) = 0 ] || { order=$(rev $VARIANTS); o1=$(rev $o1); }
    for b in $BENCHES; do for p in $PS; do for v in $order; do one $r $b $v $p 2; done; done; done
    for p in $PS; do for v in $o1; do one $r cholesky $v $p 1; done; done
  done
  # Summary: min time over rounds per cell, max peak RSS; ratio tool/baseline per program; geomean over the programs
  # whose 4 cells all ran clean (rc 0) at every P (as Table 1 does); TSan-spd3's cholesky cells are the -i 1 runs.
  python3 -I - "$OUT" $PS > "$OUT/summary.txt" <<'EOP'
import csv, math, sys
d, P = sys.argv[1], [int(p) for p in sys.argv[2:]]
best, rss = {}, {}
for r in csv.DictReader(open(f"{d}/sweep.tsv"), delimiter="\t"):
    if r["rc"] == "0" and r["secs"] != "-":
        k = (r["bench"], r["variant"], int(r["P"]))
        if r["iters"] == "1":   # cholesky at -i 1, for TSan-spd3 only
            k = (r["bench"] + "-i1", r["variant"], int(r["P"]))
        best[k] = min(best.get(k, 1e99), float(r["secs"]))
        rss[k] = max(rss.get(k, 0), int(r["maxrss_kb"]))
gm = lambda x: math.exp(sum(map(math.log, x)) / len(x)) if x else float("nan")
TABLE = {"spd3pc": ("TSan-spd3", "30.0x / 39.1x, Mem 14 GB, n=11"), "archer": ("Archer", "10.0x / 14.6x, Mem 4.2x, n=11")}
for v, base in (("spd3pc", "notoolpc"), ("archer", "notool")):
    if v == "spd3pc":   # cholesky from its -i 1 runs, in place of the -i 2 ones
        for x in (v, base):
            for p in P:
                best.pop(("cholesky", x, p), None); rss.pop(("cholesky", x, p), None)
                if ("cholesky-i1", x, p) in best:
                    best[("cholesky", x, p)], rss[("cholesky", x, p)] = best[("cholesky-i1", x, p)], rss[("cholesky-i1", x, p)]
    B = sorted({k[0] for k in best if not k[0].endswith("-i1") and all((k[0], x, p) in best for x in (v, base) for p in P)})
    print(f"{TABLE[v][0]} ({v} over {base}), {len(B)} programs: {', '.join(B)}")
    for b in B:
        print(f"  {b:14s}" + "".join(f"  P{p} {best[(b, v, p)] / best[(b, base, p)]:6.2f}x" for p in P)
              + f"  peak P{P[0]} {rss[(b, v, P[0])] / 1e6:6.2f} GB = {rss[(b, v, P[0])] / rss[(b, base, P[0])]:7.1f}x")
    print("  geomean" + "".join(f"  P{p} {gm([best[(b, v, p)] / best[(b, base, p)] for b in B]):.1f}x" for p in P)
          + f"  Mem P{P[0]} {gm([rss[(b, v, P[0])] / rss[(b, base, P[0])] for b in B]):.1f}x"
          + (f" (peaks {min(rss[(b, v, P[0])] for b in B) / 1e6:.1f}-{max(rss[(b, v, P[0])] for b in B) / 1e6:.1f} GB)" if B else ""))
    print(f"  Table 1 (P=1 / P=24): {TABLE[v][1]}")
bad = [r for r in csv.DictReader(open(f"{d}/sweep.tsv"), delimiter="\t") if r["rc"] != "0"]
print(f"Failed runs: {len(bad)} (expected: spd3pc cholesky at -i 2, rc 66 every run)")
for r in bad:
    print(f"  round {r['round']} {r['bench']}.{r['variant']} P={r['P']} -i {r['iters']} rc {r['rc']} killed {r['killed']}")
EOP
  cat "$OUT/summary.txt"
}

case ${1:-all} in build) build ;; run) run ;; all) build; run ;; *) echo "usage: $0 [build|run|all]"; exit 2 ;; esac
