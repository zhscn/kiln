#!/usr/bin/env python3
"""Measure warmed native COMPILE latency against a fixed set of kiln modules."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--modules', type=Path, required=True, help='directory containing the five backend modules (.lir or legacy .kir)')
parser.add_argument('--runs', type=int, default=5)
parser.add_argument('--pipeline', choices=('hir', 'mir'),
                    default=os.environ.get('KILN_BUILD_PIPELINE', 'mir'))
parser.add_argument('--backend', type=Path, default=root / 'target/debug/kiln-cg')
parser.add_argument('--output', type=Path, default=root / 'build/native-compile')
args = parser.parse_args()
if args.runs < 1:
    parser.error('--runs must be positive')
if args.pipeline not in ('hir', 'mir'):
    parser.error('KILN_BUILD_PIPELINE must be hir or mir')
backend = args.backend.resolve()
modules = [args.modules.resolve() / (f'{name}.lir' if (args.modules / f'{name}.lir').exists() else f'{name}.kir')
           for name in ['kernel', 'clos', 'frontend', 'eval', 'compiler']]
for path in [backend, *modules]:
    if not path.is_file():
        parser.error(f'missing benchmark input: {path}')
args.output.mkdir(parents=True, exist_ok=True)
program = args.output.resolve() / 'native-compile-small.lir'
benchmark = root / 'bench/native-compile-small.lisp'
harness = args.output.resolve() / 'native-compile-small.lisp'
if harness == benchmark.resolve():
    parser.error('--output must differ from the benchmark source directory')
harness.write_text(f'(setf kiln.compiler::*compiler-pipeline* :{args.pipeline})\n'
                   + benchmark.read_text())
env = dict(os.environ)
env.setdefault('MMTK_GC_TRIGGER', 'FixedHeapSize:8589934592')
# No target compiler session is executed while preparing the harness. The
# selected modules supply its runtime compiler and its environment.
def lisp_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

expr = f'(kiln:compile-file-to-lir {lisp_string(harness)} {lisp_string(program)})'
command = ['sbcl', '--noinform', '--non-interactive', '--load', 'tools/env.lisp',
           '--eval', '(ql:quickload "kiln" :silent t)', '--eval', expr]
with (args.output / 'prepare.log').open('w') as log:
    subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
samples = []
for i in range(args.runs):
    run = subprocess.run([str(backend), 'jit', *map(str, modules), str(program)],
                         cwd=root, env=env, capture_output=True, text=True)
    (args.output / f'run-{i}.out').write_text(run.stdout + run.stderr)
    run.check_returncode()
    samples.append(float(run.stdout.strip()))
report = {'pipeline': args.pipeline, 'heap': env['MMTK_GC_TRIGGER'],
          'backend': str(backend), 'backend_sha256': hashlib.sha256(backend.read_bytes()).hexdigest(),
          'modules': {p.name: {'path': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                      for p in modules},
          'benchmark_sha256': hashlib.sha256(benchmark.read_bytes()).hexdigest(),
          'harness_sha256': hashlib.sha256(harness.read_bytes()).hexdigest(),
          'program_sha256': hashlib.sha256(program.read_bytes()).hexdigest(),
          'sample_kind': 'process mean CPU microseconds per compile',
          'microseconds_per_compile': samples, 'median': statistics.median(samples)}
(args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'{report["median"]:.3f} microseconds/compile (median of {args.runs} processes)')
