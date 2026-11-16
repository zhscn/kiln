# Benchmarks

- `compare.lisp`, `micro*.lisp`, `gf*.lisp`, `fe-read.lisp`, `local-calls.lisp`, `captured-calls.lisp`, `double-tree.lisp`, `double-branches.lisp`: kiln's own.
- `cl-bench/`: cl-bench (Eric Marsden, maintained by Daniel Kochmański; public domain per its `cl-bench.asd`; `files/deflate.lisp` is copyright Gilbert Baumann), from https://gitlab.common-lisp.net/ansi-test/cl-bench at commit a054e5f (2026-10-29): the benchmark sources, `misc/gabriel.lisp` and `misc/message.gz`; not the report generator.
- `benchmarksgame/`: the SBCL programs of the Computer Language Benchmarks Game (revised BSD license, `benchmarksgame/LICENSE`), from its source archive (https://benchmarksgame-team.pages.debian.net/benchmarksgame/download/benchmarksgame-sourcecode.zip, downloaded 2026-11-07).

Both are copied unchanged in their own commit; kiln's changes to them are listed below.

`native-compile-small.lisp` measures warmed runtime compilation of independent small functions. Run `tools/bench-native-compile.py --modules build/boot/stage0`; select an output directory for each module set. It reports CPU microseconds per compile after warmup and verifies the compiled results. Keep the backend, heap configuration and machine load fixed when comparing modules.

Pass `--pipeline` to select the runtime compiler independently of how those modules were built. The default follows `KILN_BUILD_PIPELINE`, falling back to MIR. Current compilers accept MIR; `--pipeline hir` measures older compilers that still support HIR. Use `--backend target/release/kiln-cg` for a release backend; the default is the debug executable. The default heap is 8 GiB unless `MMTK_GC_TRIGGER` is set. Reports identify the inputs by checksum and summarize process means, rather than individual compilation tail latency.

`baselines/shared-base.json` records a fixed compile-file/load workload, machine configuration, cold base costs, warm medians and retained space. Run `tools/bench-tests.py --baseline bench/baselines/shared-base.json --output build/test-comparison` to reuse its test selection and order. Add `--rebuild-base` to compare cold construction as well as warm execution. The default regression budget is 10%; compare on the recorded machine and remeasure when changing the workload or environment. Space budgets cover the base and selected tests; reports also retain the whole test directory's usage. Raw samples stay in the ignored output directory.

## Running

`tools/bench.sh [--no-build] [--kiln-only | --sbcl-only] [NAME|GROUP ...]` runs cl-bench on kiln (an AOT executable with the five modules, each benchmark in a process of its own with a timeout) and on SBCL (`sbcl --script`, default optimization), and prints a table of milliseconds per run and the ratio. The harness is `cl-bench-prelude.lisp` (DEFBENCH, `*misc-dir*`) and `cl-bench-driver.lisp` (selection, timing, errors), around cl-bench's `files/` and `tests.lisp`, which are used unchanged; they replace cl-bench's `support.lisp` and `cl-bench.lisp` (ASDF, trivial-garbage, report files).

`KILN_BUILD_PIPELINE=mir` selects module construction and runtime compilation, including the CLOS benchmarks' calls to `compile`; MIR is also the default. Set `KILN_BENCH_DIR` to keep separate executables and results for each configuration. `--no-build` checks the selected pipeline against the last completed build and rejects a different pipeline or an interrupted build. Executables predating the pipeline stamp are treated as HIR builds.

The CLOS cases share class, method and instance definitions. Each selected CLOS
case runs its preceding CLOS cases in the same process, including when selecting
a single case by name.

`python3 tools/bench-game.py [NAME ...]` compares the portable, single-threaded
Benchmarks Game submissions listed below. It builds kiln with the release runtime,
compiles each submission with both kiln and SBCL, and checks the complete output
for every pair of runs. `--no-build` reuses existing executables and FASLs;
`--runs`, `--warmup`, and `--timeout` default to 3 measured pairs, 1 discarded
pair, and 30 seconds per process. Results and
per-process output are kept under `build/bench-game/`; `--output` selects another
directory. Build or runtime failures produce a nonzero exit status after the
remaining cases have run.

`--pipeline mir` selects the compiler used for the modules and benchmark
source; its default follows `KILN_BUILD_PIPELINE`, falling back to MIR. Use
separate output directories for comparisons. `--no-build` rejects a pipeline
that differs from the completed build or a build marked as interrupted; older
outputs without a pipeline stamp are treated as HIR. Successful result records
include the selected pipeline.

| Name | Source under `benchmarksgame/` | Input |
|---|---|---|
| binarytrees | `binarytrees.sbcl` | depth 14 |
| fannkuchredux | `fannkuchredux.sbcl-2.sbcl` | n = 9 |
| fasta | `fasta.sbcl` | n = 100000 |
| knucleotide | `knucleotide.sbcl-2.sbcl` | FASTA output for n = 100000 |
| nbody | `nbody.sbcl` | 100000 steps |
| pidigits | `pidigits.sbcl-2.sbcl` | 1000 digits |
| revcomp | `revcomp.sbcl` | FASTA output for n = 100000 |
| spectralnorm | `spectralnorm.sbcl` | n = 500 |

The driver adapts SBCL command-line access to a fixed argument list in generated
copies and calls `main`; it preserves the algorithms and source optimization
declarations. Both input-consuming programs receive the same SBCL-generated
FASTA file. The vendored Mandelbrot versions depend on SBCL VOP/SIMD or low-level
thread interfaces, and regex-redux needs CL-PPCRE, which kiln does not integrate;
the driver reports these cases as unsupported.

Timing covers each whole process, including startup, module or FASL loading, and
I/O. After discarded warmup pairs, runs alternate implementation order and report
the median for each implementation. Output comparison happens outside timing.
kiln uses kernel and CLOS modules, a fixed 1 GiB SemiSpace heap, and a 1 GiB Lisp
stack; SBCL has an 8 GiB dynamic-space limit. These diagnostic input sizes and
process timings are separate from the Benchmarks Game website's measurements.

`local-calls.lisp` isolates propagation across two local call sites. Compile it
as a program after the kernel, or run it with `sbcl --script`. The outer
`benchmark-local-calls` function remains callable for hardware counters; its
fixed workload prints a checksum of `2`. Count that function's entry-to-return
region to exclude startup. This focused workload measures local-call overhead; cl-bench covers broader
application kernels.

`captured-calls.lisp` uses two local call sites to update a shared mutable
accumulator. It exercises inlining that can eliminate closures and cells.
Run it the same way as `local-calls.lisp`, counting the entry-to-return region
of `benchmark-captured-calls`. Its fixed workload prints `2097150`.

`double-tree.lisp` repeats a stable double-float recurrence with two products
and a sum. `benchmark-double-tree` stays callable for isolated counters.
The fixed workload checks its result and prints `T`; it measures arithmetic
calls and intermediate boxing rather than general floating-point workloads.

`double-branches.lisp` applies the stable double-float recurrence through a
four-arm `case`. It checks the final value and isolates discarded branch
results, switch lowering, and boxing at assignment boundaries.

## Changes

None: the harness does not modify the vendored files.
