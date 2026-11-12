#!/bin/bash
# Reproduce Table 1's C-RACER row (the original implementation, wustl-pctg/cracer): brd (detector) over base
# (no detector) at P=1 and P=24, and peak memory at P=1, on the authors' benchmark programs that pass the gate, in the
# README's LTO configuration.
#   cracer.sh build     image + sources + compiler + runtime + rdtool + benchmarks + gate  (~3 h at JOBS=10)
#   cracer.sh run       timing sweep + peak RSS + summary  (~4 h; idle machine with 64 GB)
#   cracer.sh           both
#   cracer.sh gate|time|rss|summary   one step (the gate writes $OUT/progs.txt and $OUT/pass.tsv, which time and rss read)
# Env: JOBS (build parallelism, default 10), PS (worker counts, default "1 24"), CPU (core for P=1, default 5),
#      CORES (taskset list for P>1, default unpinned), ROUNDS (default 3), W (work dir, default ./third_party/cracer),
#      OUT (default ./results/cracer), SING (default: apptainer or singularity), ALL (programs to gate),
#      ARGS_<prog> (input override), RSSCAP_MB (RSS cap in MB for gate and rss runs, default 56000).
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
# The programs in the authors' rdtool/test/bench (fibx is not in their run_bench.py; left out). Inputs: the authors'
# run_bench.py values, except cilksort (25M), and qsort, nqueens, knapsack and strassen, which are smaller so that brd
# fits in 56 GB (brd memory grows with the number of spawned tasks).
ALL=${ALL:-cilksort matmul rectmul fib nqueens qsort cholesky lu strassen heat fft knapsack}
args() { case $1 in cilksort) a="-n 25000000" ;; matmul) a="-n 2048" ;; rectmul) a="-x 2500 -y 2500 -z 2500" ;;
  fib) a="35" ;; nqueens) a="12" ;; qsort) a="10000000" ;; cholesky) a="-n 3000 -z 30000" ;; lu) a="-n 2048" ;;
  strassen) a="-n 1024" ;; heat) a="-nx 2048 -ny 2048 -nt 500" ;; fft) a="-n 67108864" ;;
  knapsack) a="-f knapsack-example3.input" ;; esac; v=ARGS_$1; printf "%s" "${!v:-$a}"; }
