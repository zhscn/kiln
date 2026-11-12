#!/usr/bin/env python3
"""Measure warmed native COMPILE latency against a fixed set of kiln modules."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--modules', type=Path, required=True, help='directory containing the five backend modules (.lir or legacy .kir)')
parser.add_argument('--runs', type=int, default=5)
parser.add_argument('--output', type=Path, default=root / 'build/native-compile')
args = parser.parse_args()
if args.runs < 1:
    parser.error('--runs must be positive')
args.output.mkdir(parents=True, exist_ok=True)
program = args.output.resolve() / 'native-compile-small.lir'
# No target compiler session is executed while preparing the harness. The
# selected modules supply its runtime compiler and its environment.
def lisp_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

expr = f'(kiln:compile-file-to-lir {lisp_string(root / "bench/native-compile-small.lisp")} {lisp_string(program)})'
command = ['sbcl', '--noinform', '--non-interactive', '--load', 'tools/env.lisp',
           '--eval', '(ql:quickload "kiln" :silent t)', '--eval', expr]
with (args.output / 'prepare.log').open('w') as log:
    subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
modules = [args.modules.resolve() / (f'{name}.lir' if (args.modules / f'{name}.lir').exists() else f'{name}.kir')
           for name in ['kernel', 'clos', 'frontend', 'eval', 'compiler']]
samples = []
for i in range(args.runs):
    run = subprocess.run([str(root / 'target/debug/kiln-cg'), 'jit', *map(str, modules), str(program)],
                         cwd=root, capture_output=True, text=True, check=True)
    (args.output / f'run-{i}.out').write_text(run.stdout + run.stderr)
    samples.append(float(run.stdout.strip()))
report = {'microseconds_per_compile': samples, 'median': statistics.median(samples)}
(args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'{report["median"]:.3f} microseconds/compile (median of {args.runs} processes)')
