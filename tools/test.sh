#!/usr/bin/env bash
# Runs the end-to-end tests: SBCL compiles each tests/*/*.lisp to KIR,
# then kiln-cg runs it with the JIT (normally and under GC stress) and
# builds/runs an AOT executable.
# Each output must match the .expected file.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=$root/build/test
mkdir -p "$build"
cd "$root"
cargo build -q
cg=$root/target/debug/kiln-cg
launcher=$root/target/debug/libkiln_launcher.a

sources=("${@:-$root/tests/*/*.lisp}")
# shellcheck disable=SC2206
sources=(${sources[@]})

args=()
for src in "${sources[@]}"; do
  args+=(--eval "(kiln:compile-file-to-kir \"$src\" \"$build/$(basename "${src%.lisp}").kir\")")
done
sbcl --noinform --non-interactive \
  --load "$root/tools/env.lisp" \
  --eval '(ql:quickload "kiln" :silent t)' \
  "${args[@]}" >"$build/compile.log" 2>&1 || { cat "$build/compile.log"; exit 1; }

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
  # GC stress: a 1 MiB heap forces frequent moving collections.
  if MMTK_GC_TRIGGER=FixedHeapSize:1048576 "$cg" jit "$kir" >"$build/$name.stress.out" 2>&1 \
     && diff -u "$expected" "$build/$name.stress.out"; then
    echo "PASS gc-stress $name"
  else
    echo "FAIL gc-stress $name"; fail=1
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
