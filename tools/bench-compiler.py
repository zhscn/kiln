#!/usr/bin/env python3
"""Measure self-compilation from an existing bootstrap executable and manifest."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=root / 'build/boot/kiln1')
    parser.add_argument('--manifest', type=Path,
                        default=root / 'build/boot/stage0/modules.lisp-expr')
    parser.add_argument('--output', type=Path, default=root / 'build/bench-compiler')
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--warmup', type=int, default=1)
    args = parser.parse_args()
    if args.runs < 1 or args.warmup < 0:
        parser.error('runs must be positive and warmup nonnegative')
    exe, manifest, output = (p.resolve() for p in (args.exe, args.manifest, args.output))
    if not exe.is_file() or not manifest.is_file():
        parser.error('build the bootstrap executable and manifest first')
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, KILN_BUILD_TIMING='1')
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
                      phases=phases)
        if index >= args.warmup:
            records.append(record)
        print(f'{"warmup" if index < args.warmup else "sample"} {index}: {elapsed:.3f}s',
              flush=True)
    result = dict(executable=str(exe), executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
                  manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
                  heap=env['MMTK_GC_TRIGGER'], warmup=args.warmup, samples=records,
                  kir_sha256=expected, median_seconds=statistics.median(r['seconds'] for r in records),
                  median_peak_rss_kib=statistics.median(r['peak_rss_kib'] for r in records),
                  median_phases={name: {phase: statistics.median(r['phases'][name][phase]
                                                               for r in records)
                                        for phase in ('frontend', 'lower', 'emit')}
                                 for name in records[0]['phases']})
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k.startswith('median_')}, indent=2))


if __name__ == '__main__':
    main()
