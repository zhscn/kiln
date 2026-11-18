#!/usr/bin/env python3
"""Measure file and function edits in an initialized FSet or Maxima image."""
import argparse
import hashlib
import importlib.util
import inspect
import json
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import time

from lir_stats import lir_stats

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('library_tests', ROOT / 'tools/test-libraries.py')
libraries = importlib.util.module_from_spec(spec)
spec.loader.exec_module(libraries)
PHASES = ('first-file-compile', 'first-fasl-load', 'repeat-file-compile', 'repeat-fasl-load',
          'changed-file-compile', 'changed-fasl-load', 'same-function-eval', 'changed-function-eval')
PRESETS = {'fset': ('Code/reader.lisp', 'FSET::EXPAND-SET-CONSTRUCTOR-FORM'),
           'maxima': ('src/ellipt.lisp', 'BIGFLOAT::BF-JACOBI-AM')}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def disk_usage(path):
    seen = set()
    apparent = allocated = files = 0
    for file in path.rglob('*'):
        if file.is_symlink() or not file.is_file():
            continue
        stat = file.stat()
        identity = (stat.st_dev, stat.st_ino)
        if identity in seen:
            continue
        seen.add(identity)
        files += 1
        apparent += stat.st_size
        allocated += stat.st_blocks * 512
    return dict(files=files, bytes=apparent, allocated_bytes=allocated)


