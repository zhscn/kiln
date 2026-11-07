#!/usr/bin/env bash
# Runs cl-bench (bench/cl-bench, bench/README.md) on kiln (an AOT
# executable that SBCL compiles, with the five modules: CLOS benchmarks
# call COMPILE) and on SBCL (sbcl --script, default optimization), and
# prints a table: name, group, milliseconds per run on kiln and on SBCL,
# and their ratio.
#
#   tools/bench.sh [--no-build] [--kiln-only | --sbcl-only] [NAME|GROUP ...]
#
# NAME and GROUP select benchmarks (default: all); groups are gabriel,
# math, bignum, hash, gc, sequence, clos, misc. BENCH_BUDGET (seconds,
# default 2) bounds the time of each benchmark's runs; on kiln each
# benchmark runs in a process of its own, ended after BENCH_TIMEOUT
# seconds (default 120: TIMEOUT in the table), and a crash does not stop
# the others (CRASH). --no-build runs the executable built last.
# Results: build/bench/kiln.txt, sbcl.txt, table.txt.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=$root/build/bench
mkdir -p "$build"
cd "$root"

build_exe=1 run_kiln=1 run_sbcl=1
while [ $# -gt 0 ]; do
  case $1 in
    --no-build) build_exe=0 ;;
    --kiln-only) run_sbcl=0 ;;
    --sbcl-only) run_kiln=0 ;;
    *) break ;;
  esac
  shift
done
export BENCH_SELECT="$*"

# The program: the harness around cl-bench's files, in its ASDF order.
src=$build/co-cl-bench.lisp
{
  sed "s|@MISC-DIR@|$root/bench/cl-bench/misc/|" bench/cl-bench-prelude.lisp
  for f in arrays bignum boehm-gc clos crc40 deflate gabriel hash math ratios richards misc; do
    printf '\n;;;; bench/cl-bench/files/%s.lisp\n' "$f"
    cat "bench/cl-bench/files/$f.lisp"
  done
  printf '\n;;;; bench/cl-bench/tests.lisp\n'
  cat bench/cl-bench/tests.lisp
  printf '\n;;;; bench/cl-bench-driver.lisp\n'
  cat bench/cl-bench-driver.lisp
} >"$src"

if [ $run_kiln = 1 ] && [ $build_exe = 1 ]; then
  cargo build -q --release
  sbcl --dynamic-space-size 4GB --noinform --non-interactive \
    --load "$root/tools/env.lisp" \
    --eval '(ql:quickload "kiln" :silent t)' \
    --eval "(defvar *session* (kiln.compiler:make-session))" \
    --eval "(kiln:compile-kernel \"$build/kernel.kir\" :session *session*)" \
    --eval "(kiln:compile-clos \"$build/clos.kir\" :session *session*)" \
    --eval "(kiln:compile-frontend \"$build/frontend.kir\" :session *session*)" \
    --eval "(kiln:compile-eval \"$build/eval.kir\" :session *session*)" \
    --eval "(kiln:compile-compiler \"$build/compiler.kir\" :session *session*)" \
    --eval "(kiln:compile-file-to-kir \"$src\" \"$build/co-cl-bench.kir\" :session *session*)" \
    >"$build/compile.log" 2>&1 || { tail -40 "$build/compile.log"; exit 1; }
  target/release/kiln-cg obj "$build"/{kernel,clos,frontend,eval,compiler,co-cl-bench}.kir \
    -o "$build/co-cl-bench.o"
  cc "$build/co-cl-bench.o" target/release/libkiln_launcher.a -o "$build/co-cl-bench" \
    -lpthread -ldl -lm
fi

if [ $run_kiln = 1 ]; then
  echo "kiln:" >&2
  : >"$build/kiln.txt"
  (cd "$build" && BENCH_LIST=1 ./co-cl-bench) >"$build/kiln-list.txt"
  while read -r name group; do
    # walk-list/mess recurses deeply (SBCL skips it).
    status=0
    out=$(cd "$build" && BENCH_SELECT="$name" KILN_STACK_SIZE=${KILN_STACK_SIZE:-1073741824} \
            timeout "${BENCH_TIMEOUT:-120}" ./co-cl-bench 2>&1) || status=$?
    line=$(printf '%s\n' "$out" | grep "^$name " | tail -1 || true)
    if [ $status = 124 ]; then line="$name $group TIMEOUT ${BENCH_TIMEOUT:-120}s"
    elif [ -z "$line" ]; then line="$name $group CRASH exit $status"
    fi
    echo "$line" | tee -a "$build/kiln.txt" >&2
  done <"$build/kiln-list.txt"
fi
if [ $run_sbcl = 1 ]; then
  echo "sbcl:" >&2
  sbcl --dynamic-space-size 8GB --script "$src" 2>&1 | tee "$build/sbcl.txt" >&2
fi

# The table.
if [ $run_kiln = 1 ] && [ $run_sbcl = 1 ]; then
  awk '
    FNR == NR { if ($3 ~ /^[0-9.]+$/) sbcl[$1] = $3; else sbcl[$1] = $3; next }
    {
      k = $3; s = ($1 in sbcl) ? sbcl[$1] : "-"
      ratio = "-"
      if (k ~ /^[0-9.]+$/ && s ~ /^[0-9.]+$/ && s > 0) ratio = sprintf("%.1fx", k / s)
      printf "%-28s %-9s %12s %12s %8s\n", $1, $2, k, s, ratio
    }' "$build/sbcl.txt" "$build/kiln.txt" >"$build/table.txt"
  printf "%-28s %-9s %12s %12s %8s\n" benchmark group "kiln ms" "sbcl ms" ratio
  cat "$build/table.txt"
fi
