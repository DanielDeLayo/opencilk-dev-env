#!/bin/bash
# ours.sh: builds, gates, times and measures our rows (VISCOS, its ablations, Cilksan) on x86-64 Linux.
#
#   SRC=/path/to/opencilk-project [WORK=dir] [JOBS=24] ours.sh STAGE...      (STAGE: toolchain rows gate time rss large summary, or all)
#
# SRC is the source tree that built the paper's VISCOS rows: the unpacked tarball provided with this artifact. That tree was
# never committed as one; it is the upstream commits below with their patches applied, and contains:
#   - the compiler: opencilk-project 9f5208e9ceaf plus the 11 compiler patches, in order: llvm-1..5, clang-cilkfor-taskframe,
#     llvm-tasksimplify-syncregion-empty-entry, llvm-6-lvi-label-fetch, llvm-7-maap-and, llvm-simplifycfg-serialize-syncregion,
#     llvm-linux-elf-comdat;
#   - cilktools (cilkprace): cilktools-1..11 (flat labels, 64-byte entries, resplit, line locks, shadow MADV_DONTDUMP),
#     the strand-set patches ss-1, ss-1b and ss-2c, and then the label-spill patch cilktools-12-flat-spill (CILKPRACE_FLAT_SPILL);
#     cilkprace/CMakeLists.txt: -Xclang -mno-constructor-aliases restored on the bitcode flags (the paper's bitcode was built with it);
#   - cheetah 8a4af2e plus the sync-restore patch and the label-layout patch (os_label_config.h); runtime/CMakeLists.txt gives
#     leb8-flat the anchor define, as for leb8-ptr (the paper's cheetah was compiled with it);
#   - the benchmarks in cilktools/cilkprace/race_detection_examples (getoptions.c, the 12 benchmarks, with rectmulred.c's
#     check writing *errorf only on error) plus linear_sweep.c. BENCH overrides that directory.
# The strand-set and spill code is under #if CILKPRACE_STRAND_SET / CILKPRACE_FLAT_SPILL, so one tree builds every row. The
# paper's rows without strand sets were built from a tree without the strand-set and spill patches, and the strand-set rows
# without spill from one without the spill patch; SRC_PLAIN and SRC_SS name such trees to match that exactly (default SRC).
#
# How this relates to the paper's binaries: those were built by replaying the ninja commands of a CMake build of the same
# tree, with the label-implementation, granularity and feature defines that the CMake options below set; the benchmark
# compile and link lines, run commands, benchmark answer checks, timing method and summaries here are copied verbatim from
# those runs. The paper's race-test suites are not included; TESTS takes any such suite.
# Building from a clean slate through CMake, as this script does, has not been tested end to end.
#
# Needs: cmake, ninja, a host C/C++ compiler, python3, GNU time (/usr/bin/time), taskset, setarch; 24 physical cores for the
# 24-worker columns (CPUS24 overrides 0-23). Time and rss want an otherwise idle machine.
set -uo pipefail
: "${SRC:?set SRC to the opencilk-project tree (see the header)}"
SRC=$(realpath "$SRC") SRC_PLAIN=$(realpath "${SRC_PLAIN:-$SRC}") SRC_SS=$(realpath "${SRC_SS:-$SRC}")
WORK=$(realpath -m "${WORK:-$PWD/ours-work}") JOBS=${JOBS:-24} CORE=${CORE:-5} CPUS24=${CPUS24:-0-23}
BENCH=$(realpath -m "${BENCH:-$SRC/cilktools/cilkprace/race_detection_examples}")
TC=$WORK/toolchain L=lib/x86_64-unknown-linux-gnu V=$WORK/v R=$WORK/results
die() { echo "ours.sh: $*" >&2; exit 1; }

# Rows: NAME TOOL RUNTIME STATIC BFLAGS. RUNTIME is the runtime build below; BFLAGS go to the benchmark compiles only.
NKSF="-mllvm -cilksan-hoist-nests -mllvm -cilksan-coalesce-blocks -mllvm -cilksan-hoist-symbolic-nests"
ROWS=(
  "f64-notool none plain true"
  "f64-l128 cilkprace plain true"
  "f64-l128-NKS cilkprace plain true $NKSF"
  "f64ss-l128 cilkprace ss true"
  "f64ss-l128-NKS cilkprace ss true $NKSF"
  "f64ss-l128-NKS-spill cilkprace spill true $NKSF"
  "ab8-csan cilksan plain true"
  "ab8-csan-NKS cilksan plain true $NKSF"
)
MAIN="f64-notool f64-l128 f64-l128-NKS f64ss-l128 f64ss-l128-NKS f64ss-l128-NKS-spill ab8-csan ab8-csan-NKS"
row() {  # row: sets TOOL RT STATIC BFLAGS for row $NAME
  local r; for r in "${ROWS[@]}"; do set -- $r
    if [ "$1" = "$NAME" ]; then TOOL=$2 RT=$3 STATIC=$4; shift 4; BFLAGS="$*"; return; fi
  done; die "no row $NAME"; }