def run(command, log, env, timeout, cwd):
    start = time.perf_counter()
    with log.open('w') as output:
        process = subprocess.Popen(command, env=env, cwd=cwd, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
            status = 'completed' if code == 0 else 'failed'
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait()
            status = 'timeout'
    return dict(status=status, exit_code=code, seconds=time.perf_counter() - start)


def duration(value, unit):
    return float(value) * {'ns': 1e-9, 'µs': 1e-6, 'ms': 1e-3, 's': 1}[unit]


def parse_phases(text):
    phases = {}
    current = None
    for line in text.splitlines():
        if line.startswith('BENCH-BEGIN '):
            if current is not None:
                raise ValueError('benchmark intervals overlap')
            current = line.split()[1]
            if current in phases:
                raise ValueError(f'duplicate benchmark interval {current}')
            phases[current] = dict(backend_calls=0, backend_seconds=0.0, machine_seconds=0.0,
                                   compilation_phases={})
        elif line.startswith('BENCH-END '):
            _, name, wall, cpu, units = line.split()
            if name != current:
                raise ValueError('benchmark intervals overlap or are incomplete')
            phases[name].update(wall_seconds=int(wall) / int(units),
                                cpu_seconds=int(cpu) / int(units))
            current = None
        elif line.startswith('BENCH-METRIC '):
            _, name, phase, wall, cpu, own_wall, own_cpu, count, units = line.split()
            phases[name]['compilation_phases'][phase] = dict(
                wall_seconds=int(wall) / int(units), cpu_seconds=int(cpu) / int(units),
                self_wall_seconds=int(own_wall) / int(units),
                self_cpu_seconds=int(own_cpu) / int(units), count=int(count))
        elif current:
            machine = re.search(r'kiln-cg: machine code in ([\d.]+)(ns|µs|ms|s)', line)
            backend = re.search(r'kiln compiler: .+ in ([\d.]+)(ns|µs|ms|s)', line)
            if machine:
                phases[current]['machine_seconds'] += duration(*machine.groups())
            if backend:
                phases[current]['backend_calls'] += 1
                phases[current]['backend_seconds'] += duration(*backend.groups())
    if current or 'BENCH-COMPLETE' not in text or not phases:
        raise ValueError('benchmark did not finish every interval')
    return phases


def prepare(args, projects, source, base, key):
    image = base / 'library.img'
    stamp = base / 'image.key'
    if image.exists() and stamp.exists() and stamp.read_text() == key:
        return image, dict(cache_hit=True)
    stamp.unlink(missing_ok=True)
    image.unlink(missing_ok=True)
    env = dict(os.environ, KILN_SERVE='1', MMTK_GC_TRIGGER=args.heap)
    for name in ('KILN_IMAGE', 'KILN_SAVE_IMAGE', 'KILN_MAXIMA_TEST',
                 'KILN_MAXIMA_SHARE', 'KILN_PROFILE', 'KILN_TIME'):
        env.pop(name, None)
    if args.project == 'fset':
        cache = base / 'fasl-cache'
        setup = libraries.asdf_bootstrap(args) + '\n' + f'''(eval (read-from-string
          {libraries.lisp('(progn ' + libraries.registry(projects, args.corpus, target=True) + chr(10) +
              '(asdf:initialize-output-translations ' +
              "'(:output-translations (t (" + libraries.lisp(str(cache) + '/') +
              ' :implementation)) :ignore-inherited-configuration))' + chr(10) +
              '(asdf:load-system "fset"))')}))'''
    else:
        build = args.maxima_build_directory or base / 'maxima'
        if args.maxima_build_directory:
            expected = dict(compiler_sha256=digest(args.kiln), revision=next(
                p['revision'] for p in projects if p['name'] == 'maxima'),
                configuration_sha256=digest(source / 'src/autoconf-variables.lisp'),
                patches={name: digest(ROOT / name) for p in projects if p['name'] == 'maxima'
                         for name in p.get('patches', [])})
            reports = [build / 'report.json', *(build / 'runs').glob('*/report.json')]
            compatible = False
            for path in reports:
                if path.is_file():
                    record = json.loads(path.read_text())
                    if record.get('build_completed') and all(record.get(k) == v for k, v in expected.items()):
                        compatible = True
                        break
            if not compatible:
                raise ValueError('Maxima cache has no completed build for this executable, configuration and patches')
        build.mkdir(parents=True, exist_ok=True)
        configuration = source / 'src/autoconf-variables.lisp'
        if not configuration.is_file():
            raise ValueError('configure Maxima before preparing its benchmark image')
        destination = build / 'autoconf-variables.lisp'
        if not destination.exists() or destination.read_bytes() != configuration.read_bytes():
            shutil.copyfile(configuration, destination)
        env.update(KILN_MAXIMA_SOURCE=str(source) + '/', KILN_MAXIMA_BUILD=str(build) + '/',
                   KILN_MAXIMA_BUILD_ONLY='1', MAXIMA_PREFIX=str(source),
                   MAXIMA_LAYOUT_AUTOTOOLS='false', MAXIMA_USERDIR=str(base / 'user'),
                   MAXIMA_OBJDIR=str(base / 'objects'))
        setup = f'(load {libraries.lisp(ROOT / "tools/test-maxima.lisp")})'
    script = base / 'prepare.lisp'
    script.write_text(f'''{setup}
(load {libraries.lisp(ROOT / 'tools/bench-library.lisp')})
(kiln.sys:save-image {libraries.lisp(image)}
 :toplevel (symbol-function (find-symbol "RUN" "KILN.BENCH")))
''')
    result = libraries.run([str(args.kiln)], base / 'prepare.log', args.timeout, env=env,
                           input=libraries.kiln_request(f'(load {libraries.lisp(script)})'), cwd=base)
    if result['status'] != 'completed' or not image.exists() or '(:ok 1 ' not in (
            base / 'prepare.log').read_text(errors='replace'):
        raise RuntimeError(f'benchmark image preparation failed: {base / "prepare.log"}')
    stamp.write_text(key)
    result['cache_hit'] = False
    return image, result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', choices=PRESETS)
    parser.add_argument('--kiln', type=Path, default=ROOT / 'build/boot/kiln1')
    parser.add_argument('--corpus', type=Path, default=Path.home() / 'package/kiln-library-tests')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/bench-library')
    parser.add_argument('--asdf-directory', type=Path, default=ROOT / 'vendor/ASDF')
    parser.add_argument('--maxima-build-directory', type=Path,
                        help='reuse an existing compiler-specific Maxima build directory')
    parser.add_argument('--file', help='source path relative to the selected project')
    parser.add_argument('--definition', help='DEFUN name to recompile in the initialized image')
    parser.add_argument('--prepare-only', action='store_true', help='build the initialized image without timing edits')
    parser.add_argument('--profile', choices=('cpu', 'alloc'), help='collect samples in a separate measurement run')
    parser.add_argument('--profile-phase', choices=PHASES, default='first-file-compile', help='one interval to profile')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--warmup', type=int, default=1)
    parser.add_argument('--timeout', type=float, default=3600)
    parser.add_argument('--heap', default='FixedHeapSize:8589934592')
    args = parser.parse_args()
    if args.runs < 1 or args.warmup < 0:
        parser.error('runs must be positive and warmup nonnegative')
    for field in ('kiln', 'corpus', 'output', 'asdf_directory', 'maxima_build_directory'):
        if getattr(args, field) is not None:
            setattr(args, field, getattr(args, field).resolve())
    projects = json.loads(libraries.MANIFEST.read_text())['projects']
    for project in projects:
        if (args.corpus / project['name']).exists():
            libraries.checked_project(project, args.corpus)
    project = next(p for p in projects if p['name'] == args.project)
    source = libraries.checked_project(project, args.corpus)
    selected = (source / (args.file or PRESETS[args.project][0])).resolve()
    if not selected.is_relative_to(source) or not selected.is_file():
        parser.error('selected source must be a file inside the project')
    definition = args.definition or PRESETS[args.project][1]
    hashes = {str(p.relative_to(ROOT)): digest(p) for p in (
        libraries.MANIFEST, Path(__file__), ROOT / 'tools/bench-library.lisp',
        ROOT / 'tools/test-libraries.py', ROOT / 'tools/test-maxima.lisp')}
    hashes.update({name: digest(ROOT / name) for p in projects for name in p.get('patches', [])})
    corpus_hashes = {}
    for item in projects:
        directory = args.corpus / item['name']
        if directory.exists():
            state = hashlib.sha256()
            if 'archive_url' in item:
                paths = [directory / name for name in item['source_sha256']]
            else:
                names = subprocess.check_output(
                    ['git', '-C', str(directory), 'ls-files', '--cached', '-z', '--',
                     '*.lisp', '*.lsp', '*.asd'])
                paths = [directory / os.fsdecode(name) for name in names.split(b'\0') if name]
                for patch in item.get('patches', []):
                    for name in re.findall(r'^\+\+\+ b/(.+)$', (ROOT / patch).read_text(), re.M):
                        candidate = directory / name
                        if candidate.suffix in ('.lisp', '.lsp', '.asd'):
                            paths.append(candidate)
            for path in sorted(set(paths)):
                state.update(str(path.relative_to(directory)).encode())
                state.update(bytes.fromhex(digest(path)))
            corpus_hashes[item['name']] = state.hexdigest()
    configuration = source / 'src/autoconf-variables.lisp'
    preparation_code = hashlib.sha256('\n'.join(inspect.getsource(function) for function in
        (prepare, libraries.asdf_bootstrap, libraries.registry, libraries.lisp)).encode()).hexdigest()
    identity = dict(compiler_sha256=digest(args.kiln), heap=args.heap,
                    setup_sha256=preparation_code, manifest_sha256=digest(libraries.MANIFEST),
                    driver_sha256={name: digest(ROOT / name) for name in
                                   ('tools/bench-library.lisp', 'tools/test-maxima.lisp')},
                    corpus_sha256=corpus_hashes,
                    build_cache=str(args.maxima_build_directory) if args.maxima_build_directory else None,
                    configuration_sha256=digest(configuration) if configuration.exists() else None)
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    base = args.output / args.project / key
    base.mkdir(parents=True, exist_ok=True)
    image, preparation = prepare(args, projects, source, base, key)
    if args.prepare_only:
        print(image)
        return
    experiment = base / (f'{args.profile}-{args.profile_phase}' if args.profile else 'timing')
    experiment.mkdir(exist_ok=True)
    samples = []
    for index in range(args.warmup + args.runs):
        sample = experiment / f'run-{index}'
        sample.mkdir(exist_ok=True)
        packet_directory = sample / 'packets'
        packet_directory.mkdir(exist_ok=True)
        for old in packet_directory.glob('*.lir'):
            old.unlink()
        scratch = sample / selected.name
        shutil.copyfile(selected, scratch)
        env = dict(os.environ, KILN_IMAGE=str(image), KILN_TIME='1', MMTK_GC_TRIGGER=args.heap,
                   KILN_BENCH_SOURCE=str(scratch), KILN_BENCH_FASL=str(sample / 'selected.fasl'),
                   KILN_BENCH_PACKETS=str(packet_directory) + '/', KILN_BENCH_DEFINITION=definition)
        for name in ('KILN_SERVE', 'KILN_SAVE_IMAGE', 'KILN_PROFILE'):
            env.pop(name, None)
        if args.profile:
            env.update(KILN_BENCH_PROFILE=args.profile, KILN_BENCH_PROFILE_PHASE=args.profile_phase,
                       KILN_BENCH_PROFILE_OUT=str(sample / 'profile.folded'))
        else:
            for name in ('KILN_BENCH_PROFILE', 'KILN_BENCH_PROFILE_PHASE', 'KILN_BENCH_PROFILE_OUT'):
                env.pop(name, None)
        log = sample / 'benchmark.log' 
        record = run(['/usr/bin/time', '-f', '%M', '-o', str(sample / 'rss.txt'), str(args.kiln)],
                     log, env, args.timeout, sample)
        if record['status'] != 'completed':
            raise RuntimeError(f'{record["status"]}: {log}')
        record['phases'] = parse_phases(log.read_text(errors='replace'))
        if set(record['phases']) != set(PHASES):
            raise RuntimeError(f'benchmark scenario list is incomplete: {log}')
        if not record['phases']['first-file-compile']['compilation_phases']:
            raise RuntimeError('compiler lacks phase metrics; rebuild it from current sources')
        record['peak_rss_kib'] = int((sample / 'rss.txt').read_text())
        record['lir'] = {}
        for label in ('first', 'repeat', 'changed'):
            packets = list(packet_directory.glob(f'{label}-*.lir'))
            if not packets:
                raise RuntimeError(f'no LIR packets retained for {label}: {log}')
            stats = [lir_stats(p) for p in packets]
            record['lir'][label] = dict(packets=len(packets), bytes=sum(p.stat().st_size for p in packets),
                                      metrics={k: sum(s[k] for s in stats) for k in stats[0]})
        record['disk'] = disk_usage(sample)
        if index >= args.warmup:
            samples.append(record)
        print(f'{args.project} sample {index}: {record["seconds"]:.3f}s', flush=True)
    report = dict(identity=identity, tool_sha256=hashes, project=args.project, revision=project['revision'],
                  source=str(selected), source_sha256=digest(selected), definition=definition,
                  profile=args.profile, profile_phase=args.profile_phase if args.profile else None,
                  preparation=preparation, warmup=args.warmup, samples=samples, disk=disk_usage(base),
                  median_seconds=statistics.median(r['seconds'] for r in samples),
                  median_peak_rss_kib=statistics.median(r['peak_rss_kib'] for r in samples),
                  median_phases={phase: {field: statistics.median(r['phases'][phase][field] for r in samples)
                                        for field in ('wall_seconds', 'cpu_seconds', 'backend_seconds',
                                                      'machine_seconds', 'backend_calls')}
                                 for phase in samples[0]['phases']})
    for phase, summary in report['median_phases'].items():
        names = set().union(*(r['phases'][phase]['compilation_phases'] for r in samples))
        summary['compilation_phases'] = {
            name: {field: statistics.median(
                r['phases'][phase]['compilation_phases'].get(name, {}).get(field, 0)
                for r in samples)
                   for field in ('wall_seconds', 'cpu_seconds', 'self_wall_seconds',
                                 'self_cpu_seconds', 'count')}
            for name in sorted(names)}
    (experiment / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(experiment / 'report.json')


if __name__ == '__main__':
    main()
