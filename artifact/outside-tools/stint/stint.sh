#!/bin/bash
# Reproduce Table 1's STINT row (Xu et al., ALENEX 2022): P=1 time and peak memory, each against the artifact's own
# uninstrumented build, on its 7 benchmarks with the paper's inputs (stint-bench.txt).
#   stint.sh build   image + source + compiler + runtime + benchmarks (~4 h at JOBS=10)
#   stint.sh run     timing sweep + peak RSS + summary  (~1 h; 1 core, fft peaks ~25 GB; idle machine)
#   stint.sh         both
#   stint.sh ours    the "our ports" sub-row: STINT on our 12 programs, ported by port.py (after build; ~1 h; 1 core;
#                    idle machine). Needs BENCH (our benchmark sources, as ours.sh) and NOTOOL (ours.sh's
#                    f64-notool binaries, for the reference answers).
# Env: JOBS (build parallelism, default 10), CPU (core for the P=1 runs, default 5), ROUNDS (default 3),
#      W (work dir, default ./third_party/stint), OUT (default ./results/stint), SING (default: apptainer or singularity).
# Needs apptainer or singularity with --fakeroot, git, python3 and network access; everything compiles inside the image.
# build resumes: each step is skipped if its output exists (stint.diff is applied right after the clone).
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
JOBS=${JOBS:-10} CPU=${CPU:-5} ROUNDS=${ROUNDS:-3}
W=$(mkdir -p "${W:-third_party/stint}" && cd "${W:-third_party/stint}" && pwd)
OUT=$(mkdir -p "${OUT:-results/stint}" && cd "${OUT:-results/stint}" && pwd)
SING=${SING:-$(command -v apptainer || command -v singularity || true)}
[ -n "$SING" ] || { echo "stint.sh: needs apptainer or singularity (with --fakeroot) on PATH, or SING=/path/to/it" >&2; exit 1; }
X() { "$SING" exec --bind "$W" "$W/stint.sif" bash -c "$1"; }

build() {
  cd "$W"
  [ -e stint.sif ] || "$SING" build --fakeroot stint.sif "$H/stint.def"
  if [ ! -d STINT ]; then
    git clone https://github.com/wustl-pctg/STINT && git -C STINT checkout --detach 9b3ca93
    git -C STINT apply "$H/stint.diff"     # pin the compiler commit; -j from JOBS
  fi
  [ -x STINT/opencilk-project/llvm/build/bin/clang ] || X "cd $W/STINT && JOBS=$JOBS ./build-tapir.sh"
  [ -e STINT/rts/lib/libcilkrts.a ] || X "cd $W/STINT && ./build-rts.sh"
  X "cd $W/STINT/benchmarks/sync && make -j$JOBS all"
  cp "$H/../rsscap.c" "$W/" && X "gcc -O2 -o $W/rsscap $W/rsscap.c"
}

