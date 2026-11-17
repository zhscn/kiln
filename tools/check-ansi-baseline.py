#!/usr/bin/env python3
"""Compare named ANSI failures and disabled-note skips for explicit test groups."""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def check(directory, groups, baseline):
    failures = set()
    skipped = {}
    totals = [0, 0, 0]
    for group in groups:
        text = (directory / f'{group}.log').read_text(errors='replace')
        results = re.findall(r'^ANSI-RESULT (\d+) (\d+) (\d+)$', text, re.M)
        if len(results) != 1:
            raise ValueError(f'{group}: missing or duplicate ANSI result')
        mode = re.findall(r'^ANSI-DETAILS (\S+)$', text, re.M)
        if mode != [baseline['configuration']['evaluation']]:
            raise ValueError(f'{group}: use ANSI_REPORT_NAMES=1 with the baseline evaluation mode')
        names = re.findall(r'^ANSI-FAILURE-NAME (.+)$', text, re.M)
        failures.update((group, name) for name in names)
        for line in re.findall(r'^ANSI-SKIP-NAME (.+)$', text, re.M):
            name, note = line.rsplit(' ', 1)
            skipped.setdefault((group, name), set()).add(note)
        counts = list(map(int, results[0]))
        if counts[1] != len(set(names)) or counts[2] != sum(key[0] == group for key in skipped):
            raise ValueError(f'{group}: named outcomes disagree with totals')
        totals = [a + b for a, b in zip(totals, counts)]
    expected_failures = {(item['group'], item['test']) for item in baseline['known_failures'] if item['group'] in groups}
    expected_skips = {(item['group'], item['test']): set(item['disabled_notes'])
                      for item in baseline['skipped'] if item['group'] in groups}
    changes = dict(new_failures=sorted(failures - expected_failures),
                   resolved_failures=sorted(expected_failures - failures),
                   new_skips=sorted(skipped.keys() - expected_skips.keys()),
                   missing_skips=sorted(expected_skips.keys() - skipped.keys()),
                   changed_skip_reasons=sorted(key for key in skipped.keys() & expected_skips.keys()
                                               if skipped[key] != expected_skips[key]))
    return dict(groups=groups, passed=totals[0], failed=totals[1], skipped=totals[2],
                matches=not any(changes.values()), **changes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('groups', nargs='+', help='every requested group must have a completed log')
    parser.add_argument('--baseline', type=Path, default=ROOT / 'tests/ansi-baseline.json')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        result = check(args.directory, list(dict.fromkeys(args.groups)), json.loads(args.baseline.read_text()))
    except (ValueError, OSError) as error:
        parser.exit(2, f'{error}\n')
    output = json.dumps(result, indent=2) + '\n'
    print(output, end='')
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output)
    return int(not result['matches'])


if __name__ == '__main__':
    raise SystemExit(main())
