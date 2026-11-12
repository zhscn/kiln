#!/usr/bin/env bash
# Builds the kernel, CLOS and eval modules (SBCL, into build/repl) and an
# executable linked from them (kiln-cg obj) if a source changed, then
# starts kiln's read-eval-print loop. Forms are evaluated by
# the HIR evaluator. With --jit, runs the modules with the JIT instead
# (slower to start: it compiles them all).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=$root/build/repl
mkdir -p "$build"
cd "$root"
cargo build -q
main=$build/main.lisp
echo '(kiln.sys:repl)' >"$main"
stamp=$build/main.lir
if [ ! -e "$stamp" ] || [ -n "$(find lisp vendor kiln.asd -newer "$stamp" -name '*.lisp' -print -quit)" ]; then
  echo "; building the image (a few minutes)" >&2
  sbcl --noinform --non-interactive \
    --load "$root/tools/env.lisp" \
    --eval '(ql:quickload "kiln" :silent t)' \
    --eval "(defvar *session* (kiln.compiler:make-session))" \
    --eval "(kiln:compile-kernel \"$build/kernel.lir\" :session *session*)" \
    --eval "(kiln:compile-clos \"$build/clos.lir\" :session *session*)" \
    --eval "(kiln:compile-frontend \"$build/frontend.lir\" :session *session*)" \
    --eval "(kiln:compile-eval \"$build/eval.lir\" :session *session*)" \
    --eval "(kiln:compile-file-to-lir \"$main\" \"$build/main.lir\" :session *session*)" \
    >"$build/compile.log" 2>&1 || { tail -40 "$build/compile.log"; exit 1; }
fi
modules=("$build/kernel.lir" "$build/clos.lir" "$build/frontend.lir" "$build/eval.lir" "$build/main.lir")
if [ "${1:-}" = --jit ]; then
  exec "$root/target/debug/kiln-cg" jit "${modules[@]}"
fi
exe=$build/kiln
launcher=$root/target/debug/libkiln_launcher.a
if [ ! -e "$exe" ] || [ "$stamp" -nt "$exe" ] || [ "$launcher" -nt "$exe" ]; then
  "$root/target/debug/kiln-cg" obj "${modules[@]}" -o "$build/kiln.o"
  cc "$build/kiln.o" "$launcher" -o "$exe" -lpthread -ldl -lm
fi
exec "$exe"