# The programs' own result check, where the program has one (the others print their result; base and brd compared).
# fft's -c runs a fixed self-test instead of the timed transform.
chk() { case $1 in cilksort|matmul|rectmul|lu|strassen|fft) printf -- "-c" ;; esac; }
RSSCAP_MB=${RSSCAP_MB:-56000}   # brd peak memory is tens of GB on some programs
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
  # -fcilk-no-inline on the runtime too (rdtool/common.mk already puts it on rdtool and the programs). The Batcher
  # runtime keeps the deque tail as a pointer to a pointer; without the flag, the runtime's own cilk_for spawns with
  # clang-cilk's inline single-pointer push, which overwrites the batch deque during the detector's relabel batch.
  # Runtime, built with -flto as the README requires for LTO; its libtool archives bitcode with plain ar, so the
  # installed archive is then indexed with the gold plugin (otherwise gold cannot resolve __cilkrts_* at the link).
  # Gold is ld for every -flto step (README): the image's ld is bfd, which cannot link clang's bitcode objects.
  mkdir -p goldbin && ln -sf /usr/bin/ld.gold goldbin/ld
  [ -e rts/lib/x86_64/libcilkrts.a ] || X "export PATH=$W/goldbin:\$PATH && cd $W/cracer/cilkplusrts && ./setup.sh &&
    ./configure --prefix=$W/rts CC=$W/llvm-cilk/bin/clang CXX=$W/llvm-cilk/bin/clang++ \
      CFLAGS='-O3 -fno-omit-frame-pointer -flto -fcilk-no-inline' CXXFLAGS='-O3 -fno-omit-frame-pointer -flto -fcilk-no-inline' &&
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
# Gate: base at P=1 and brd at every P in $PS (-c at P=1 only: the check is serial and slow under brd), each under
# rsscap (RSSCAP_MB) so an over-memory run is reported, not OOM-killed. A run passes if it exits 0 with no race line,
# no wrong/fail/assert line, and (for programs without -c) the same result lines as base. Per program, $OUT/pass.tsv
# gets "prog P" for each P whose brd run passes (base P=1 must pass too); $OUT/progs.txt lists the programs that pass
# at P=1 (the kept set; time/rss/summary use these). Exits 1 if any base run fails, or if cilksort, matmul or rectmul
# (Table 1's 3) fail at any P; other failures only drop that program at that P.
gate() {
  echo -e "prog\targs\tmode\tP\trc\trace_lines\tmaxrss_kb\tkilled\tpass\tresult" > "$OUT/gate.tsv"
  : > "$OUT/progs.txt"; : > "$OUT/pass.tsv"; ok=1
  for b in $ALL; do ref=""; bok=0
    for mp in base:1 $(for p in $PS; do echo "brd:$p"; done); do m=${mp%%:*}; p=${mp##*:}
      rc=0; o=$(R "$p" "$BENCH" "$W/rsscap" "$W/gstats" 3600 $RSSCAP_MB ./bin/${b}_$m $(args $b) $([ "$p" = 1 ] && chk $b)) || rc=$?
      n=$(grep -c 'Race detected at address' <<< "$o" || true)
      res=$(grep -E 'Result|solutions|Best value|check result|Max error|error' <<< "$o" | grep -v WARNING | tr '\n' ' ' || true)
      bad=$(grep -ciE 'wrong|fail|assert' <<< "$o" || true)
      kb=$(awk '$1 == "maxrss_kb" {print $2}' "$W/gstats"); k=$(awk '$1 == "killed" {print $2}' "$W/gstats")
      [ "$m" = base ] && ref=$res
      pass=0; [ "$rc" = 0 ] && [ "$n" = 0 ] && [ "$bad" = 0 ] && { [ -n "$(chk $b)" ] || [ "$res" = "$ref" ]; } && pass=1
      echo -e "$b\t$(args $b)\t$m\t$p\t$rc\t$n\t$kb\t$k\t$pass\t${res:--}" | tee -a "$OUT/gate.tsv"
      if [ "$m" = base ]; then bok=$pass; [ $pass = 1 ] || ok=0
      else
        [ $bok = 1 ] && [ $pass = 1 ] && echo "$b $p" >> "$OUT/pass.tsv"
        [ "$p" = 1 ] && [ $bok = 1 ] && [ $pass = 1 ] && echo "$b" >> "$OUT/progs.txt"
        case $b in cilksort|matmul|rectmul) [ $pass = 1 ] || ok=0 ;; esac
      fi
    done
  done
  echo "kept (P=1): $(tr '\n' ' ' < "$OUT/progs.txt")"; for p in $PS; do echo "passing at P=$p: $(awk -v p=$p '$2 == p {printf "%s ", $1}' "$OUT/pass.tsv")"; done
  [ $ok = 1 ] && echo "gate PASS" || { echo "gate FAIL (see $OUT/gate.tsv)"; exit 1; }
}

