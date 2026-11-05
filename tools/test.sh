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
# A test NAME.lisp with a file NAME.same-kir prints a module compiled on
# kiln (docs/11 §8, §9): its expected output is the KIR that SBCL made, in
# the same session, of the test or the module (kernel, clos...) that the
# file names. Such a test is run too.
for src in "${sources[@]}"; do
  same=${src%.lisp}.same-kir
  if [ -f "$same" ] && [ -f "$(dirname "$src")/$(cat "$same").lisp" ]; then
    other=$(dirname "$src")/$(cat "$same").lisp
    case " ${sources[*]} " in
      *" $other "*) ;;
      *) sources+=("$other") ;;
    esac
  fi
done

# One SBCL session: the kernel is compiled once, then every test in the
# same compile-time environment.
args=(--eval "(defvar *session* (kiln.compiler:make-session))"
      --eval "(kiln:compile-kernel \"$build/kernel.kir\" :session *session*)")
# Tests named clos-*.lisp run with the CLOS module loaded after the kernel,
# fe-*.lisp also with the front-end module after it, ev-*.lisp with the
# eval module after CLOS, co-*.lisp with the front-end, eval and compiler
# modules (docs/11 §3).
need_clos=0
need_fe=0
need_ev=0
need_co=0
for src in "${sources[@]}"; do
  case $(basename "$src") in
    clos-*) need_clos=1 ;;
    fe-*) need_clos=1; need_fe=1 ;;
    ev-*) need_clos=1; need_ev=1 ;;
    co-*) need_clos=1; need_fe=1; need_ev=1; need_co=1 ;;
  esac
done
if [ $need_clos = 1 ]; then
  args+=(--eval "(kiln:compile-clos \"$build/clos.kir\" :session *session*)")
fi
if [ $need_fe = 1 ]; then
  args+=(--eval "(kiln:compile-frontend \"$build/frontend.kir\" :session *session*)")
fi
if [ $need_ev = 1 ]; then
  args+=(--eval "(kiln:compile-eval \"$build/eval.kir\" :session *session*)")
fi
if [ $need_co = 1 ]; then
  args+=(--eval "(kiln:compile-compiler \"$build/compiler.kir\" :session *session*)")
fi
for src in "${sources[@]}"; do
  args+=(--eval "(kiln:compile-file-to-kir \"$src\" \"$build/$(basename "${src%.lisp}").kir\" :session *session*)")
done
sbcl --dynamic-space-size 4GB --noinform --non-interactive \
  --load "$root/tools/env.lisp" \
  --eval '(ql:quickload "kiln" :silent t)' \
  "${args[@]}" >"$build/compile.log" 2>&1 || { cat "$build/compile.log"; exit 1; }

fail=0
for src in "${sources[@]}"; do
  name=$(basename "${src%.lisp}")
  kir=$build/$name.kir
  expected=${src%.lisp}.expected
  if [ -f "${src%.lisp}.same-kir" ]; then
    expected=$build/$(cat "${src%.lisp}.same-kir").kir
  fi
  modules=("$build/kernel.kir")
  # GC stress: a small heap forces frequent moving collections; CLOS's
  # live data (metaobjects, satiated call histories) needs more than 1 MiB.
  heap=1048576
  case $name in
    clos-*) modules+=("$build/clos.kir"); heap=8388608 ;;
    fe-*) modules+=("$build/clos.kir" "$build/frontend.kir"); heap=16777216 ;;
    ev-*) modules+=("$build/clos.kir" "$build/eval.kir"); heap=16777216 ;;
    co-*) modules+=("$build/clos.kir" "$build/frontend.kir" "$build/eval.kir" "$build/compiler.kir")
          heap=67108864 ;;
  esac
  # Compiling a module on kiln keeps the module and the session live.
  case $name in
    co-kernel) heap=268435456 ;;
  esac
  if "$cg" jit "${modules[@]}" "$kir" >"$build/$name.jit.out" 2>&1 && diff -u "$expected" "$build/$name.jit.out"; then
    echo "PASS jit $name"
  else
    echo "FAIL jit $name"; fail=1
  fi
  if MMTK_GC_TRIGGER=FixedHeapSize:$heap "$cg" jit "${modules[@]}" "$kir" >"$build/$name.stress.out" 2>&1 \
     && diff -u "$expected" "$build/$name.stress.out"; then
    echo "PASS gc-stress $name"
  else
    echo "FAIL gc-stress $name"; fail=1
  fi
  if "$cg" obj "${modules[@]}" "$kir" -o "$build/$name.o" \
     && cc "$build/$name.o" "$launcher" -o "$build/$name" -lpthread -ldl -lm \
     && "$build/$name" >"$build/$name.aot.out" 2>&1 \
     && diff -u "$expected" "$build/$name.aot.out"; then
    echo "PASS aot $name"
  else
    echo "FAIL aot $name"; fail=1
  fi
done
exit $fail
