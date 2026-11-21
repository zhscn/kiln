#!/usr/bin/env python3
"""Export Kiln's compilation stages and per-pass MIR diffs."""
import argparse
import difflib
import json
from pathlib import Path
import re
import shutil
import subprocess

from lir_stats import lir_stats


ROOT = Path(__file__).resolve().parent.parent
COUNTS = ("functions", "blocks", "instructions", "values", "calls")


def capture(args, path):
    with path.open("w") as output:
        subprocess.run(args, stdout=output, check=True)


def focus_backend(out, labels):
    lir = (out / "program.lir.txt").read_text().splitlines(keepends=True)
    with (out / "selected.lir.txt").open("w") as selected:
        for line in lir:
            function = re.match(r'  \(function "([^"]+)" ', line)
            if function and function[1] in labels:
                selected.write(line)
    clif = (out / "program.clif").read_text()
    with (out / "selected.clif").open("w") as selected:
        for match in re.finditer(r"^; (\S+)\n.*?(?=^; \S+\n|\Z)", clif, re.M | re.S):
            if match[1] in labels:
                selected.write(match[0])
    with (out / "selected.asm").open("w") as selected:
        for label in sorted(labels):
            subprocess.run(["objdump", "-dr", f"--disassemble={label}", out / "program.o"],
                           stdout=selected, check=True)


def report(out, function):
    stages = []
    previous = {}
    for line in (out / "stages.tsv").read_text().splitlines():
        unit, stage, file, elapsed, *counts = line.split("\t")
        metrics = dict(zip(COUNTS, map(int, counts), strict=True))
        snapshot = (out / file).read_text().splitlines(keepends=True)
        prior = previous.get(unit)
        diff_file = None
        delta = None
        if prior:
            old_file, old_snapshot, old_metrics = prior
            diff_file = file + ".diff"
            (out / diff_file).write_text("".join(difflib.unified_diff(
                old_snapshot, snapshot, fromfile=old_file, tofile=file)))
            delta = {key: metrics[key] - old_metrics[key] for key in COUNTS}
        previous[unit] = file, snapshot, metrics
        stages.append(dict(unit=int(unit), stage=stage, snapshot=file, diff=diff_file,
                           elapsed_us=None if elapsed == "-" else int(elapsed),
                           counts=metrics, delta=delta))
    stats = lir_stats(out / "program.lir")
    (out / "report.json").write_text(json.dumps({"mir": stages, "lir": stats}, indent=2) + "\n")
    with (out / "report.md").open("w") as stream:
        stream.write(
            "# Kiln IR report\n\n"
            "[Source](source.lisp) · [Macro expansion events](expansions.txt) · "
            "[Normalized LIR](program.lir.txt) · [CLIF before machine compilation](program.clif) · "
            "[Assembly](program.asm) · [Function labels](labels.txt) · [JSON](report.json)\n\n"
            "MIR timings exclude snapshot writing. A zero count delta can still have a textual diff.\n\n")
        if function:
            stream.write("Selected function · [LIR](selected.lir.txt) · "
                         "[CLIF](selected.clif) · [Assembly](selected.asm)\n\n")
        stream.write(
            "| Unit | Pass | µs | Functions | Blocks | Instructions | Values | Calls | Diff |\n"
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n")
        for row in stages:
            cells = [f"[{row['unit']}](u{row['unit']}.hir)",
                     f"[{row['stage']}]({row['snapshot']})",
                     str(row["elapsed_us"]) if row["elapsed_us"] is not None else "—"]
            for key in COUNTS:
                count = str(row["counts"][key])
                if row["delta"] and row["delta"][key]:
                    count += f" ({row['delta'][key]:+d})"
                cells.append(count)
            cells.append(f"[view]({row['diff']})" if row["diff"] else "—")
            stream.write("| " + " | ".join(cells) + " |\n")
        stream.write("\n## LIR totals\n\n")
        for key, value in stats.items():
            stream.write(f"- {key}: {value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, required=True, help="new report directory")
    parser.add_argument("--function", default="", help="select a MIR function by name")
    parser.add_argument("--with-kernel", action="store_true",
                        help="prepare the kernel's compiler environment before tracing")
    parser.add_argument("--prelude", type=Path, action="append", default=[],
                        help="compile a supporting source file before tracing (repeatable)")
    parser.add_argument("--backend", type=Path, default=ROOT / "target/debug/kiln-cg")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("--output must name a new directory")
    source = args.source.resolve(strict=True)
    backend = args.backend.resolve(strict=True)
    preludes = [path.resolve(strict=True) for path in args.prelude]
    out = args.output.resolve()
    out.mkdir(parents=True)
    shutil.copyfile(source, out / "source.lisp")
    compiler_log = out / "compiler.log"
    with compiler_log.open("w") as log:
        result = subprocess.run(
            ["sbcl", "--noinform", "--non-interactive", "--load", ROOT / "tools/ir-explorer.lisp",
             "--end-toplevel-options", source, out, args.function,
             "yes" if args.with_kernel else "no", *preludes],
            stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        parser.exit(1, f"Kiln compilation failed. See {compiler_log}\n")
    lir = out / "program.lir"
    capture([backend, "dump", lir], out / "program.lir.txt")
    obj = out / "program.o"
    with (out / "program.clif").open("w") as clif:
        subprocess.run([backend, "obj", lir, "-o", obj, "--dump-clif"],
                       stderr=clif, check=True)
    capture(["objdump", "-dr", obj], out / "program.asm")
    if args.function:
        focus_backend(out, set((out / "labels.txt").read_text().splitlines()))
    report(out, args.function)
    print(out / "report.md")


if __name__ == "__main__":
    main()