run() {
  B=$W/STINT/benchmarks/sync
  [ -x "$W/rsscap" ] || { echo "stint.sh: run needs a finished build ($W/rsscap missing)" >&2; exit 1; }
  grep -v '^#' "$H/stint-bench.txt" > "$OUT/bench.txt"
  # Timing: every cell once per round, order reversed on odd rounds; the program's own timer ("Running time 1:",
  # strassen_z "Elapsed time in second:"); 1 worker on core $CPU; ASLR off.
  echo -e "round\tbench\tbuild\trc\tsecs" > "$OUT/sweep.tsv"
  for r in $(seq 0 $((ROUNDS - 1))); do
    order=$(while IFS='|' read -r b _; do echo "$b ori"; echo "$b rd"; done < "$OUT/bench.txt")
    [ $((r % 2)) = 1 ] && order=$(tac <<< "$order")
    while read -r b v; do
      IFS='|' read -r _ bin args _ <<< "$(grep "^$b|" "$OUT/bench.txt")"
      rc=0; o=$(taskset -c "$CPU" "$SING" exec --bind "$W" "$W/stint.sif" bash -c \
        "cd $B && CILK_NWORKERS=1 timeout 3600 setarch x86_64 -R ./$bin-$v $args" 2>&1 < /dev/null) || rc=$?
      t=$(grep -m1 -E '^(Running time 1|Elapsed time in second):' <<< "$o" | awk '{print ($NF == "s") ? $(NF-1) : $NF}' || true)
      echo -e "$r\t$b\t$v\t$rc\t${t:--}" | tee -a "$OUT/sweep.tsv"
    done <<< "$order"
  done
  # Peak RSS: one run per cell, measured inside the image by rsscap (wait4 ru_maxrss of the program itself).
  echo -e "bench\tbuild\trc\tmaxrss_kb" > "$OUT/rss.tsv"
  while IFS='|' read -r b bin args _; do
    for v in ori rd; do
      rc=0; taskset -c "$CPU" "$SING" exec --bind "$W" "$W/stint.sif" bash -c \
        "cd $B && CILK_NWORKERS=1 setarch x86_64 -R $W/rsscap $W/stats 3600 0 ./$bin-$v $args" > /dev/null 2>&1 < /dev/null || rc=$?
      echo -e "$b\t$v\t$rc\t$(awk '$1 == "maxrss_kb" {print $2}' "$W/stats")" | tee -a "$OUT/rss.tsv"
    done
  done < "$OUT/bench.txt"
  # Summary: min over rounds per cell; ratio rd/ori; geomean (Table 1 prints P=1 18.4x and Mem 7.7x).
  python3 -I - "$OUT" > "$OUT/summary.txt" <<'EOP'
import csv, math, sys
from collections import defaultdict
d = sys.argv[1]
t = defaultdict(list)
for r in csv.DictReader(open(f"{d}/sweep.tsv"), delimiter="\t"):
    if r["rc"] == "0" and r["secs"] != "-":
        t[(r["bench"], r["build"])].append(float(r["secs"]))
m = {(r["bench"], r["build"]): int(r["maxrss_kb"]) for r in csv.DictReader(open(f"{d}/rss.tsv"), delimiter="\t") if r["rc"] == "0"}
B = [l.split("|")[0] for l in open(f"{d}/bench.txt")]
gm = lambda x: math.exp(sum(map(math.log, x)) / len(x)) if x else float("nan")
x = {b: min(t[(b, "rd")]) / min(t[(b, "ori")]) for b in B if t[(b, "rd")] and t[(b, "ori")]}
y = {b: m[(b, "rd")] / m[(b, "ori")] for b in B if (b, "rd") in m and (b, "ori") in m}
for b in B:
    print(f"{b:6s} time {x.get(b, float('nan')):7.2f}x  rss {y.get(b, float('nan')):7.2f}x")
print(f"geomean P=1 {gm(x.values()):.1f}x over {len(x)}  (Table 1: 18.4x over 7)")
print(f"geomean Mem {gm(y.values()):.1f}x over {len(y)}  (Table 1: 7.7x over 7)")
EOP
  cat "$OUT/summary.txt"
}