sfx() { local NAME=$1; row; case $TOOL in cilkprace) echo cilkprace ;; cilksan) echo cilksan ;; *) echo notool ;; esac; }

# Benchmark cases: NAME|EXE|default args|large args (the large inputs; qsort adds -s SEED).
CASES=(
  "cholesky|cholesky||-n 4000 -z 40000"        "cilksort|cilksort||-n 70000000"
  "fib|fib||-n 42"                              "lu|lu||-n 4096"
  "matmul|matmul||-n 2048"                      "nqueens|nqueens||-n 13"
  "qsort|qsort||-n 50000000"                    "rectmul|rectmul||-x 4096 -y 4096 -z 2048"
  "rectmulred|rectmulred||-x 4096 -y 4096 -z 2048" "spp_karatsuba|spp_karatsuba||-r 2000"
  "spp_sort|spp_sort||-m 20"                    "strassen|strassen||-n 4096"
  "linear_sweep|linear_sweep||-n 67108864 -p 400" "linear_sweep_o|linear_sweep|-o 1|-n 67108864 -p 400 -o 1"
)
# Timing groups (each group is one interleaved sweep).
GROUPS_=("spp_karatsuba strassen fib" "matmul spp_sort" "rectmul rectmulred nqueens" "cholesky cilksort lu qsort" "linear_sweep linear_sweep_o")

