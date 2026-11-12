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
stamp=$build/main.kir
if [ ! -e "$stamp" ] || [ -n "$(find lisp vendor kiln.asd -newer "$stamp" -name '*.lisp' -print -quit)" ]; then
  echo "; building the image (a few minutes)" >&2
  sbcl --noinform --non-interactive \
    --load "$root/tools/env.lisp" \
    --eval '(ql:quickload "kiln" :silent t)' \
    --eval "(defvar *session* (kiln.compiler:make-session))" \
    --eval "(kiln:compile-kernel \"$build/kernel.kir\" :session *session*)" \
    --eval "(kiln:compile-clos \"$build/clos.kir\" :session *session*)" \
    --eval "(kiln:compile-frontend \"$build/frontend.kir\" :session *session*)" \
    --eval "(kiln:compile-eval \"$build/eval.kir\" :session *session*)" \
    --eval "(kiln:compile-file-to-kir \"$main\" \"$build/main.kir\" :session *session*)" \
    >"$build/compile.log" 2>&1 || { tail -40 "$build/compile.log"; exit 1; }
fi
modules=("$build/kernel.kir" "$build/clos.kir" "$build/frontend.kir" "$build/eval.kir" "$build/main.kir")
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
