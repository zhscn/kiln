#!/usr/bin/env python3
"""Build the pinned Maxima corpus on kiln and run its startup checks and core suite."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('library_tests', ROOT / 'tools/test-libraries.py')
libraries = importlib.util.module_from_spec(spec)
spec.loader.exec_module(libraries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--corpus', type=Path, default=Path.home() / 'package/kiln-library-tests')
    parser.add_argument('--kiln', type=Path, default=ROOT / 'build/boot/kiln1')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/maxima-tests')
    parser.add_argument('--configuration', type=Path,
                        help='generated autoconf-variables.lisp; defaults to Maxima src/')
    parser.add_argument('--timeout', type=float, default=3600)
    parser.add_argument('--heap', default='FixedHeapSize:8589934592')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--test', help='one upstream core test file, for example rtest1')
    parser.add_argument('--share', action='store_true')
    parser.add_argument('--verbose-tests', action='store_true', help='show each test input and result')
    args = parser.parse_args()
    args.kiln = args.kiln.resolve()
    project = next(p for p in json.loads(libraries.MANIFEST.read_text())['projects']
                   if p['name'] == 'maxima')
    source = libraries.checked_project(project, args.corpus.resolve())
    config = args.configuration or source / 'src/autoconf-variables.lisp'
    if not config.is_file():
        parser.error('configure the Maxima source tree first, or supply --configuration')
    key = hashlib.sha256(args.kiln.read_bytes()).hexdigest()
    output = args.output.resolve() / key
    output.mkdir(parents=True, exist_ok=True)
    target_config = output / 'autoconf-variables.lisp'
    if not target_config.exists() or target_config.read_bytes() != config.read_bytes():
        target_config.write_bytes(config.read_bytes())
    env = dict(os.environ, KILN_SERVE='1', MMTK_GC_TRIGGER=args.heap,
               LC_ALL='C', LANG='C', LANGUAGE='C',
               KILN_MAXIMA_SOURCE=str(source) + '/', KILN_MAXIMA_BUILD=str(output) + '/',
               MAXIMA_PREFIX=str(source), MAXIMA_LAYOUT_AUTOTOOLS='false',
               MAXIMA_USERDIR=str(output / 'user'), MAXIMA_OBJDIR=str(output / 'objects'))
    for name in ('KILN_IMAGE', 'KILN_SAVE_IMAGE', 'KILN_MAXIMA_BUILD_ONLY',
                 'KILN_MAXIMA_TEST', 'KILN_MAXIMA_SHARE', 'KILN_MAXIMA_DISPLAY_ALL'):
        env.pop(name, None)
    if args.build_only:
        env['KILN_MAXIMA_BUILD_ONLY'] = '1'
    if args.test:
        env['KILN_MAXIMA_TEST'] = args.test
    if args.share:
        env['KILN_MAXIMA_SHARE'] = '1'
    if args.verbose_tests:
        env['KILN_MAXIMA_DISPLAY_ALL'] = '1'
    progress = output / 'progress.log'
    form = f'''(let ((out (open {libraries.lisp(progress)} :direction :output
                                    :if-exists :supersede)))
      (unwind-protect
           (let ((*standard-output* out) (*error-output* out))
             (load {libraries.lisp(ROOT / 'tools/test-maxima.lisp')}))
        (close out)))'''
    log = output / 'server.log'
    result = libraries.run([str(args.kiln)], log, args.timeout, env=env,
                           input=libraries.kiln_request(form), cwd=output)
    server_text = log.read_text(errors='replace')
    text = progress.read_text(errors='replace') if progress.exists() else ''
    result.update(compiler_sha256=key, revision=project['revision'],
                  progress_log=str(progress),
                  patches={name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                           for name in project.get('patches', [])},
                  fasl_bytes=sum(p.stat().st_size for p in output.rglob('*.fasl')),
                  configuration_sha256=hashlib.sha256(config.read_bytes()).hexdigest(),
                  build_completed='MAXIMA-BUILD-COMPLETED' in text,
                  startup_checks_completed='MAXIMA-STARTUP-CHECKS-COMPLETED' in text,
                  test_op_completed='MAXIMA-TEST-OP-COMPLETED' in text)
    totals = re.findall(r'No unexpected errors found out of ([\d,]+) tests\.', text)
    result['tests_without_unexpected_errors'] = [int(n.replace(',', '')) for n in totals]
    if result['status'] == 'completed' and (
            '(:ok 1 ' not in server_text or not result['startup_checks_completed']
            or (not args.build_only and (not result['test_op_completed']
                                        or not any(result['tests_without_unexpected_errors'])))
            or 'Error summary:' in text or 'Caused an error break:' in text):
        result['status'] = 'failed'
    (output / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"maxima: {result['status']} ({progress})")
    return int(result['status'] != 'completed')


if __name__ == '__main__':
    raise SystemExit(main())
