#!/usr/bin/env python3
"""Measure shared-base tests serially and compare retained space and warm latency."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', nargs='*', help='baseline selection, or all fast tests when no baseline is given')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--baseline', type=Path, help='previous summary.json with the same selection')
    parser.add_argument('--rebuild-base', action='store_true', help='measure cold base construction in the warmup')
    parser.add_argument('--max-regression', type=float, default=0.10)
    args = parser.parse_args()
    if args.runs < 1 or args.max_regression < 0:
        parser.error('runs must be positive and max-regression nonnegative')
    if args.baseline and not args.files:
        baseline = json.loads(args.baseline.read_text())
        args.files = baseline.get('test_order', baseline['tests'])
    args.output.mkdir(parents=True, exist_ok=True)
    reports = []
    # The first run establishes or rebuilds the cache. Keep its cold cost
    # separate; measured samples must reuse the same base.
    for index in range(args.runs + 1):
        report = args.output.resolve() / f'run-{index}.json'
        with (args.output / f'run-{index}.log').open('w') as log:
            subprocess.run([sys.executable, str(ROOT / 'tools/test-fasl.py'),
                            '--report', str(report),
                            *(['--rebuild-base'] if index == 0 and args.rebuild_base else []),
                            *args.files], cwd=ROOT,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        reports.append(json.loads(report.read_text()))
        print(f'{"warmup" if index == 0 else "sample"} {index}: {reports[-1]["seconds"]:.3f}s', flush=True)
    samples = reports[1:]
    if not samples[0]['tests'] or not all(r['base'].get('cache_hit') for r in samples):
        raise RuntimeError('samples must include shared-base tests and reuse an unchanged base')
    tests = sorted(samples[0]['tests'])
    if any(sorted(r['tests']) != tests or r['base']['key'] != samples[0]['base']['key']
           or r['source_sha256'] != samples[0]['source_sha256'] for r in samples):
        raise RuntimeError('test selection or base changed during measurement')
    metrics = dict(seconds=statistics.median(r['seconds'] for r in samples),
                   disk_bytes=max(r['budget_disk']['bytes'] for r in samples),
                   disk_allocated_bytes=max(r['budget_disk']['allocated_bytes'] for r in samples),
                   base_bytes=max(r['base_disk']['bytes'] for r in samples))
    result = dict(tests=tests, heap=samples[0]['heap'], runs=args.runs,
                  test_order=list(samples[0]['tests']),
                  source_sha256=samples[0]['source_sha256'],
                  base_key=samples[0]['base']['key'], warmup=reports[0], metrics=metrics,
                  test_medians={name: {phase: statistics.median(r['tests'][name][phase] for r in samples)
                                      for phase in samples[0]['tests'][name]} for name in tests})
    result['cold_metrics'] = ({field: reports[0]['base'][field]
                               for field in ('build_seconds', 'snapshot_seconds')}
                              if not reports[0]['base']['cache_hit'] else None)
    failed = False
    if args.baseline:
        baseline = json.loads(args.baseline.read_text())
        if baseline['tests'] != tests or baseline['heap'] != result['heap']:
            raise RuntimeError('baseline test selection and heap must match')
        if baseline.get('test_order', result['test_order']) != result['test_order']:
            raise RuntimeError('baseline test order must match')
        if baseline.get('source_sha256', result['source_sha256']) != result['source_sha256']:
            raise RuntimeError('baseline test sources changed; establish a new workload baseline')
        result['ratios'] = {key: value / baseline['metrics'][key] for key, value in metrics.items()}
        failed = any(ratio > 1 + args.max_regression for ratio in result['ratios'].values())
        if result['cold_metrics'] and baseline.get('cold_metrics'):
            result['cold_ratios'] = {key: value / baseline['cold_metrics'][key]
                                    for key, value in result['cold_metrics'].items()}
            failed |= any(ratio > 1 + args.max_regression for ratio in result['cold_ratios'].values())
        result['regression'] = failed
        print(json.dumps(result['ratios'], indent=2))
    (args.output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
