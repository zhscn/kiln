#!/usr/bin/env bash
# Runs the M0 end-to-end tests: SBCL compiles each tests/m0/*.lisp to KIR,
# then kiln-cg runs it with the JIT and builds/runs an AOT executable.
# Each output must match the .expected file.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=$root/build/m0
mkdir -p "$build"
cd "$root"
cargo build -q
cg=$root/target/debug/kiln-cg
launcher=$root/target/debug/libkiln_launcher.a

sources=("${@:-$root/tests/m0/*.lisp}")
# shellcheck disable=SC2206
sources=(${sources[@]})

args=()
for src in "${sources[@]}"; do
  args+=(--eval "(kiln:compile-file-to-kir \"$src\" \"$build/$(basename "${src%.lisp}").kir\")")
done
sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval "(asdf:load-asd \"$root/kiln.asd\")" \
  --eval '(asdf:load-system :kiln)' \
  "${args[@]}" >/dev/null

fail=0
for src in "${sources[@]}"; do
  name=$(basename "${src%.lisp}")
  kir=$build/$name.kir
  expected=${src%.lisp}.expected
  if "$cg" jit "$kir" >"$build/$name.jit.out" 2>&1 && diff -u "$expected" "$build/$name.jit.out"; then
    echo "PASS jit $name"
  else
    echo "FAIL jit $name"; fail=1
  fi
  if "$cg" obj "$kir" -o "$build/$name.o" \
     && cc "$build/$name.o" "$launcher" -o "$build/$name" -lpthread -ldl -lm \
     && "$build/$name" >"$build/$name.aot.out" 2>&1 \
     && diff -u "$expected" "$build/$name.aot.out"; then
    echo "PASS aot $name"
  else
    echo "FAIL aot $name"; fail=1
  fi
done
exit $fail