# Our ports: port.py makes three mechanical edits (cilk_scope { B } -> { B cilk_sync; }, drop the SERIAL-only cilk_stub.h
# include, STINT's END_OF_COMPUTATION hook before main's last return). Each program is built twice with STINT's compiler,
# runtime and flags (benchmarks/sync/Makefile): -ori = TOOL_FLAGS; -rd = the same + -fsanitize=cilk -DEND_OF_COMPUTATION,
# linked with STINT's tool objects. C sources take TOOL_FLAGS minus -std=c++11, plus -D_GNU_SOURCE as our builds.
# A program that does not build or gate is dropped and reported. Gate: 1 worker, -i 1; ori and rd exit 0, report no race,
# print no failure and the same answer lines as f64-notool; rd prints STINT's "###stats:###" and ori does not.
# Time: as run, with -i 3 (the program prints the fastest of 3 iterations), qsort with seeds 1 and 2.
ours() {
  set +e
  : "${BENCH:?set BENCH to our benchmark sources}" "${NOTOOL:?set NOTOOL to the f64-notool binaries of ours.sh}"
  local ST=$W/STINT O=$W/ours R=$OUT/ours B=$W/STINT/benchmarks/sync
  local CC=$ST/opencilk-project/llvm/build/bin/clang
  local TF="-g -O3 -fcilkplus -fno-omit-frame-pointer -std=c++11 -D__CILKRTS_ABI_VERSION=1 -DTIMING_COUNT=1 -flto"
  local INC="-I$ST/rts/include -I$ST/stint_rdtool/include"
  local LIBS="$ST/rts/lib/libcilkrts.a -lpthread -ldl -lrt -lnuma -flto -ltcmalloc -rdynamic"
  local TOOL_OBJ=$(for o in drivercsan shadow_stack stat_util mem_access print_addr trace utility treap shadow_mem_2_helper; do
                     echo -n "$B/$o.o "; done)
  local CFC="${TF/-std=c++11 /} -D_GNU_SOURCE"
  # CASE|program|gate args|timing args (default inputs, as ours.sh)
  local CASES="cholesky|cholesky|-c|
cilksort|cilksort|-c|
fib|fib||
lu|lu|-c|
matmul|matmul|-c|
nqueens|nqueens||
qsort|qsort|-s 1|
rectmul|rectmul|-c|
rectmulred|rectmulred|-c|
spp_karatsuba|spp_karatsuba||
spp_sort|spp_sort||
strassen|strassen|-c|"
  [ -x "$W/rsscap" ] && [ -x "$CC" ] || { echo "stint.sh: ours needs a finished build" >&2; exit 1; }
  [ -d $O/src ] || { mkdir -p $O/obj $O/bin && python3 -I "$H/port.py" "$BENCH" $O/src && cp "$H/stint-eoc.cpp" $O/; } \
    || { echo "stint.sh: port failed" >&2; exit 1; }
  X "cd $O/obj && $CC $CFC $INC -c ../src/getoptions.c -o getoptions.o && ${CC}++ $TF $INC -c ../stint-eoc.cpp -o stint-eoc.o" \
    > $O/obj/common.log 2>&1 || { cat $O/obj/common.log; exit 1; }
  for p in cholesky cilksort fib lu matmul nqueens qsort rectmul rectmulred spp_karatsuba spp_sort strassen; do
    [ -x $O/bin/$p-rd ] && continue
    case $p in qsort|spp_*) cc="${CC}++ $TF" s=$p.cpp ;; *) cc="$CC $CFC" s=$p.c ;; esac
    g=getoptions.o; case $p in spp_*) g= ;; esac   # spp_* parse no options
    m=; [ $p = cholesky ] && m=-lm
    X "cd $O/obj && $cc $INC -c ../src/$s -o $p-ori.o && ${CC}++ $p-ori.o $g $LIBS $m -o ../bin/$p-ori \
       && $cc -fsanitize=cilk -DEND_OF_COMPUTATION $INC -c ../src/$s -o $p-rd.o \
       && ${CC}++ $p-rd.o $g stint-eoc.o $TOOL_OBJ $LIBS $m -o ../bin/$p-rd" > $O/obj/$p.log 2>&1 \
      && echo "BUILD $p: OK" || echo "BUILD $p: FAIL (dropped; $O/obj/$p.log)"
  done

  answer() {  # answer DIR EXE ARGS... (inside the image unless DIR is $NOTOOL) -> "status|race|bad|stats|answer lines"
    local d=$1 out st; shift
    if [ "$d" = "$NOTOOL" ]; then
      out=$(cd "$d" && CILK_NWORKERS=1 timeout -k 5 3600 setarch x86_64 -R ./"$@" 2>&1 </dev/null); st=$?
    else
      out=$(X "cd $d && CILK_NWORKERS=1 timeout -k 5 3600 setarch x86_64 -R ./$*" 2>&1 </dev/null); st=$?
    fi
    local race=-; grep -qE "Race detected|RACE" <<< "$out" && race=RACE
    grep -qE "detected total of [1-9]" <<< "$out" && race=RACE
    local bad=-; grep -qiE "WRONG|FAIL|wrong result|No solution|Invalid|racedetector: fatal" <<< "$out" && bad=BAD
    local stats=-; grep -q "###stats:###" <<< "$out" && stats=STATS
    echo "$st|$race|$bad|$stats|$(grep -E "^Result:|Total number of solutions|Sort succeeded" <<< "$out" | tr '\n' ' ')"
  }
  : > $O/GATE
  while IFS='|' read -r c p ga _; do
    [ -x $O/bin/$p-ori ] && [ -x $O/bin/$p-rd ] || { echo "GATE $c: not built"; continue; }
    ref=$(answer "$NOTOOL" $p.notool -i 1 $ga); ori=$(answer $O/bin $p-ori -i 1 $ga); rd=$(answer $O/bin $p-rd -i 1 $ga)
    IFS='|' read -r st0 _ _ _ a0 <<< "$ref"
    IFS='|' read -r st1 r1 b1 s1 a1 <<< "$ori"
    IFS='|' read -r st2 r2 b2 s2 a2 <<< "$rd"
    v=OK
    [ "$st0" = 0 ] || v=FAIL
    [ "$st1" = 0 ] && [ $r1 = - ] && [ $b1 = - ] && [ $s1 = - ] && [ "$a1" = "$a0" ] || v=FAIL
    [ "$st2" = 0 ] && [ $r2 = - ] && [ $b2 = - ] && [ $s2 = STATS ] && [ "$a2" = "$a0" ] || v=FAIL
    echo "GATE $c: $v  f64-notool[$ref]  ori[$ori]  rd[$rd]"
    [ $v = OK ] && echo $c >> $O/GATE
  done <<< "$CASES"
  echo "gate: $(wc -l < $O/GATE | tr -d ' ') of 12 cases pass: $(tr '\n' ' ' < $O/GATE)"
  [ -s $O/GATE ] || exit 1

  mkdir -p $R && : > $R/time.txt && : > $R/rss.txt
  for r in $(seq 0 $((ROUNDS - 1))); do
    order=$(while IFS='|' read -r c p _ ta; do grep -qx $c $O/GATE || continue
              for s in $([ $c = qsort ] && echo "1 2" || echo -); do for v in ori rd; do echo "$c|$p|$v|$s|$ta"; done; done
            done <<< "$CASES")
    [ $((r % 2)) = 1 ] && order=$(tac <<< "$order")
    while IFS='|' read -r c p v s ta; do
      args="-i 3 $ta"; [ $s != - ] && args="$args -s $s"
      t=$(taskset -c "$CPU" "$SING" exec --bind "$W" "$W/stint.sif" bash -c \
            "cd $O/bin && CILK_NWORKERS=1 timeout -s KILL 3600 setarch x86_64 -R ./$p-$v $args" 2>/dev/null </dev/null \
          | grep -E '^[0-9.]+$' | tail -1; exit ${PIPESTATUS[0]}) || t=none
      echo "$r $c$([ $s != - ] && echo /s$s) $v ${t:-none}" | tee -a $R/time.txt
    done <<< "$order"
  done
  while IFS='|' read -r c p _ ta; do grep -qx $c $O/GATE || continue
    for v in ori rd; do
      : > $W/stats  # so a run that writes no stats file reads as empty, not as the previous run's
      taskset -c "$CPU" "$SING" exec --bind "$W" "$W/stint.sif" bash -c \
        "cd $O/bin && CILK_NWORKERS=1 setarch x86_64 -R $W/rsscap $W/stats 3600 49152 ./$p-$v -i 1 $ta" > /dev/null 2>&1 </dev/null
      echo "$c $v $(awk '$1 == "maxrss_kb" || $1 == "rc" || $1 == "killed" {printf "%s ", $2}' $W/stats)" | tee -a $R/rss.txt
    done
  done <<< "$CASES"
  # Summary: min over rounds (qsort: mean over seeds of per-seed minimums), rd/ori per case, geomean. fib is listed but
  # not in the geomeans: under STINT's compiler its timer captures none of its work (ori and rd both time ~16 ns).
  python3 -I - $R > $R/summary.txt <<'EOP'
