#!/usr/bin/env python3
"""Compare portable, single-threaded Benchmarks Game submissions on kiln and SBCL."""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import time


CASES = {
    'fasta': ('fasta.sbcl', 100000),
    'binarytrees': ('binarytrees.sbcl', 14),
    'fannkuchredux': ('fannkuchredux.sbcl-2.sbcl', 9),
    'knucleotide': ('knucleotide.sbcl-2.sbcl', None),
    'nbody': ('nbody.sbcl', 100000),
    'pidigits': ('pidigits.sbcl-2.sbcl', 1000),
    'revcomp': ('revcomp.sbcl', None),
    'spectralnorm': ('spectralnorm.sbcl', 500),
}


UNSUPPORTED = {
    'mandelbrot': 'vendored versions use SBCL VOP/SIMD or low-level thread interfaces',
    'regexredux': 'requires CL-PPCRE, which is not integrated into kiln',
}


def lisp_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def source_for(source, size):
    # Replace only the SBCL command-line access; keep the benchmark algorithm.
    source = re.sub(r'#\+sbcl\s+sb-ext:\*posix-argv\*', '*game-argv*',
                    source, flags=re.IGNORECASE)
    source = re.sub(r'sb-ext:\*posix-argv\*', '*game-argv*',
                    source, flags=re.IGNORECASE)
    return (f'(defparameter *game-argv* \'("bench" "{size or 0}"))\n'
            + source + '\n(in-package :cl-user)\n(main)\n')


def checked(command, log, root, env):
    with log.open('w') as out:
        subprocess.run(command, cwd=root, env=env, stdout=out,
                       stderr=subprocess.STDOUT, check=True)


def build_case(root, directory, env):
    source = directory / 'program.lisp'
    forms = [
        '(ql:quickload "kiln" :silent t)',
        '(defvar *session* (kiln.compiler:make-session))',
        f'(kiln:compile-kernel {lisp_string(directory / "kernel.kir")} :session *session*)',
        f'(kiln:compile-clos {lisp_string(directory / "clos.kir")} :session *session*)',
        f'(kiln:compile-file-to-kir {lisp_string(source)} '
        f'{lisp_string(directory / "program.kir")} :session *session*)',
    ]
    command = ['sbcl', '--dynamic-space-size', '4GB', '--noinform',
               '--non-interactive', '--load', str(root / 'tools/env.lisp')]
    for form in forms:
        command += ['--eval', form]
    checked(command, directory / 'kiln-compile.log', root, env)
    checked([str(root / 'target/release/kiln-cg'), 'obj',
             *[str(directory / f'{name}.kir') for name in ('kernel', 'clos', 'program')],
             '-o', str(directory / 'program.o')], directory / 'codegen.log', root, env)
    checked(['cc', str(directory / 'program.o'),
             str(root / 'target/release/libkiln_launcher.a'),
             '-o', str(directory / 'kiln'), '-lpthread', '-ldl', '-lm'],
            directory / 'link.log', root, env)
    form = (f'(multiple-value-bind (path warnings failure) '
            f'(compile-file {lisp_string(source)} '
            f':output-file {lisp_string(directory / "program.fasl")}) '
            '(declare (ignore path warnings)) (when failure (sb-ext:exit :code 1)))')
    checked(['sbcl', '--dynamic-space-size', '4GB', '--noinform', '--no-sysinit',
             '--no-userinit', '--non-interactive', '--eval', form],
            directory / 'sbcl-compile.log', root, env)


