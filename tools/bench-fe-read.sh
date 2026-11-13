#!/usr/bin/env bash
# Times bench/fe-read.lisp in kiln (JIT) and the same code in SBCL;
# BENCH=bench/other.lisp runs another benchmark in kiln only.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=$root/build/bench
mkdir -p "$build"
cd "$root"
cargo build -q
sbcl --dynamic-space-size 4GB --noinform --non-interactive --load "$root/tools/env.lisp" \
  --eval '(ql:quickload "kiln" :silent t)' \
  --eval "(defvar *session* (kiln.compiler:make-session))" \
  --eval "(kiln:compile-kernel \"$build/kernel.lir\" :session *session*)" \
  --eval "(kiln:compile-clos \"$build/clos.lir\" :session *session*)" \
  --eval "(kiln:compile-frontend \"$build/frontend.lir\" :session *session*)" \
  --eval "(kiln:compile-file-to-lir \"${BENCH:-bench/fe-read.lisp}\" \"$build/bench.lir\" :session *session*)" \
  >"$build/compile.log" 2>&1 || { cat "$build/compile.log"; exit 1; }
echo "kiln:"
"$root/target/debug/kiln-cg" jit "$build/kernel.lir" "$build/clos.lir" "$build/frontend.lir" "$build/bench.lir"
# BENCH names another kiln-only benchmark file (no SBCL comparison).
[ -n "${BENCH:-}" ] && exit 0
echo "SBCL:"
sbcl --dynamic-space-size 4GB --noinform --non-interactive --load "$root/tools/env.lisp" \
  --eval '(ql:quickload (list "kiln" "eclector-concrete-syntax-tree") :silent t)' \
  --load bench/fe-read.lisp 2>&1 | grep -v "^;\|^$"
