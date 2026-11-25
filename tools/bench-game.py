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
    'mandelbrot': ('mandelbrot.sbcl-3.sbcl', 800),
    'nbody': ('nbody.sbcl', 100000),
    'pidigits': ('pidigits.sbcl-2.sbcl', 1000),
    'revcomp': ('revcomp.sbcl', None),
    'spectralnorm': ('spectralnorm.sbcl', 500),
    'regexredux': ('regexredux.sbcl-4.sbcl', None),
}


FASTA_CONSUMERS = {'knucleotide', 'revcomp', 'regexredux'}
HOT_SIZES = {'fannkuchredux': 10, 'spectralnorm': 2000}
PPCRE_FILES = (
    'packages', 'specials', 'util', 'errors', 'charset', 'charmap', 'chartest',
    'lexer', 'parser', 'regex-class', 'regex-class-util', 'convert', 'optimize',
    'closures', 'repetition-closures', 'scanner', 'api',
)


def lisp_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def regexredux_source(source, ppcre_dir):
    library = '\n'.join((ppcre_dir / f'{name}.lisp').read_text() for name in PPCRE_FILES)
    # Compile the same compatibility forms for both implementations.
    for original, replacement in (
        ('#.*standard-optimize-settings*',
         '(optimize speed (space 0) (debug 1) (compilation-speed 0))'),
        ('#.*special-optimize-settings*', '(optimize speed space)'),
        ('(constantp regex env)', '(constantp regex)'),
        ('#*0', "(make-array 1 :element-type 'bit :initial-element 0)"),
    ):
        if original not in library:
            raise ValueError(f'unsupported CL-PPCRE source layout, missing {original}')
        library = library.replace(original, replacement)
    # The library is already in this compilation unit. Select the submission's
    # serial branch on both implementations, irrespective of their features.
    start = source.index('(eval-when (:compile-toplevel :load-toplevel :execute)')
    end = source.index('(eval-when (:compile-toplevel)', start)
    serial = re.sub(r'(#[-+])sb-thread\b', r'\1bench-regex-threads', source[:start] + source[end:])
    return library + '\n(in-package :cl-user)\n' + serial + '\n(main)\n'


def source_for(source, size, name, ppcre_dir=None):
    if name == 'regexredux':
        return regexredux_source(source, ppcre_dir)
    if name == 'mandelbrot':
        # Keep the submission's serial renderer. Both timed processes write
        # the PBM header and raster to the harness's redirected stdout.
        serial, marker, _ = source.partition('(defun par-render')
        if not marker:
            raise ValueError('Mandelbrot submission is missing its parallel renderer')
        if size <= 0 or size % 8:
            raise ValueError('the serial renderer requires a positive multiple of eight')
        return serial + f"""
(defun main ()
  (let ((n {size}))
    (with-open-file (stream "/dev/stdout" :direction :output
                           :element-type '(unsigned-byte 8) :if-exists :overwrite)
      (loop for character across (format nil "P4~%~D ~D~%" n n)
            do (write-byte (char-code character) stream))
      (render n stream))))

(main)
"""
    # Replace only the SBCL command-line access; keep the benchmark algorithm.
    source = re.sub(r'#\+sbcl\s+sb-ext:\*posix-argv\*', '*game-argv*',
                    source, flags=re.IGNORECASE)
    source = re.sub(r'sb-ext:\*posix-argv\*', '*game-argv*',
                    source, flags=re.IGNORECASE)
    return (f'(defparameter *game-argv* \'("bench" "{size or 0}"))\n'
            + source + '\n(in-package :cl-user)\n(main)\n')


def hot_source(program, samples):
    return program.removesuffix('(main)\n') + f"""
(main)
(dotimes (i {samples})
  #+sbcl (sb-ext:gc :full t)
  #+kiln (kiln.sys:%gc)
  (let ((start (get-internal-real-time)))
    (main)
    (let ((elapsed (- (get-internal-real-time) start)))
      (format *error-output* "bench-time ~D ~D~%"
              elapsed internal-time-units-per-second))))
"""


