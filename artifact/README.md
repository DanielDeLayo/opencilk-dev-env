# Reproducibility artifact for the PLDI 2027 submission

This directory holds only what is needed to reproduce the paper's measurements: source
changes, build commands and the scripts that build, gate and time each configuration.
It contains no measured data and no record of how the paper's numbers were produced;
every number is remeasured by the reader.

## Layout

| Path | Contents |
|---|---|
| `ours/ours.sh` | One script that builds, gates, times and measures our rows (VISCOS, its ablations, Cilksan) from SRC, the OpenCilk source tree with our changes that the paper's rows were built from; the script's header names that tree (a tarball until it is committed). Stages in order: toolchain, rows, gate, time, rss, large, static, summary. The large inputs are inlined. |
| `outside-tools/RECIPES.md` | For each published detector in Table 1: where its source comes from (commit or digest), the changes we made, and the exact build and run commands. |
| `outside-tools/rsscap.c` | Time-limit and memory-cap wrapper for the outside-tool scripts. It records the peak RSS of the STINT and C-RACER cells. |
| `outside-tools/stint/` | `stint.sh` plus the definition, diff and benchmark list it applies, for the STINT rows; `port.py` and `stint-eoc.cpp` port our benchmarks for its "our ports" sub-row (`stint.sh ours`). |
| `outside-tools/cracer/` | `cracer.sh` plus the definition and diff it applies, for the C-RACER row. |
| `outside-tools/openmp/` | `omp.sh`, the Archer diff and the probe it uses, for the TSan-spd3 and Archer rows (task-centric Archer: `RECIPES.md`). |

The TBB rows (SPD3 C++ port, PTRacer, FastRacer) and PINT have build commands in
`outside-tools/RECIPES.md` but no script yet. PINT's source is not public and is not included.

## Rules

- Sources, build commands and scripts only. No results, logs, summaries, job scripts,
  checksums of absent files or provenance notes; those live under `scratch/`.
- Keep the file count small (16 files as of 2026-11-06). One script per outside tool
  with the files it applies, one script for our rows.
- Every number change in the paper is checked outside the artifact with
  `scratch/paper-audit/scripts/audit_tables.py` and
  `scratch/paper-audit/outside-tools/recompute_outside.py`; both must exit 0.