# time and rss run over the gate's $OUT/progs.txt; time runs a (program, P) cell only if the gate passed it there
# ($OUT/pass.tsv).
progs() { [ -s "$OUT/progs.txt" ] || { echo "cracer.sh: no $OUT/progs.txt; run the gate first" >&2; exit 1; }; tr '\n' ' ' < "$OUT/progs.txt"; }
time_() {
  [ -x "$W/rsscap" ] || { echo "cracer.sh: run needs a finished build ($W/rsscap missing)" >&2; exit 1; }
  PROGS=$(progs)
  # Timing: every cell once per round, order reversed on odd rounds; the program's own timer (first stdout line, ms).
  echo -e "round\tprog\targs\tmode\tP\trc\tms\trace_lines" > "$OUT/sweep.tsv"
  for r in $(seq 0 $((ROUNDS - 1))); do
    order=$(for b in $PROGS; do for p in $PS; do grep -qx "$b $p" "$OUT/pass.tsv" && { echo "$b base $p"; echo "$b brd $p"; }; done; done)
    [ $((r % 2)) = 1 ] && order=$(tac <<< "$order")
    while read -r b m p; do
      rc=0; o=$(R "$p" "$BENCH" ./bin/${b}_$m $(args $b)) || rc=$?
      t=$(grep -m1 -E '^[0-9]+$' <<< "$o" || true); t=${t:--}   # matmul prints "Max error" first
      n=$(grep -c 'Race detected at address' <<< "$o" || true)
      echo -e "$r\t$b\t$(args $b)\t$m\t$p\t$rc\t$t\t$n" | tee -a "$OUT/sweep.tsv"
    done <<< "$order"
  done
}
rss_() {
  PROGS=$(progs)
  # Peak RSS at P=1: one run per cell, measured inside the image by rsscap (wait4 ru_maxrss of the program itself).
  echo -e "prog\targs\tmode\trc\tmaxrss_kb\tkilled" > "$OUT/rss.tsv"
  for b in $PROGS; do for m in base brd; do
    rc=0; R 1 "$BENCH" "$W/rsscap" "$W/stats" 3600 $RSSCAP_MB ./bin/${b}_$m $(args $b) > /dev/null || rc=$?
    echo -e "$b\t$(args $b)\t$m\t$rc\t$(awk '$1 == "maxrss_kb" {print $2}' "$W/stats")\t$(awk '$1 == "killed" {print $2}' "$W/stats")" | tee -a "$OUT/rss.tsv"
  done; done
}
summary() {
  # Summary: min over rounds per cell (rc 0, no race line); brd over base at the same P; geomean over the programs
  # the gate passed at that P (primary), and over cilksort, matmul and rectmul (secondary; the earlier row). Mem: P=1, over the kept programs.
  python3 -I - "$OUT" "$PS" "$(progs)" > "$OUT/summary.txt" <<'EOP'
import csv, math, os, sys
from collections import defaultdict
d, ps, B = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
okp = {tuple(l.split()) for l in open(f"{d}/pass.tsv") if l.strip()}   # (prog, P) that passed the gate
t = defaultdict(list)
for r in csv.DictReader(open(f"{d}/sweep.tsv"), delimiter="\t"):
    if r["rc"] == "0" and r["ms"] != "-" and r["race_lines"] == "0":
        t[(r["prog"], r["mode"], r["P"])].append(int(r["ms"]))
m = {}
if os.path.exists(f"{d}/rss.tsv"):
    m = {(r["prog"], r["mode"]): int(r["maxrss_kb"]) for r in csv.DictReader(open(f"{d}/rss.tsv"), delimiter="\t") if r["rc"] == "0"}
gm = lambda x: math.exp(sum(map(math.log, x)) / len(x)) if x else float("nan")
paper = {"1": "54.1x", "24": "61.3x", "Mem": "73.2x"}   # the earlier row, over cilksort, matmul and rectmul only
for sub, name, old in ((B, "all passing", False), ([b for b in "cilksort matmul rectmul".split() if b in B], "cilksort matmul rectmul", True)):
    print(f"== {name}: {' '.join(sub)}")
    for p in ps:
        x = {b: min(t[(b, "brd", p)]) / min(t[(b, "base", p)]) for b in sub
             if (b, p) in okp and t[(b, "brd", p)] and t[(b, "base", p)] and min(t[(b, "base", p)]) > 0}
        print(f"P={p:2s} " + "  ".join(f"{b} {x[b]:.2f}x" for b in x) + f"  geomean {gm(x.values()):.1f}x over {len(x)}"
              + (f"  (earlier row: {paper[p]})" if old and p in paper else ""))
    y = {b: m[(b, "brd")] / m[(b, "base")] for b in sub if (b, "brd") in m and (b, "base") in m}
    print("Mem  " + "  ".join(f"{b} {y[b]:.2f}x" for b in y) + f"  geomean {gm(y.values()):.1f}x over {len(y)}" + (f"  (earlier row: {paper['Mem']})" if old else ""))
EOP
  cat "$OUT/summary.txt"
}

case ${1:-all} in build) build ;; run) time_; rss_; summary ;; all) build; time_; rss_; summary ;;
  gate) gate ;; time) time_; summary ;; rss) rss_; summary ;; summary) summary ;;
  *) echo "usage: $0 [build|run|all|gate|time|rss|summary]"; exit 2 ;; esac
