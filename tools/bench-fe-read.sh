#!/usr/bin/env bash
# Times bench/fe-read.lisp in kiln (JIT) and the same code in SBCL;
# BENCH=bench/other.lisp runs another benchmark in kiln only.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=$root/build/bench
mkdir -p "$build"
cd "$root"
cargo build -q
sbcl --noinform --non-interactive --load "$root/tools/env.lisp" \
  --eval '(ql:quickload "kiln" :silent t)' \
  --eval "(defvar *session* (kiln.compiler:make-session))" \
  --eval "(kiln:compile-kernel \"$build/kernel.kir\" :session *session*)" \
  --eval "(kiln:compile-clos \"$build/clos.kir\" :session *session*)" \
  --eval "(kiln:compile-frontend \"$build/frontend.kir\" :session *session*)" \
  --eval "(kiln:compile-file-to-kir \"${BENCH:-bench/fe-read.lisp}\" \"$build/bench.kir\" :session *session*)" \
  >"$build/compile.log" 2>&1 || { cat "$build/compile.log"; exit 1; }
echo "kiln:"
"$root/target/debug/kiln-cg" jit "$build/kernel.kir" "$build/clos.kir" "$build/frontend.kir" "$build/bench.kir"
# BENCH names another kiln-only benchmark file (no SBCL comparison).
[ -n "${BENCH:-}" ] && exit 0
echo "SBCL:"
sbcl --noinform --non-interactive --load "$root/tools/env.lisp" \
  --eval '(ql:quickload (list "kiln" "eclector-concrete-syntax-tree") :silent t)' \
  --load bench/fe-read.lisp 2>&1 | grep -v "^;\|^$"