def hot_seconds(log, count):
    timings = re.findall(rb'^bench-time (\d+) ([1-9]\d*)\r?$', log, re.MULTILINE)
    if len(timings) != count:
        raise ValueError(f'expected {count} in-process timings, found {len(timings)}')
    return [int(ticks) / int(units) for ticks, units in timings]


def checked(command, log, root, env):
    with log.open('w') as out:
        subprocess.run(command, cwd=root, env=env, stdout=out,
                       stderr=subprocess.STDOUT, check=True)


def build_case(root, directory, env, pipeline, snapshot=False, timeout=30):
    source = directory / 'program.lisp'
    kiln_source = source
    executable = directory / 'kiln'
    if snapshot:
        program = source.read_text()
        entry = '(main)\n'
        assert program.endswith(entry)
        kiln_source = directory / 'program-snapshot.lisp'
        snapshot_path = directory / 'kiln-snapshot'
        snapshot_path.unlink(missing_ok=True)
        kiln_source.write_text(program.removesuffix(entry) +
                               f'(kiln.sys:save-image {lisp_string(snapshot_path)} '
                               ":toplevel #'main :executable t)\n")
        executable = directory / 'kiln-build-snapshot'
    forms = [
        '(ql:quickload "kiln" :silent t)',
        f'(setf kiln.compiler::*compiler-pipeline* :{pipeline})',
        '(defvar *session* (kiln.compiler:make-session))',
        f'(kiln:compile-kernel {lisp_string(directory / "kernel.lir")} :session *session*)',
        f'(kiln:compile-clos {lisp_string(directory / "clos.lir")} :session *session*)',
        f'(kiln:compile-file-to-lir {lisp_string(kiln_source)} '
        f'{lisp_string(directory / "program.lir")} :session *session*)',
    ]
    command = ['sbcl', '--dynamic-space-size', '4GB', '--noinform',
               '--non-interactive', '--load', str(root / 'tools/env.lisp')]
    for form in forms:
        command += ['--eval', form]
    checked(command, directory / 'kiln-compile.log', root, env)
    checked([str(root / 'target/release/kiln-cg'), 'obj',
             *[str(directory / f'{name}.lir') for name in ('kernel', 'clos', 'program')],
             '-o', str(directory / 'program.o')], directory / 'codegen.log', root, env)
    checked(['cc', str(directory / 'program.o'),
             str(root / 'target/release/libkiln_launcher.a'),
             '-o', str(executable), '-lpthread', '-ldl', '-lm'],
            directory / 'link.log', root, env)
    if snapshot:
        checked(['timeout', '--kill-after=1', str(timeout), str(executable)],
                directory / 'snapshot.log', root, env)
        if not snapshot_path.is_file():
            raise subprocess.CalledProcessError(1, [str(executable)])
        snapshot_path.replace(directory / 'kiln')
        executable.unlink()
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
    parser.add_argument('cases', nargs='*', help='names from ' + ', '.join(CASES))
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--snapshot', action='store_true',
                        help='build kiln executables with preinitialized heap snapshots')
    parser.add_argument('--hot', type=int, metavar='SAMPLES',
                        help='time repeated array kernels within each process after one warmup')
    parser.add_argument('--pipeline', choices=('mir',),
                        default=os.environ.get('KILN_BUILD_PIPELINE', 'mir'))
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--warmup', type=int, default=1)
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--cl-ppcre-dir', type=Path,
                        help='CL-PPCRE source directory for regexredux')
    args = parser.parse_args()
    build_stamp = args.pipeline + ('+snapshot' if args.snapshot else '')
    if args.pipeline != 'mir':
        parser.error('KILN_BUILD_PIPELINE must be mir')
    if args.runs < 1 or args.warmup < 0 or args.timeout <= 0:
        parser.error('runs and timeout must be positive; warmup must be nonnegative')
    if any(name not in CASES for name in args.cases):
        parser.error('unknown benchmark')
    selected = [name for name in CASES if not args.cases or name in args.cases]
    if args.hot is not None:
        if args.hot < 1 or args.snapshot:
            parser.error('--hot needs a positive sample count and cannot use --snapshot')
        if not args.cases:
            selected = list(HOT_SIZES)
        if any(name not in HOT_SIZES for name in selected):
            parser.error('--hot supports only the two array kernels')
        build_stamp += f'+hot-{args.hot}'
    output = (args.output or root / 'build' /
              ('bench-game-hot' if args.hot else
               'bench-game-snapshot' if args.snapshot else 'bench-game')).resolve()
    output.mkdir(parents=True, exist_ok=True)
    results = {}
    if ('regexredux' in selected and args.cl_ppcre_dir is None
            and not (args.no_build and (output / 'regexredux' / 'pipeline').is_file())):
        selected.remove('regexredux')
        reason = 'requires CL-PPCRE sources via --cl-ppcre-dir'
        results['regexredux'] = {'status': 'UNSUPPORTED', 'reason': reason}
        print(f'regexredux: UNSUPPORTED ({reason})', flush=True)
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
    build_names = list(dict.fromkeys((['fasta'] if FASTA_CONSUMERS.intersection(selected)
                                    else []) + selected))
    for name in build_names:
        filename, size = CASES[name]
        if args.hot:
            size = HOT_SIZES[name]
        directory = output / name
        directory.mkdir(exist_ok=True)
        source = root / 'bench/benchmarksgame' / filename
        print(f'{"using" if args.no_build else "building"} {name}', flush=True)
        stamp = directory / 'pipeline'
        if args.no_build:
            previous = stamp.read_text().strip() if stamp.exists() else 'hir'
            if previous != build_stamp:
                results[name] = {'status': 'BUILD-ERROR', 'pipeline': args.pipeline,
                                 'source': filename, 'size': size}
                print(f'{name}: BUILD-ERROR (build mode differs; rebuild without --no-build)',
                      flush=True)
                continue
        if not args.no_build:
            stamp.write_text('building\n')
            try:
                program = source_for(source.read_text(), size, name, args.cl_ppcre_dir)
                if args.hot:
                    program = hot_source(program, args.hot)
                (directory / 'program.lisp').write_text(program)
                build_case(root, directory, env, args.pipeline, args.snapshot, args.timeout)
            except (OSError, ValueError) as error:
                results[name] = {'status': 'BUILD-ERROR', 'source': filename, 'size': size,
                                 'reason': str(error)}
                print(f'{name}: BUILD-ERROR ({error})', flush=True)
                continue
            except subprocess.CalledProcessError:
                results[name] = {'status': 'BUILD-ERROR', 'source': filename, 'size': size}
                print(f'{name}: BUILD-ERROR (see {directory})', flush=True)
                continue
            stamp.write_text(build_stamp + '\n')
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
        if name in FASTA_CONSUMERS and not input_path.is_file():
            results[name] = {'status': 'NO-INPUT'}
            continue
        stdin = input_path if name in FASTA_CONSUMERS else empty
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
                try:
                    timings = (hot_seconds((directory / f'{implementation}-{index}.err').read_bytes(),
                                           args.hot) if args.hot else [run['seconds']])
                except ValueError as error:
                    status = f'{implementation.upper()}-INVALID-TIMING ({error})'
                    break
                if index >= args.warmup:
                    samples[implementation].extend(timings)
            if status != 'OK':
                break
            if ((directory / f'kiln-{index}.out').read_bytes() !=
                    (directory / f'sbcl-{index}.out').read_bytes()):
                status = 'OUTPUT-MISMATCH'
                break
        record = {'status': status, 'samples': samples, 'source': filename, 'size': size,
                  'pipeline': args.pipeline, 'snapshot': args.snapshot}
        if args.hot:
            record['samples_per_process'] = args.hot
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
