#!/usr/bin/env python3
"""Measure self-compilation from an existing bootstrap executable and manifest."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import statistics
import subprocess
import time


def measure_backend(backend, packets, output, env):
    """Time isolated object compilation; machine_seconds excludes LIR lowering."""
    results = {}
    for packet in packets:
        log = output / f'{packet.stem}.codegen.log'
        obj = output / f'{packet.stem}.o'
        start = time.perf_counter()
        with log.open('w') as stream:
            subprocess.run([str(backend), 'obj', str(packet), '-o', str(obj)],
                           env=dict(env, KILN_TIME='1'), stdout=stream,
                           stderr=subprocess.STDOUT, check=True)
        elapsed = time.perf_counter() - start
        match = re.search(r'machine code in ([\d.]+)(ns|µs|ms|s)', log.read_text())
        if not match:
            raise RuntimeError(f'missing Cranelift timing in {log}')
        results[packet.stem] = dict(seconds=elapsed,
            machine_seconds=float(match[1]) * {'ns': 1e-9, 'µs': 1e-6, 'ms': 1e-3, 's': 1}[match[2]],
            object_bytes=obj.stat().st_size)
        obj.unlink()
    return results


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=root / 'build/boot/kiln1')
    parser.add_argument('--manifest', type=Path,
                        default=root / 'build/boot/stage0/modules.lisp-expr')
    parser.add_argument('--output', type=Path, default=root / 'build/bench-compiler')
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--warmup', type=int, default=1)
    parser.add_argument('--backend', type=Path,
                        help='also measure each LIR module with this kiln-cg executable')
    parser.add_argument('--lir-directory', type=Path,
                        help='measure existing LIR files only; requires --backend')
    parser.add_argument('--pipeline', choices=('hir', 'mir'),
                        default=os.environ.get('KILN_BUILD_PIPELINE', 'mir'))
    args = parser.parse_args()
    if args.runs < 1 or args.warmup < 0:
        parser.error('runs must be positive and warmup nonnegative')
    if args.pipeline not in ('hir', 'mir'):
        parser.error('KILN_BUILD_PIPELINE must be hir or mir')
    if args.lir_directory:
        if not args.backend:
            parser.error('--lir-directory requires --backend')
        packets = sorted(args.lir_directory.resolve().glob('*.lir'))
        if not packets:
            parser.error('no LIR files in --lir-directory')
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=True)
        records = []
        for index in range(args.warmup + args.runs):
            run = output / f'run-{index}'
            run.mkdir(exist_ok=True)
            record = measure_backend(args.backend.resolve(), packets, run, os.environ)
            if index >= args.warmup:
                records.append(record)
            print(f'backend sample {index}', flush=True)
        result = dict(backend_sha256=hashlib.sha256(args.backend.read_bytes()).hexdigest(),
                      lir_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in packets},
                      lir_bytes={p.stem: p.stat().st_size for p in packets},
                      warmup=args.warmup, samples=records,
                      median_backend={p.stem: {
                          field: statistics.median(r[p.stem][field] for r in records)
                          for field in ('seconds', 'machine_seconds', 'object_bytes')}
                          for p in packets})
        (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
        return
    exe, manifest, output = (p.resolve() for p in (args.exe, args.manifest, args.output))
    if not exe.is_file() or not manifest.is_file():
        parser.error('build the bootstrap executable and manifest first')
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, KILN_BUILD_TIMING='1', KILN_BUILD_PIPELINE=args.pipeline)
    for key in ('KILN_SERVE', 'KILN_SAVE_IMAGE', 'KILN_IMAGE'):
        env.pop(key, None)
    env.setdefault('MMTK_GC_TRIGGER', 'FixedHeapSize:8589934592')
    records = []
    expected = None
    for index in range(args.warmup + args.runs):
        run = output / f'run-{index}'
        run.mkdir(exist_ok=True)
        for old in [*run.glob('*.kir'), *run.glob('*.lir')]:
            old.unlink()
        shutil.copyfile(manifest, run / 'modules.lisp-expr')
        start = time.perf_counter()
        with (run / 'build.log').open('w') as log:
            subprocess.run(['/usr/bin/time', '-f', '%M', '-o', str(run / 'rss.txt'),
                            str(exe)], cwd=run, env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True)
        elapsed = time.perf_counter() - start
        phases = {}
        for line in (run / 'build.log').read_text().splitlines():
            if line.startswith('build-timing '):
                _, name, front, lower, emit, units = line.split()
                phases[name] = dict(zip(('frontend', 'lower', 'emit'),
                                       (int(v) / int(units) for v in (front, lower, emit))))
        if not phases:
            raise RuntimeError('executable lacks build timing; rebuild it from current sources')
        hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in sorted([*run.glob('*.kir'), *run.glob('*.lir')])}
        if not hashes or {p[:-4] for p in hashes} != set(phases):
            raise RuntimeError('Backend outputs and timed modules differ')
        if expected is not None and hashes != expected:
            raise RuntimeError('Backend output changed between runs')
        expected = hashes
        record = dict(seconds=elapsed, peak_rss_kib=int((run / 'rss.txt').read_text()),
                      phases=phases,
                      lir_bytes={p.stem: p.stat().st_size for p in run.glob('*.lir')})
        if args.backend:
            record['backend'] = measure_backend(args.backend.resolve(), sorted(run.glob('*.lir')), run, env)
        if index >= args.warmup:
            records.append(record)
        print(f'{"warmup" if index < args.warmup else "sample"} {index}: {elapsed:.3f}s',
              flush=True)
    result = dict(pipeline=args.pipeline, executable=str(exe), executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
                  manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
                  heap=env['MMTK_GC_TRIGGER'], warmup=args.warmup, samples=records,
                  kir_sha256=expected, median_seconds=statistics.median(r['seconds'] for r in records),
                  median_peak_rss_kib=statistics.median(r['peak_rss_kib'] for r in records),
                  median_phases={name: {phase: statistics.median(r['phases'][name][phase]
                                                               for r in records)
                                        for phase in ('frontend', 'lower', 'emit')}
                                 for name in records[0]['phases']})
    result['lir_bytes'] = records[0]['lir_bytes']
    if args.backend:
        result['backend_sha256'] = hashlib.sha256(args.backend.read_bytes()).hexdigest()
        result['median_backend'] = {
            name: {field: statistics.median(r['backend'][name][field] for r in records)
                   for field in ('seconds', 'machine_seconds', 'object_bytes')}
            for name in records[0]['backend']}
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k.startswith('median_')}, indent=2))


if __name__ == '__main__':
    main()
