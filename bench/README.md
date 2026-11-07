# Benchmarks

- `compare.lisp`, `micro*.lisp`, `gf*.lisp`, `fe-read.lisp`: kiln's own.
- `cl-bench/`: cl-bench (Eric Marsden, maintained by Daniel Kochmański; public domain per its `cl-bench.asd`; `files/deflate.lisp` is copyright Gilbert Baumann), from https://gitlab.common-lisp.net/ansi-test/cl-bench at commit a054e5f (2026-10-29): the benchmark sources, `misc/gabriel.lisp` and `misc/message.gz`; not the report generator.
- `benchmarksgame/`: the SBCL programs of the Computer Language Benchmarks Game (revised BSD license, `benchmarksgame/LICENSE`), from its source archive (https://benchmarksgame-team.pages.debian.net/benchmarksgame/download/benchmarksgame-sourcecode.zip, downloaded 2026-11-07).

Both are copied unchanged in their own commit; kiln's changes to them are listed below.

## Running

`tools/bench.sh [--no-build] [--kiln-only | --sbcl-only] [NAME|GROUP ...]` runs cl-bench on kiln (an AOT executable with the five modules, each benchmark in a process of its own with a timeout) and on SBCL (`sbcl --script`, default optimization), and prints a table of milliseconds per run and the ratio. The harness is `cl-bench-prelude.lisp` (DEFBENCH, `*misc-dir*`) and `cl-bench-driver.lisp` (selection, timing, errors), around cl-bench's `files/` and `tests.lisp`, which are used unchanged; they replace cl-bench's `support.lisp` and `cl-bench.lisp` (ASDF, trivial-garbage, report files).

## Changes

None: the harness does not modify the vendored files.