def run_case(root, directory, implementation, index, timeout, env, input_path):
    command = ([str(directory / 'kiln')] if implementation == 'kiln' else
               ['sbcl', '--dynamic-space-size', '8GB', '--noinform', '--no-sysinit',
                '--no-userinit', '--non-interactive',
                '--load', str(directory / 'program.fasl')])
    prefix = directory / f'{implementation}-{index}'
    with input_path.open('rb') as stdin, prefix.with_suffix('.out').open('wb') as stdout, \
            prefix.with_suffix('.err').open('wb') as stderr:
        start = time.perf_counter()
        result = subprocess.run(['timeout', '--kill-after=1', str(timeout), *command],
                                cwd=root, env=env, stdin=stdin,
                                stdout=stdout, stderr=stderr)
        elapsed = time.perf_counter() - start
    if result.returncode == 124 or (result.returncode == 137 and elapsed >= timeout):
        return {'status': 'TIMEOUT'}
    if result.returncode:
        return {'status': 'ERROR', 'exit': result.returncode}
    return {'status': 'OK', 'seconds': elapsed}


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', nargs='*', help='names from ' + ', '.join([*CASES, *UNSUPPORTED]))
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--warmup', type=int, default=1)
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--output', type=Path, default=root / 'build/bench-game')
    args = parser.parse_args()
    if args.runs < 1 or args.warmup < 0 or args.timeout <= 0:
        parser.error('runs and timeout must be positive; warmup must be nonnegative')
    if any(name not in CASES and name not in UNSUPPORTED for name in args.cases):
        parser.error('unknown benchmark')
    selected = [name for name in CASES if not args.cases or name in args.cases]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(('KILN_', 'MMTK_', 'BENCH_')):
            env.pop(key)
    env.update(MMTK_GC_TRIGGER='FixedHeapSize:1073741824', KILN_STACK_SIZE='1073741824')
    if not args.no_build:
        checked(['cargo', 'build', '-q', '--release'], output / 'cargo.log', root, env)
    empty = output / 'empty-input'
    empty.write_bytes(b'')
    input_path = output / 'fasta-input.txt'
    # The same SBCL-generated FASTA bytes feed both implementations.
    build_names = list(dict.fromkeys((['fasta'] if any(
        name in selected for name in ('knucleotide', 'revcomp')) else []) + selected))
    results = {}
    for name, reason in UNSUPPORTED.items():
        if not args.cases or name in args.cases:
            results[name] = {'status': 'UNSUPPORTED', 'reason': reason}
            print(f'{name}: UNSUPPORTED ({reason})', flush=True)
    for name in build_names:
        filename, size = CASES[name]
        directory = output / name
        directory.mkdir(exist_ok=True)
        source = root / 'bench/benchmarksgame' / filename
        if not args.no_build:
            (directory / 'program.lisp').write_text(source_for(source.read_text(), size))
        print(f'{"using" if args.no_build else "building"} {name}', flush=True)
        if not args.no_build:
            try:
                build_case(root, directory, env)
            except subprocess.CalledProcessError:
                results[name] = {'status': 'BUILD-ERROR', 'source': filename, 'size': size}
                print(f'{name}: BUILD-ERROR (see {directory})', flush=True)
                continue
        if args.no_build and not all((directory / file).is_file()
                                     for file in ('kiln', 'program.fasl')):
            results[name] = {'status': 'BUILD-ERROR', 'source': filename, 'size': size}
            print(f'{name}: BUILD-ERROR (missing existing executable or FASL)', flush=True)
            continue
        if name == 'fasta':
            result = run_case(root, directory, 'sbcl', 'input', args.timeout, env, empty)
            if result['status'] != 'OK':
                raise RuntimeError('SBCL FASTA input generation failed')
            input_path.write_bytes((directory / 'sbcl-input.out').read_bytes())
        if name not in selected:
            continue
        if name in ('knucleotide', 'revcomp') and not input_path.is_file():
            results[name] = {'status': 'NO-INPUT'}
            continue
        stdin = input_path if name in ('knucleotide', 'revcomp') else empty
        samples = {'kiln': [], 'sbcl': []}
        status = 'OK'
        for index in range(args.warmup + args.runs):
            order = ('kiln', 'sbcl') if index % 2 == 0 else ('sbcl', 'kiln')
            for implementation in order:
                run = run_case(root, directory, implementation, index,
                               args.timeout, env, stdin)
                if run['status'] != 'OK':
                    status = f'{implementation.upper()}-{run["status"]}'
                    break
                if index >= args.warmup:
                    samples[implementation].append(run['seconds'])
            if status != 'OK':
                break
            if ((directory / f'kiln-{index}.out').read_bytes() !=
                    (directory / f'sbcl-{index}.out').read_bytes()):
                status = 'OUTPUT-MISMATCH'
                break
        record = {'status': status, 'samples': samples, 'source': filename, 'size': size}
        if status == 'OK':
            record.update({impl: statistics.median(values) for impl, values in samples.items()})
            record['ratio'] = record['kiln'] / record['sbcl']
            print(f'{name}: kiln {record["kiln"]:.6f}s / SBCL {record["sbcl"]:.6f}s '
                  f'= {record["ratio"]:.2f}x', flush=True)
        else:
            print(f'{name}: {status} (see {directory})', flush=True)
        results[name] = record
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    if any(record['status'] not in ('OK', 'UNSUPPORTED') for record in results.values()):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
