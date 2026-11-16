#!/usr/bin/env python3
"""Run isolated compile-file/load tests using one initialized base snapshot."""

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'build/test-fasl'
METRICS = {'base': {}, 'tests': {}}


def disk_usage(directory, paths=None):
    """Count retained regular files once, including sparse-file allocation."""
    apparent = allocated = files = 0
    seen = set()
    for path in directory.rglob('*') if paths is None else paths:
        if path.is_symlink() or not path.is_file():
            continue
        stat = path.stat()
        identity = (stat.st_dev, stat.st_ino)
        if identity in seen:
            continue
        seen.add(identity)
        apparent += stat.st_size
        allocated += stat.st_blocks * 512
        files += 1
    return dict(bytes=apparent, allocated_bytes=allocated, files=files)


def lisp_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def base_image(rebuild=False):
    start = time.perf_counter()
    base = BUILD / 'base'
    base.mkdir(parents=True, exist_ok=True)
    executable = base / 'kiln0'
    image = base / 'base.img'
    stamp = base / 'base.key'
    digest = hashlib.sha256()
    # Hash contents, not mtimes: branch switches and restored sources must
    # invalidate both the executable and its address-dependent snapshot.
    paths = [ROOT / name for name in ('Cargo.toml', 'Cargo.lock', 'deps.lock', 'kiln.asd',
                                     'tools/env.lisp', 'tools/stage0-kiln.sh', 'tools/test-base.lisp')]
    for directory in ('lisp', 'vendor', 'rust', 'protocol'):
        paths.extend(p for p in (ROOT / directory).rglob('*')
                     if p.is_file() and p.suffix in ('.lisp', '.rs', '.toml', '.def', '.sh', '.py'))
    for path in sorted(paths):
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(b'\0')
        digest.update(path.read_bytes())
    key = digest.hexdigest()
    METRICS['base']['key_seconds'] = time.perf_counter() - start
    METRICS['base']['key'] = key
    if not rebuild and executable.exists() and image.exists() and stamp.exists() and stamp.read_text() == key:
        METRICS['base']['cache_hit'] = True
        return executable, image
    METRICS['base']['cache_hit'] = False
    stamp.unlink(missing_ok=True)
    image.unlink(missing_ok=True)
    print('Building shared test base', flush=True)
    with (base / 'build.log').open('w') as log:
        start = time.perf_counter()
        subprocess.run([str(ROOT / 'tools/stage0-kiln.sh'), str(base)], cwd=ROOT,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    METRICS['base']['build_seconds'] = time.perf_counter() - start
    form = f'(load {lisp_string(ROOT / "tools/test-base.lisp")})'
    request = f'(:eval 1 {lisp_string(form)})\n'
    environment = dict(os.environ, KILN_SERVE='1', KILN_TEST_BASE=str(image))
    environment.pop('KILN_IMAGE', None)
    environment.pop('KILN_SAVE_IMAGE', None)
    with (base / 'snapshot.log').open('w') as log:
        start = time.perf_counter()
        subprocess.run([str(executable)], input=request, text=True, cwd=ROOT,
                       env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    METRICS['base']['snapshot_seconds'] = time.perf_counter() - start
    if not image.exists():
        raise RuntimeError(f'base snapshot was not written; see {base / "snapshot.log"}')
    # The packets are reproducible build intermediates, not cache entries.
    for path in (base / 'stage0').glob('*.lir'):
        path.unlink()
    stamp.write_text(key)
    return executable, image


def main():
    start = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', type=Path, nargs='*', help='test source files; default: all fast tests')
    parser.add_argument('--report', type=Path, help='write phase timings and retained disk usage as JSON')
    parser.add_argument('--rebuild-base', action='store_true', help='rebuild even if the base cache matches')
    args = parser.parse_args()
    explicit = bool(args.files)
    sources = ([path.resolve(strict=True) for path in args.files] if explicit
               else sorted((ROOT / 'tests').glob('*/*.lisp')))
    cross, files = [], []
    for source in sources:
        if source.with_suffix('.slow').exists() and not explicit:
            continue
        if (not source.stem.startswith(('clos-', 'fe-', 'ev-', 'co-'))
                or any(source.with_suffix(suffix).exists()
                       for suffix in ('.same-kir', '.image', '.slow', '.cross'))):
            cross.append(source)
        else:
            files.append(source)
    names = [source.stem for source in files]
    if len(set(names)) != len(names):
        raise ValueError('test names must be distinct')
    METRICS['source_sha256'] = {os.path.relpath(source, ROOT): hashlib.sha256(source.read_bytes()).hexdigest()
                               for source in sources}
    BUILD.mkdir(parents=True, exist_ok=True)
    # Existing file and stream tests create fixtures in this directory.
    (ROOT / 'build/test').mkdir(parents=True, exist_ok=True)
    failed = False
    if files:
        executable, image = base_image(args.rebuild_base)
        environment = dict(os.environ, KILN_IMAGE=str(image))
        environment.pop('KILN_SERVE', None)
        environment.pop('KILN_SAVE_IMAGE', None)
        for source in files:
            name = source.stem
            packet = BUILD / f'{name}.fasl'
            packet.unlink(missing_ok=True)
            env = dict(environment, KILN_TEST_SOURCE=str(source), KILN_TEST_FASL=str(packet),
                       KILN_TEST_EVAL='hir' if name.startswith('ev-') else 'native')
            log = BUILD / f'{name}.compile.out'
            metrics = METRICS['tests'][os.path.relpath(source, ROOT)] = {}
            phase_start = time.perf_counter()
            with log.open('wb') as stream:
                result = subprocess.run([str(executable)], cwd=ROOT,
                                        env=dict(env, KILN_TEST_PHASE='compile'),
                                        stdout=stream, stderr=subprocess.STDOUT)
            metrics['compile_seconds'] = time.perf_counter() - phase_start
            if result.returncode or not packet.exists():
                print(f'FAIL compile-file {name}\n{log.read_text(errors="replace")}', flush=True)
                failed = True
                continue
            expected = source.with_suffix('.expected').read_bytes()
            for mode in ('load', 'stress'):
                run_env = dict(env, KILN_TEST_PHASE='load')
                if mode == 'stress':
                    run_env['MMTK_GC_TRIGGER'] = 'FixedHeapSize:67108864'
                output = BUILD / f'{name}.{mode}.out'
                phase_start = time.perf_counter()
                with output.open('wb') as stream:
                    result = subprocess.run([str(executable)], cwd=ROOT, env=run_env,
                                            stdout=stream, stderr=subprocess.STDOUT)
                metrics[f'{mode}_seconds'] = time.perf_counter() - phase_start
                actual = output.read_bytes()
                ok = result.returncode == 0 and actual == expected
                print(f'{"PASS" if ok else "FAIL"} {mode} {name}', flush=True)
                if not ok:
                    failed = True
                    print(''.join(difflib.unified_diff(
                        expected.decode(errors='replace').splitlines(True),
                        actual.decode(errors='replace').splitlines(True),
                        fromfile=str(source.with_suffix('.expected')), tofile=str(output))), flush=True)
    if cross:
        phase_start = time.perf_counter()
        result = subprocess.run([str(ROOT / 'tools/test-cross.sh'), *map(str, cross)], cwd=ROOT)
        failed |= result.returncode != 0
        METRICS['cross_seconds'] = time.perf_counter() - phase_start
    if args.report:
        budget_paths = list((BUILD / 'base').rglob('*'))
        for source in files:
            for path in [*BUILD.glob(source.stem + '.*'), BUILD / source.stem]:
                budget_paths.append(path)
                if path.is_dir() and not path.is_symlink():
                    budget_paths.extend(path.rglob('*'))
        METRICS.update(seconds=time.perf_counter() - start, success=not failed,
                       disk=disk_usage(BUILD), base_disk=disk_usage(BUILD / 'base'),
                       budget_disk=disk_usage(BUILD, budget_paths),
                       heap=os.environ.get('MMTK_GC_TRIGGER', 'default'))
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(METRICS, indent=2) + '\n')
    return int(failed)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'ERROR: {error}\nBase build logs: {BUILD / "base"}', file=sys.stderr)
        sys.exit(1)
