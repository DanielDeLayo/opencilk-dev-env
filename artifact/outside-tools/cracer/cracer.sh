#!/bin/bash
# Reproduce Table 1's C-RACER row (the original implementation, wustl-pctg/cracer): brd (detector) over base
# (no detector) at P=1 and P=24, and peak memory at P=1, on the 3 benchmarks the shipped runtime completes (cilksort,
# matmul, rectmul; the other 8 abort, note b), in the README's LTO configuration.
#   cracer.sh build   image + sources + compiler + runtime + rdtool + benchmarks + gate  (~3 h at JOBS=10; Slurm: sbatch -p shared -c $JOBS)
#   cracer.sh run     timing sweep + peak RSS + summary  (~2 h; Slurm: sbatch -p fullmachine)
#   cracer.sh         both
# Env: JOBS (build parallelism, default 10), PS (worker counts, default "1 24"), CPU (core for P=1, default 5),
#      CORES (taskset list for P>1, default unpinned), ROUNDS (default 3), W (work dir, default ./third_party/cracer),
#      OUT (default ./results/cracer), SING (default: apptainer or singularity).
# Needs apptainer or singularity with --fakeroot, git, python3 and network access; everything compiles inside the image.
# build resumes: each step is skipped if its output exists (cracer.diff is applied right after the clone).
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-10} PS=${PS:-1 24} CPU=${CPU:-5} CORES=${CORES:-} ROUNDS=${ROUNDS:-3}
W=$(mkdir -p "${W:-third_party/cracer}" && cd "${W:-third_party/cracer}" && pwd)
OUT=$(mkdir -p "${OUT:-results/cracer}" && cd "${OUT:-results/cracer}" && pwd)
SING=${SING:-$(command -v apptainer || command -v singularity || true)}
[ -n "$SING" ] || { echo "cracer.sh: needs apptainer or singularity (with --fakeroot) on PATH, or SING=/path/to/it" >&2; exit 1; }
export CRACER_W=$W   # read by rdtool/config.mk
X() { "$SING" exec --bind "$W" "$W/cracer.sif" bash -c "$1"; }
PROGS="cilksort matmul rectmul"
args() { case $1 in cilksort) a="-n 25000000" ;; matmul) a="-n 2048" ;; rectmul) a="-x 2500 -y 2500 -z 2500" ;; esac; printf "%s" "$a"; }
BENCH=$W/cracer/rdtool/test/bench

build() {
  cd "$W"
  [ -e cracer.sif ] || "$SING" build --fakeroot cracer.sif "$H/cracer.def"
  if [ ! -d cracer ]; then
    git clone https://github.com/wustl-pctg/cracer && git -C cracer checkout --detach 033f0bc0
    git -C cracer apply "$H/cracer.diff"   # adds rdtool/config.mk (README values, LTO)
  fi
  # The authors' build-linux.sh layout; the gitlab.com/wustl-pctg URLs it uses now need a login, the -pub mirrors don't.
  if [ ! -d llvm-cilk/src ]; then
    git clone -b cilkplus https://gitlab.com/wustl-pctg-pub/llvm-cilk.git llvm-cilk/src
    git -C llvm-cilk/src checkout --detach a7582a488514
    git clone -b cilkplus https://gitlab.com/wustl-pctg-pub/clang-cilk.git llvm-cilk/src/tools/clang
    git -C llvm-cilk/src/tools/clang checkout --detach 39e31073c4be
    git clone https://github.com/cilkplus/compiler-rt llvm-cilk/src/projects/compiler-rt
    git -C llvm-cilk/src/projects/compiler-rt checkout --detach b696762
  fi
  # Compiler, configured as build-linux.sh does (Debug+Asserts), plus the include path that builds LLVMgold.so.
  # make install typesets the clang man page with groff, which the image lacks: no-op stand-ins (docs only).
  mkdir -p stubbin && for c in groff ps2pdf; do printf '#!/bin/sh\nexit 0\n' > stubbin/$c; chmod +x stubbin/$c; done
  [ -e llvm-cilk/lib/LLVMgold.so ] || X "mkdir -p $W/llvm-cilk/src/build && cd $W/llvm-cilk/src/build &&
    ../configure --prefix=$W/llvm-cilk --enable-targets=host --with-binutils-include=/usr/include &&
    make -j$JOBS && PATH=$W/stubbin:\$PATH make install"
  # Runtime, built with -flto as the README requires for LTO; its libtool archives bitcode with plain ar, so the
  # installed archive is then indexed with the gold plugin (otherwise gold cannot resolve __cilkrts_* at the link).
  # Gold is ld for every -flto step (README): the image's ld is bfd, which cannot link clang's bitcode objects.
  mkdir -p goldbin && ln -sf /usr/bin/ld.gold goldbin/ld
  [ -e rts/lib/x86_64/libcilkrts.a ] || X "export PATH=$W/goldbin:\$PATH && cd $W/cracer/cilkplusrts && ./setup.sh &&
    ./configure --prefix=$W/rts CC=$W/llvm-cilk/bin/clang CXX=$W/llvm-cilk/bin/clang++ \
      CFLAGS='-O3 -fno-omit-frame-pointer -flto' CXXFLAGS='-O3 -fno-omit-frame-pointer -flto' &&
    make -j$JOBS && make install &&
    ranlib --plugin $W/llvm-cilk/lib/LLVMgold.so $W/rts/lib/x86_64/libcilkrts.a"
  # rdtool and the programs, with gold as ld (README); sequential, since parallel makes race on mkdir.
  X "export PATH=$W/goldbin:\$PATH && cd $W/cracer/rdtool && make -C src &&
    make -C test/bench base brd"
  cp "$H/../rsscap.c" "$W/" && X "gcc -std=gnu99 -O2 -o $W/rsscap $W/rsscap.c"
  gate
}