# ---- toolchain: the compiler, then one runtime build (cheetah + cilktools) per configuration -------------------------------
stage_toolchain() {
  mkdir "$WORK" 2>/dev/null; mkdir "$TC" || die "$TC exists"
  cmake -G Ninja -S $SRC/llvm -B $TC -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=On -DLLVM_TARGETS_TO_BUILD=host \
    -DLLVM_ENABLE_PROJECTS=clang -DLLVM_PARALLEL_LINK_JOBS=4 || die "cmake (compiler) failed"
  ninja -C $TC -j $JOBS clang llvm-link || die "compiler build failed"
  # Every runtime: leb8-flat shadow labels, so cheetah's labels are leb8-anchor (cheetah/runtime/CMakeLists.txt), 128-byte
  # granules refined to bytes on demand. The three configurations differ only in the cilkprace features they turn on.
  local cfg tree opts
  for cfg in plain ss spill; do
    case $cfg in
      plain) tree=$SRC_PLAIN opts="" ;;
      ss)    tree=$SRC_SS opts="-DCILKPRACE_STRAND_SET=ON" ;;
      spill) tree=$SRC opts="-DCILKPRACE_STRAND_SET=ON -DCILKPRACE_FLAT_SPILL=ON" ;;
    esac
    mkdir -p $WORK/rt-$cfg/out/include   # clang rejects an --opencilk-resource-dir without include/, even at configure time
    cmake -G Ninja -S $tree/runtimes -B $WORK/rt-$cfg -DLLVM_ENABLE_RUNTIMES="cheetah;cilktools" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=$TC/bin/clang -DCMAKE_CXX_COMPILER=$TC/bin/clang++ -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
      -DCHEETAH_ENABLE_ASAN=OFF -DCILKPRACE_LABEL_IMPL=leb8-flat -DCILKPRACE_GRANULARITY=128 -DCILKPRACE_ADAPTIVE_GRANULE=ON \
      -DCILKTOOLS_BUILD_CILKPISTON=OFF -DCILKTOOLS_TO_BUILD="cilksan;cilkprace" \
      -DCHEETAH_OUTPUT_DIR=$WORK/rt-$cfg/out -DCILKTOOLS_OUTPUT_DIR=$WORK/rt-$cfg/out -DLLVM_LINK=$TC/bin/llvm-link \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      "-DCMAKE_C_FLAGS=-fno-semantic-interposition --opencilk-resource-dir=$WORK/rt-$cfg/out" \
      "-DCMAKE_CXX_FLAGS=-fno-semantic-interposition --opencilk-resource-dir=$WORK/rt-$cfg/out" \
      $opts || die "cmake (runtime $cfg) failed"
    # The flags OpenCilk's own build (assertions on) gives the runtimes: -D_DEBUG -D_GLIBCXX_ASSERTIONS -fno-semantic-interposition.
    # --opencilk-resource-dir: the tools' -fopencilk compiles take cheetah's ABI bitcode and headers from this build's out/.
    # Only the two tools the rows use: the tree also holds CilkPiston, which is not part of the paper and is built by
    # default (CILKTOOLS_TO_BUILD selects the tools; the BUILD option alone does not stop it). One output dir for both
    # projects: cilktools' bitcode depends on cheetah's libopencilk-abi.bc under its own output dir. LLVM_LINK is given
    # because a standalone runtimes build looks for llvm-link only in its own bin/.
    ninja -C $WORK/rt-$cfg -j $JOBS || die "runtime $cfg failed"
    # A resource dir per configuration: the compiler's headers plus this build's libraries and headers.
    cp -a $TC/lib/clang/21 $WORK/res-$cfg && mkdir -p $WORK/res-$cfg/$L
    cp -a $WORK/rt-$cfg/out/include/. $WORK/res-$cfg/include/ && cp -a $WORK/rt-$cfg/out/lib/*/. $WORK/res-$cfg/$L/ \
      || die "runtime $cfg: no out/ to install"
    for f in libopencilk.a libclang_rt.cilkprace.a libcilkprace.bc libclang_rt.cilksan.a libcilksan.bc; do
      [ -s $WORK/res-$cfg/$L/$f ] || die "runtime $cfg: no $L/$f"
    done
    grep -q USE_OS_LABEL_LEB8_ANCHOR $WORK/res-$cfg/include/cilk/os_label_config.h || die "runtime $cfg: labels not leb8-anchor"
    # The runtime itself must be built with anchor labels too, not just the installed header: cheetah's compile lines get
    # -DUSE_OS_LABEL_LEB8_ANCHOR=1 from CILKPRACE_LABEL_IMPL=leb8-flat (cheetah's runtime/CMakeLists.txt, the
    # cheetah-1-flat-anchor hunk). Without it cheetah falls back to leb8-single labels while the tools and benchmarks use
    # leb8-anchor: the binaries link and pass at 1 worker, then segfault above (os_label ABI mismatch). Check
    # the shared library the rows link, for an anchor-only symbol and against the leb8-single signature.
    # No pipeline here: under pipefail, grep -q closing the pipe early gives nm SIGPIPE and the check a false failure.
    for lib in $WORK/res-$cfg/$L/libopencilk.a $WORK/res-$cfg/$L/libopencilk.so; do
      case $lib in *.so) nmf=-DC ;; *) nmf=-C ;; esac   # the .so's dynamic table is what the rows link against
      syms=$(nm $nmf --defined-only $lib) || die "runtime $cfg: nm $(basename $lib) failed"
      grep -q "os_label::spill()" <<< "$syms" || die "runtime $cfg: $(basename $lib) not built with anchor labels (no os_label::spill)"
      ! grep -q "restore_on_sync(unsigned short)" <<< "$syms" || die "runtime $cfg: $(basename $lib) built with leb8-single labels"
    done
  done
}

# ---- rows: the 13 benchmark binaries of every row --------------------------------------------------------------------------
stage_rows() {
  [ -x $TC/bin/clang ] || die "run the toolchain stage first"
  mkdir $V || die "$V exists"
  local r NAME
  for r in "${ROWS[@]}"; do
    set -- $r; NAME=$1; row; RES=$WORK/res-$RT; mkdir $V/$NAME $V/$NAME/obj
    common=(-resource-dir $RES -O3 -g -D_GNU_SOURCE $BFLAGS)
    case $TOOL in
      cilkprace) tool=(-fopencilk -mllvm -enable-static-race-detection=$STATIC -fsanitize=cilkprace
                       -mllvm -cilksan-bc-path=$RES/$L/libcilkprace.bc)
                 link=(-fopencilk -fsanitize=cilkprace -fopencilk-enable-pedigrees) ;;
      cilksan)   tool=(-fopencilk -mllvm -enable-static-race-detection=$STATIC -fsanitize=cilk
                       -mllvm -cilksan-bc-path=$RES/$L/libcilksan.bc)
                 link=(-fopencilk -fsanitize=cilk) ;;
      none)      tool=(-fopencilk) link=(-fopencilk) ;;
    esac
    s=$(sfx $NAME); o=$V/$NAME/obj
    $TC/bin/clang "${common[@]}" -o $o/getoptions.o -c $BENCH/getoptions.c || die "$NAME: getoptions"
    for b in cholesky cilksort fib lu matmul nqueens qsort rectmul rectmulred spp_karatsuba spp_sort strassen linear_sweep; do
      case $b in qsort|spp_*) cc=$TC/bin/clang++ src=$BENCH/$b.cpp ;; *) cc=$TC/bin/clang src=$BENCH/$b.c ;; esac
      case $b in spp_*) g="" ;; *) g=$o/getoptions.o ;; esac
      $cc "${common[@]}" "${tool[@]}" -o $o/$b.o -c $src &&
        $cc "${common[@]}" "${link[@]}" -no-pie $o/$b.o -o $V/$NAME/$b.$s $g $([ $b = cholesky ] && echo -lm) -lstdc++ \
        || die "$NAME: $b failed to build"
    done
    echo "$NAME: $(ls $V/$NAME | grep -c "\.$s$") binaries"
  done
}

# ---- gate: only rows that pass are timed -----------------------------------------------------------------------------------
# Every benchmark at 4 and 24 workers must exit 0, report no race, print no failure, and print the same answer lines as
# f64-notool at 4 workers. If TESTS names a directory of race tests (*.cpp), each is also built at -O0 and -O3 for every tool
# row and run at 1 worker: tests named *norace* must report no race, the others must report one.
answer() {  # answer WORKERS EXE ARGS... -> "status|race|bad|answer lines"
  local out st w=$1; shift
  out=$(env -i HOME=$HOME PATH=/usr/bin:/bin CILK_NWORKERS=$w timeout -k 5 3600 setarch x86_64 -R "$@" 2>&1 </dev/null); st=$?
  local race=-; grep -qE "RACE|Race detected" <<< "$out" && race=RACE
  local bad=-; grep -qiE "WRONG|FAIL|wrong result|No solution|Invalid" <<< "$out" && bad=BAD
  echo "$st|$race|$bad|$(grep -E "^Result:|Total number of solutions|Sort succeeded" <<< "$out" | tr '\n' ' ')"
}
GATE_BENCH=("cholesky -c" "cilksort -c" "fib" "lu -c" "matmul -c" "nqueens" "qsort -s 1" "rectmul -c" "rectmulred -c"
            "spp_karatsuba" "spp_sort" "strassen -c" "linear_sweep" "linear_sweep -o 1")
stage_gate() {
  local r NAME bb w ok got ref
  declare -A refs
  for bb in "${GATE_BENCH[@]}"; do set -- $bb; refs[$bb]=$(answer 4 $V/f64-notool/$1.notool "${@:2}"); done
  for r in "${ROWS[@]}"; do
    set -- $r; NAME=$1; row; s=$(sfx $NAME); ok=1
    for w in 4 24; do for bb in "${GATE_BENCH[@]}"; do
      set -- $bb; got=$(answer $w $V/$NAME/$1.$s "${@:2}")
      IFS='|' read -r st race bad ans <<< "$got"; IFS='|' read -r _ _ _ rans <<< "${refs[$bb]}"
      [ "$st" = 0 ] && [ $race = - ] && [ $bad = - ] && [ "$ans" = "$rans" ] ||
        { ok=0; echo "FAIL $NAME '$bb' at $w workers: status $st, $race, $bad, answer '$ans' (f64-notool '$rans')"; }
    done; done
    if [ -n "${TESTS:-}" ] && [ $TOOL != none ]; then
      RES=$WORK/res-$RT; mkdir -p $V/$NAME/tests
      case $TOOL in
        cilkprace) tf=(-fopencilk -mllvm -enable-static-race-detection=$STATIC -fsanitize=cilkprace -mllvm -cilksan-bc-path=$RES/$L/libcilkprace.bc -fopencilk-enable-pedigrees) ;;
        cilksan)   tf=(-fopencilk -mllvm -enable-static-race-detection=$STATIC -fsanitize=cilk -mllvm -cilksan-bc-path=$RES/$L/libcilksan.bc) ;;
      esac
      for t in $TESTS/*.cpp; do for O in -O0 -O3; do
        e=$V/$NAME/tests/$(basename $t .cpp)$O
        $TC/bin/clang++ -resource-dir $RES $O -g $BFLAGS "${tf[@]}" -no-pie $t -o $e -lstdc++ || { ok=0; echo "FAIL $NAME: $t $O does not build"; continue; }
        IFS='|' read -r st race _ _ <<< "$(answer 1 $e)"
        want=RACE; [[ $(basename $t) == *norace* ]] && want=-
        [ $race = $want ] && [[ $st = 0 || $want = RACE ]] || { ok=0; echo "FAIL $NAME: $(basename $e) race '$race' (want '$want'), status $st"; }
      done; done
    fi
    [ $ok = 1 ] && echo OK > $V/$NAME/GATE || echo BAD > $V/$NAME/GATE
    echo "gate $NAME: $(cat $V/$NAME/GATE)"
  done
}

# ---- timing ----------------------------------------------------------------------------------------------------------------
# wait_quiet: until the 1-minute load average has stayed below 0.5 for 10 consecutive minutes.
wait_quiet() { local q=0; while [ $q -lt 10 ]; do awk '{exit !($1 < 0.5)}' /proc/loadavg && q=$((q + 1)) || q=0; sleep 60; done; }
# sweep OUT NW CPUS ITERS ROUNDS "SEEDS" SIZE(default|large) BINDNOW TMO "CASES" ROW...: appends "ROUND CASE ROW SECONDS"
# lines to OUT; rows interleaved in each round, their order reversed on odd rounds; each run's time is the fastest of ITERS
# iterations as the program prints it; a run that fails or exceeds TMO seconds scores "none".
sweep() {
  local out=$1 nw=$2 cpus=$3 it=$4 rounds=$5 seeds=$6 size=$7 bn=$8 tmo=$9 cases=${10}; shift 10; local rows=("$@")
  local n; for n in "${rows[@]}"; do [ "$(cat $V/$n/GATE 2>/dev/null)" = OK ] || die "$n has not passed the gate"; done
  local r c i idx args x
  for ((r = 0; r < rounds; r++)); do
    until awk '{exit !($1 < 1.5)}' /proc/loadavg; do sleep 10; done
    for c in $cases; do
      for x in "${CASES[@]}"; do IFS='|' read -r cn exe dargs largs <<< "$x"; [ $cn = $c ] && break; done
      [ $size = large ] && args=($largs) || args=($dargs)
      for s in $([ $c = qsort ] && echo $seeds || echo -); do
        idx=("${rows[@]}"); [ $((r % 2)) = 1 ] && idx=($(printf '%s\n' "${rows[@]}" | tac))
        for n in "${idx[@]}"; do
          t=$(cd $V/$n && env -i HOME=$HOME PATH=/usr/bin:/bin ${bn:+LD_BIND_NOW=1} CILK_NWORKERS=$nw \
                timeout -s KILL $tmo taskset -c $cpus setarch x86_64 -R ./$exe.$(sfx $n) -i $it "${args[@]}" \
                $([ $s != - ] && echo -s $s) 2>/dev/null | grep -E '^[0-9.]+$' | tail -1; exit ${PIPESTATUS[0]}) || t=none
          echo "$r $c$([ $s != - ] && echo /s$s) $n ${t:-none}" >> $out
        done
      done
    done
  done
}
times() {  # times OUT NW CPUS SIZE ITERS ROUNDS SEEDS BINDNOW ROWS: one sweep per group, each after the machine is quiet
  local out=$1 nw=$2 cpus=$3 size=$4 it=$5 rounds=$6 seeds=$7 bn=$8; shift 8; local g
  mkdir -p $R
  for g in "${GROUPS_[@]}"; do wait_quiet; sweep $R/$out.txt $nw $cpus $it $rounds "$seeds" $size "$bn" 3600 "$g" "$@"; done
}
stage_time() {
  times main-w1 1 $CORE default 3 3 "1 2" "" $MAIN
  times main-w24 24 $CPUS24 default 3 3 "1 2" "" $MAIN
}
# Large inputs: -i 1, LD_BIND_NOW=1, each run killed after an hour (scored "none").
stage_large() {
  times large-w1 1 $CORE large 1 2 "1 2 3" 1 f64-notool f64ss-l128-NKS ab8-csan
  times large-w24 24 $CPUS24 large 1 3 "1 2 3" 1 f64-notool f64ss-l128-NKS
}

# ---- rss: peak resident memory, 1 worker, -i 1, default inputs plus cholesky on its large input --------------------------
stage_rss() {
  mkdir -p $R; local x n o rc m
  for x in "${CASES[@]}" "cholesky-large|cholesky|-n 4000 -z 40000|"; do
    IFS='|' read -r cn exe dargs _ <<< "$x"
    for n in $MAIN; do
      o=$(cd $V/$n && env -i HOME=$HOME PATH=/usr/bin:/bin CILK_NWORKERS=1 timeout -k 5 3600 /usr/bin/time -v \
            taskset -c $CORE setarch x86_64 -R ./$exe.$(sfx $n) $dargs -i 1 2>&1); rc=$?
      m=$(grep "Maximum resident set size" <<< "$o" | awk '{print $NF}')
      echo "$n $cn ${m:-none} $rc" >> $R/rss.txt
    done
  done
}

# ---- summary: per benchmark, each row's time over f64-notool's, and geomeans over benchmarks ------------------------------
# A cell is the minimum over rounds (qsort: the mean over seeds of the per-seed minimums); the spread is (max-min)/min.
stage_summary() {
  local f
  for f in $R/*-w1.txt $R/*-w24.txt; do [ -f $f ] && { echo "== $(basename $f .txt)"; python3 - $f <<'EOP'; }; done
import sys, math, collections
d = collections.defaultdict(list); order = []
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) != 4: continue
    if p[2] not in order: order.append(p[2])
    if p[3] != 'none': d[(p[1], p[2])].append(float(p[3]))
cases = sorted({c for c, _ in d})
def cell(bench, b):
    if bench == 'qsort':
        vs = [d[(k, b)] for k in cases if k.startswith('qsort/') and d.get((k, b))]
        if not vs: return None
        return sum(min(v) for v in vs) / len(vs), max((max(v) - min(v)) / min(v) for v in vs)
    v = d.get((bench, b))
    return (min(v), (max(v) - min(v)) / min(v)) if v else None
benches = sorted({c.split('/')[0] for c in cases})
base = 'f64-notool'; B = [b for b in order if b != base]; g = collections.defaultdict(list)
print('bench'.ljust(16) + f"{'notool_s':>10}" + ''.join(f'{b:>24}' for b in B))
for bench in benches:
    n = cell(bench, base)
    if n is None: print(bench.ljust(16), 'no f64-notool time'); continue
    row = bench.ljust(16) + f'{n[0]:10.4f}'
    for b in B:
        c = cell(bench, b)
        if c is None: row += f"{'none':>24}"; continue
        r = c[0] / n[0]; g[b].append(r); row += f'{r:17.3f} ({c[1]:4.0%})'
    print(row)
gm = lambda x: math.exp(sum(map(math.log, x)) / len(x)) if x else float('nan')
print('geomean'.ljust(26) + ''.join(f'{gm(g[b]):17.3f} ({len(g[b]):2d} b)' for b in B))
EOP
  [ -f $R/rss.txt ] && { echo "== rss"; python3 - $R/rss.txt <<'EOP'; }
import sys, math, collections
kb = collections.defaultdict(dict); bad = []; order = []
for l in open(sys.argv[1]):
    v, c, k, rc = l.split()
    if v not in order: order.append(v)
    if rc == '0' and k != 'none': kb[v][c] = int(k)
    else: bad.append(l.strip())
gm = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs)) if xs else float('nan')
base = 'f64-notool'
print("peak RSS geomean ratio to f64-notool (all cases / without cholesky-large); nonzero status: " + ('; '.join(bad) or 'none'))
for n in order:
    if n == base: continue
    cs = [c for c in kb[n] if c in kb[base]]
    print(f"  {n:22} {gm([kb[n][c] / kb[base][c] for c in cs]):8.3f}  ({gm([kb[n][c] / kb[base][c] for c in cs if c != 'cholesky-large']):.3f})  {len(cs)} cases")
EOP
}

[ $# -gt 0 ] || die "name a stage: toolchain rows gate time rss large summary, or all"
[ "$1" = all ] && set -- toolchain rows gate time rss large summary
for s in "$@"; do
  case $s in toolchain|rows|gate|time|rss|large|summary) echo "== $s"; stage_$s ;; *) die "unknown stage $s" ;; esac
done