import sys, math, collections
d = sys.argv[1]
t = collections.defaultdict(list)
for l in open(f"{d}/time.txt"):
    r, c, v, s = l.split()
    if s != "none": t[(c, v)].append(float(s))
cases = list(dict.fromkeys(l.split()[1].split("/")[0] for l in open(f"{d}/time.txt")))
def cell(c, v):
    ks = [k for k in t if k[1] == v and k[0].split("/")[0] == c]
    if not ks or any(not t[k] for k in ks): return None
    return sum(min(t[k]) for k in ks) / len(ks)
gm = lambda x: math.exp(sum(map(math.log, x)) / len(x)) if x else float("nan")
x = {}
print("# time: 1 worker, -i 3, min over rounds (qsort: mean over seeds 1 2 of per-seed minimums); spread = (max-min)/min")
for c in cases:
    o, r = cell(c, "ori"), cell(c, "rd")
    sp = max((max(v) - min(v)) / min(v) for k, v in t.items() if k[0].split("/")[0] == c and v)
    if o and r: x[c] = r / o
    print(f"{c:15s} ori {o if o else float('nan'):9.4f}  rd {r if r else float('nan'):10.4f}  {x.get(c, float('nan')):8.2f}x  max spread {sp:4.0%}")
x.pop("fib", None)
print(f"geomean P=1 {gm(list(x.values())):.1f}x over {len(x)} (fib not counted)")
m = {}
for l in open(f"{d}/rss.txt"):
    p = l.split()
    if len(p) >= 5 and p[3] == "0" and p[4] == "none": m[(p[0], p[1])] = int(p[2])
y = {c: m[(c, "rd")] / m[(c, "ori")] for c in cases if (c, "rd") in m and (c, "ori") in m}
for c in cases: print(f"{c:15s} rss ori {m.get((c, 'ori'), 0) / 1024:9.1f} MB  rd {m.get((c, 'rd'), 0) / 1024:9.1f} MB  {y.get(c, float('nan')):7.2f}x")
y.pop("fib", None)
print(f"geomean Mem {gm(list(y.values())):.1f}x over {len(y)} (fib not counted)")
EOP
  cat $R/summary.txt
}

case ${1:-all} in build) build ;; run) run ;; ours) ours ;; all) build; run ;; *) echo "usage: $0 [build|run|ours|all]"; exit 2 ;; esac