# R P DIR CMD...: one run inside the image, in DIR, with P workers, ASLR off, 1 h limit; stdout and stderr on stdout.
R() { local p=$1 dir=$2 pin=""; shift 2
  if [ "$p" = 1 ]; then pin="taskset -c $CPU"; elif [ -n "$CORES" ]; then pin="taskset -c $CORES"; fi
  $pin "$SING" exec --bind "$W" "$W/cracer.sif" bash -c "cd $dir && CILK_NWORKERS=$p timeout 3600 setarch x86_64 -R $*" 2>&1 < /dev/null; }

# Gate (the exact binaries timed): base and brd at P=1 with their -c check report no race and exit 0. Exits 1
# otherwise.
gate() {
  echo -e "prog\tmode\trc\trace_lines\tcheck" > "$OUT/gate.tsv"; ok=1
  for b in $PROGS; do for m in base brd; do
    rc=0; o=$(R 1 "$BENCH" ./bin/${b}_$m $(args $b) -c) || rc=$?
    n=$(grep -c 'Race detected at address' <<< "$o" || true)
    c=$(grep -m1 -E 'check result|Max error' <<< "$o" || true)
    echo -e "$b\t$m\t$rc\t$n\t${c:--}" | tee -a "$OUT/gate.tsv"
    [ "$rc" = 0 ] && [ "$n" = 0 ] || ok=0
  done; done
  [ $ok = 1 ] && echo "gate PASS" || { echo "gate FAIL (see $OUT/gate.tsv)"; exit 1; }
}

run() {
  [ -x "$W/rsscap" ] || { echo "cracer.sh: run needs a finished build ($W/rsscap missing)" >&2; exit 1; }
  # Timing: every cell once per round, order reversed on odd rounds; the program's own timer (first stdout line, ms).
  echo -e "round\tprog\tmode\tP\trc\tms" > "$OUT/sweep.tsv"
  for r in $(seq 0 $((ROUNDS - 1))); do
    order=$(for b in $PROGS; do for p in $PS; do echo "$b base $p"; echo "$b brd $p"; done; done)
    [ $((r % 2)) = 1 ] && order=$(tac <<< "$order")
    while read -r b m p; do
      rc=0; o=$(R "$p" "$BENCH" ./bin/${b}_$m $(args $b)) || rc=$?
      t=$(grep -m1 -E '^[0-9]+$' <<< "$o" || true); t=${t:--}   # matmul prints "Max error" first
      echo -e "$r\t$b\t$m\t$p\t$rc\t$t" | tee -a "$OUT/sweep.tsv"
    done <<< "$order"
  done
  # Peak RSS at P=1: one run per cell, measured inside the image by rsscap (wait4 ru_maxrss of the program itself).
  echo -e "prog\tmode\trc\tmaxrss_kb" > "$OUT/rss.tsv"
  for b in $PROGS; do for m in base brd; do
    rc=0; R 1 "$BENCH" "$W/rsscap" "$W/stats" 3600 0 ./bin/${b}_$m $(args $b) > /dev/null || rc=$?
    echo -e "$b\t$m\t$rc\t$(awk '$1 == "maxrss_kb" {print $2}' "$W/stats")" | tee -a "$OUT/rss.tsv"
  done; done
  # Summary: min over rounds per cell; brd over base at the same P; geomean over the 3 programs.
  python3 -I - "$OUT" "$PS" > "$OUT/summary.txt" <<'EOP'
import csv, math, sys
from collections import defaultdict
d, ps = sys.argv[1], sys.argv[2].split()
t = defaultdict(list)
for r in csv.DictReader(open(f"{d}/sweep.tsv"), delimiter="\t"):
    if r["rc"] == "0" and r["ms"] != "-":
        t[(r["prog"], r["mode"], r["P"])].append(int(r["ms"]))
m = {(r["prog"], r["mode"]): int(r["maxrss_kb"]) for r in csv.DictReader(open(f"{d}/rss.tsv"), delimiter="\t") if r["rc"] == "0"}
B = "cilksort matmul rectmul".split()
gm = lambda x: math.exp(sum(map(math.log, x)) / len(x)) if x else float("nan")
paper = {"1": "54.1x", "24": "61.3x"}
for p in ps:
    x = {b: min(t[(b, "brd", p)]) / min(t[(b, "base", p)]) for b in B if t[(b, "brd", p)] and t[(b, "base", p)]}
    print(f"P={p:2s} " + "  ".join(f"{b} {x[b]:.2f}x" for b in x) + f"  geomean {gm(x.values()):.1f}x over {len(x)}"
          + (f"  (Table 1: {paper[p]} over 3)" if p in paper else ""))
y = {b: m[(b, "brd")] / m[(b, "base")] for b in B if (b, "brd") in m and (b, "base") in m}
print("Mem  " + "  ".join(f"{b} {y[b]:.2f}x" for b in y) + f"  geomean {gm(y.values()):.1f}x over {len(y)}  (Table 1: 73.2x over 3)")
EOP
  cat "$OUT/summary.txt"
}

case ${1:-all} in build) build ;; run) run ;; all) build; run ;; *) echo "usage: $0 [build|run|all]"; exit 2 ;; esac
