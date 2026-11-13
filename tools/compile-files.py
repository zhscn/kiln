#!/usr/bin/env python3
"""Compile independent Lisp files in isolated kiln processes."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import subprocess
import sys


def lisp_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', type=Path, nargs='+')
    parser.add_argument('-j', '--jobs', type=int, default=os.cpu_count() or 1)
    parser.add_argument('--executable', type=Path, default=root / 'build/boot/kiln1')
    parser.add_argument('--load', type=Path, action='append', default=[],
                        help='load a prerequisite in every worker, in argument order')
    parser.add_argument('--output-directory', type=Path)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    executable = args.executable.resolve(strict=True)
    sources = [path.resolve(strict=True) for path in args.files]
    prerequisites = [path.resolve(strict=True) for path in args.load]
    outputs = [(args.output_directory / path.with_suffix('.fasl').name
                if args.output_directory else path.with_suffix('.fasl')).resolve()
               for path in sources]
    if len(set(outputs)) != len(outputs):
        parser.error('input files must have distinct output paths')
    if set(outputs) & set(sources + prerequisites):
        parser.error('an output path would overwrite an input file')
    if args.output_directory:
        args.output_directory.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, KILN_SERVE='1')
    # Bound total CPU use when the backend also supports function workers.
    if args.jobs > 1:
        environment.setdefault('KILN_CG_THREADS', '1')

    def compile_one(pair):
        source, output = pair
        loads = ' '.join(f'(load {lisp_string(path)})' for path in prerequisites)
        form = (f'(let ((*standard-output* *terminal-io*) '
                f'(*error-output* *terminal-io*) (*trace-output* *terminal-io*)) '
                f'(handler-case (progn {loads} '
                f'(multiple-value-bind (output warnings failure) '
                f'(compile-file {lisp_string(source)} :output-file {lisp_string(output)}) '
                f'(declare (ignore warnings)) '
                f'(finish-output) (kiln.sys:exit (if (and output (not failure)) 0 1)))) '
                f'(error (condition) (format *error-output* "~&~A~%" condition) '
                f'(finish-output *error-output*) (kiln.sys:exit 1))))')
        request = f'(:eval 1 {lisp_string(form)})\n'
        try:
            result = subprocess.run([str(executable)], input=request, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    env=environment, cwd=root)
            return source, output, result.returncode, result.stdout
        except OSError as error:
            return source, output, 1, str(error)

    failed = False
    with ThreadPoolExecutor(max_workers=min(args.jobs, len(sources))) as workers:
        # Report in input order even when workers complete in another order.
        for source, output, status, log in workers.map(compile_one, zip(sources, outputs)):
            if status:
                failed = True
                print(f'FAIL {source}\n{log}', file=sys.stderr)
            else:
                print(output)
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
