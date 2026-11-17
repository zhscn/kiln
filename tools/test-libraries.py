#!/usr/bin/env python3
"""Fetch a pinned library corpus and probe host tests, ASDF, or portable source compilation."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'tests/libraries.json'


def lisp(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def run(command, output, timeout, *, env=None, input=None, cwd=ROOT):
    start = time.monotonic()
    with output.open('w') as stream:
        try:
            result = subprocess.run(command, cwd=cwd, env=env, input=input, text=True,
                                    stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
            status = 'completed' if result.returncode == 0 else 'failed'
            code = result.returncode
        except subprocess.TimeoutExpired:
            status, code = 'timeout', None
    return dict(status=status, exit_code=code, seconds=time.monotonic() - start,
                log=str(output))


def revision(path):
    return subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()


def checked_project(project, corpus):
    path = corpus / project['name']
    if revision(path) != project['revision']:
        raise ValueError(f'{path}: checkout differs from the pinned revision')
    return path


def registry(projects, corpus):
    directories = ' '.join(f'(:directory {lisp(str(corpus / p["name"]) + "/")})'
                           for p in projects)
    return f'(asdf:initialize-source-registry \'(:source-registry {directories} :inherit-configuration))'


def host_script(project, projects, args, output):
    system = lisp(project['system'])
    plan = output / 'sources.txt'
    cache = output / 'sbcl-cache'
    # Registry inheritance makes installed test dependencies available; logs and
    # source plans identify which sources the host actually selected.
    return f'''(require :asdf)
{registry(projects, args.corpus)}
(asdf:initialize-output-translations
 '(:output-translations (t ({lisp(str(cache) + '/')} :implementation)) :ignore-inherited-configuration))
(defmethod asdf:perform :around ((operation asdf:compile-op) (component asdf:cl-source-file))
  (let ((start (get-internal-real-time)))
    (format t "~&LIBRARY-COMPILE-BEGIN ~A~%" (asdf:component-pathname component))
    (multiple-value-prog1 (call-next-method)
      (format t "~&LIBRARY-COMPILE-SECONDS ~A ~F~%" (asdf:component-pathname component)
              (/ (- (get-internal-real-time) start) internal-time-units-per-second)))))
(format t "~&LIBRARY-HOST ~A ASDF ~A~%" (lisp-implementation-version) (asdf:asdf-version))
(let ((plan (asdf:make-plan nil 'asdf:load-op {system})))
  (with-open-file (s {lisp(plan)} :direction :output :if-exists :supersede)
    (dolist (action (asdf/plan:plan-actions plan))
      (when (and (typep (car action) 'asdf:load-op) (typep (cdr action) 'asdf:cl-source-file))
        (format s "~A~%" (asdf:component-pathname (cdr action)))))))
(let ((start (get-internal-real-time)))
  (asdf:load-system {system})
  (format t "~&LIBRARY-LOAD-SECONDS ~F~%"
          (/ (- (get-internal-real-time) start) internal-time-units-per-second)))
{('(eval (read-from-string ' + lisp(project['smoke_form']) + ')) (format t "~&LIBRARY-SMOKE-COMPLETED~%")') if project.get('smoke_form') else ''}
{'(asdf:test-system ' + system + ') (format t "~&LIBRARY-TEST-OP-COMPLETED~%")' if args.tests else ''}
(format t "~&LIBRARY-COMPLETE~%")
'''


def kiln_request(form):
    return f'(:eval 1 {lisp(form)})\n(:quit 2)\n'


def kiln_run(args, form, output):
    env = dict(os.environ, KILN_SERVE='1', MMTK_GC_TRIGGER=args.heap)
    env.pop('KILN_IMAGE', None)
    env.pop('KILN_SAVE_IMAGE', None)
    result = run([str(args.kiln)], output, args.timeout, env=env, input=kiln_request(form))
    text = output.read_text(errors='replace')
    if result['status'] == 'completed' and '(:ok 1 ' not in text:
        result['status'] = 'failed'
    result['debugger_entered'] = '(:debug ' in text
    return result


def source_probe(project, args, output):
    if not project.get('source_probe'):
        raise ValueError(f'{project["name"]}: no portable source probe declared')
    plan = args.plan_directory / project['name'] / 'sources.txt'
    host_report = json.loads((args.plan_directory / 'report.json').read_text())
    if host_report['projects'][project['name']].get('revision') != project['revision']:
        raise ValueError('host source plan does not match the pinned project revision')
    paths = [Path(p) for p in plan.read_text().splitlines()]
    project_root = (args.corpus / project['name']).resolve()
    if not paths or any(not p.resolve().is_relative_to(project_root) for p in paths):
        raise ValueError('source probe requires a nonempty plan entirely within the selected project')
    fasls = output / 'fasls'
    fasls.mkdir(exist_ok=True)
    for path in fasls.glob('*.fasl'):
        path.unlink()
    pairs = ' '.join(f'({lisp(p)} {lisp(fasls / (str(i) + ".fasl"))})' for i, p in enumerate(paths))
    progress = output / 'progress.log'
    form = f'''(progn (assert (eq kiln.compiler::*compiler-pipeline* :mir))
(with-open-file (progress {lisp(progress)} :direction :output :if-exists :supersede)
(dolist (entry '({pairs}))
  (format progress "~&LIBRARY-FILE-BEGIN ~A~%" (first entry))
  (force-output progress)
  (let ((start (get-internal-real-time)))
    (multiple-value-bind (output warnings failure)
        (compile-file (first entry) :output-file (second entry) :verbose nil :print nil)
      (declare (ignore warnings))
      (unless (and output (not failure)) (error "Library source compilation failed: ~A" (first entry)))
      (let ((compiled (get-internal-real-time)))
        (load output :verbose nil :print nil)
        (format progress "~&LIBRARY-FILE-SECONDS ~A ~F ~F~%" (first entry)
                (/ (- compiled start) internal-time-units-per-second)
                (/ (- (get-internal-real-time) compiled) internal-time-units-per-second))
        (force-output progress))))))
(eval (read-from-string {lisp(project['smoke_form'])})))'''
    result = kiln_run(args, form, output / 'kiln.log')
    text = progress.read_text(errors='replace') if progress.exists() else ''
    timings = re.findall(r'^LIBRARY-FILE-SECONDS (.+) ([0-9.]+) ([0-9.]+)$', text, re.M)
    result.update(mode='source-probe', source_plan=str(plan),
                  compiled_files=len(timings), smoke_completed=result['status'] == 'completed',
                  compile_seconds=sum(float(row[1]) for row in timings),
                  load_seconds=sum(float(row[2]) for row in timings),
                  source_sha256={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
                  fasl_bytes=sum(p.stat().st_size for p in fasls.glob('*.fasl')))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['fetch', 'sbcl', 'asdf', 'source'])
    parser.add_argument('projects', nargs='*')
    parser.add_argument('--corpus', type=Path, default=Path.home() / 'package/kiln-library-tests')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/library-tests')
    parser.add_argument('--kiln', type=Path, default=ROOT / 'build/boot/kiln1')
    parser.add_argument('--plan-directory', type=Path, help='host run directory containing PROJECT/sources.txt')
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--heap', default='FixedHeapSize:8589934592')
    parser.add_argument('--tests', action='store_true', help='invoke upstream ASDF test-op; inspect its test summary too')
    args = parser.parse_args()
    args.corpus, args.output, args.kiln = args.corpus.resolve(), args.output.resolve(), args.kiln.resolve()
    projects = json.loads(MANIFEST.read_text())['projects']
    names = args.projects or (['asdf'] if args.mode == 'asdf' else
                             [p['name'] for p in projects
                              if (p.get('source_probe') if args.mode == 'source'
                                  else args.mode == 'fetch' or 'system' in p)])
    by_name = {p['name']: p for p in projects}
    unknown = set(names) - by_name.keys()
    if unknown:
        parser.error(f'unknown projects: {sorted(unknown)}')
    if args.mode == 'source' and not args.plan_directory:
        parser.error('source requires --plan-directory from a matching SBCL run')
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(mode=args.mode, projects={}, manifest_sha256=hashlib.sha256(MANIFEST.read_bytes()).hexdigest())
    if args.mode in ('asdf', 'source'):
        report.update(kiln=str(args.kiln), kiln_sha256=hashlib.sha256(args.kiln.read_bytes()).hexdigest(), heap=args.heap)
    for name in names:
        project = by_name[name]
        output = args.output / name
        output.mkdir(exist_ok=True)
        try:
            if args.mode == 'fetch':
                path = args.corpus / name
                args.corpus.mkdir(parents=True, exist_ok=True)
                if not path.exists():
                    subprocess.run(['git', 'clone', '--no-checkout', '--depth', '1', project['url'], str(path)], check=True)
                    if revision(path) != project['revision']:
                        subprocess.run(['git', '-C', str(path), 'fetch', '--depth', '1', 'origin', project['revision']], check=True)
                    subprocess.run(['git', '-C', str(path), 'checkout', '--detach', project['revision']], check=True)
                checked_project(project, args.corpus)
                result = dict(status='ready')
            else:
                path = checked_project(project, args.corpus)
                if args.mode == 'sbcl':
                    if 'system' not in project:
                        raise ValueError(f'{name}: not an ASDF system')
                    script = output / 'host.lisp'
                    script.write_text(host_script(project, projects, args, output))
                    result = run(['sbcl', '--non-interactive', '--load', str(script)], output / 'sbcl.log', args.timeout)
                    result['upstream_test_op_requested'] = args.tests
                    log = (output / 'sbcl.log').read_text(errors='replace')
                    if result['status'] == 'completed' and 'LIBRARY-COMPLETE' not in log:
                        result['status'] = 'failed'
                    load_seconds = re.search(r'^LIBRARY-LOAD-SECONDS (\S+)', log, re.M)
                    result['load_completed'] = load_seconds is not None
                    result['load_seconds'] = float(load_seconds[1]) if load_seconds else None
                    result['test_op_completed'] = 'LIBRARY-TEST-OP-COMPLETED' in log
                    result['smoke_completed'] = 'LIBRARY-SMOKE-COMPLETED' in log
                    result['compile_seconds'] = sum(float(value) for value in re.findall(
                        r'^LIBRARY-COMPILE-SECONDS .+ ([0-9.]+)$',
                        log.split('LIBRARY-LOAD-SECONDS', 1)[0], re.M))
                    plan = output / 'sources.txt'
                    if plan.exists():
                        result['source_sha256'] = {
                            path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                            for path in plan.read_text().splitlines()}
                    result['fasl_bytes'] = sum(path.stat().st_size
                                              for path in (output / 'sbcl-cache').rglob('*.fasl'))
                    missing = re.search(r'Component (.+) not found', log)
                    if missing:
                        result['missing_dependency'] = missing[1]
                        result['status'] = 'blocked'
                elif args.mode == 'source':
                    result = source_probe(project, args, output)
                else:
                    if name != 'asdf':
                        raise ValueError('asdf mode probes the build-system bootstrap; select asdf')
                    subprocess.run(['sh', './make-asdf.sh'], cwd=path, check=True)
                    result = kiln_run(args, f'(load {lisp(path / "build/asdf.lisp")})', output / 'kiln.log')
                    if result['debugger_entered']:
                        result['status'] = 'blocked'
            result['revision'] = project['revision']
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            result = dict(status='error', message=str(error))
        report['projects'][name] = result
        print(f'{name}: {result["status"]}', flush=True)
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return int(any(p['status'] not in ('ready', 'completed') for p in report['projects'].values()))


if __name__ == '__main__':
    raise SystemExit(main())
