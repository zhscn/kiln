#!/usr/bin/env bash
# Runs the end-to-end tests: SBCL (or kiln, with KILN_COMPILER set to a
# kiln executable such as build/boot/kiln1) compiles each tests/*/*.lisp to KIR,
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

if [ $# -gt 0 ]; then sources=("$@"); else sources=("$root"/tests/*/*.lisp); fi
# Absolute names: they are in the debug info of the KIR, which
# same-kir tests compare.
for i in "${!sources[@]}"; do sources[i]=$(realpath "${sources[i]}"); done
# shellcheck disable=SC2206
sources=(${sources[@]})
# A test NAME.lisp with a file NAME.slow (holding a heap size in bytes)
# runs only when named on the command line, once, with that heap.
if [ $# -eq 0 ]; then
  fast=()
  for src in "${sources[@]}"; do
    [ -f "${src%.lisp}.slow" ] || fast+=("$src")
  done
  sources=("${fast[@]}")
fi
# A test NAME.lisp with a file NAME.same-kir prints a module compiled on
# kiln: its expected output is the KIR that SBCL made, in
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
# shared HIR eval module after the front end, co-*.lisp also with compiler
# modules.
need_clos=0
need_fe=0
need_ev=0
need_co=0
for src in "${sources[@]}"; do
  case $(basename "$src") in
    clos-*) need_clos=1 ;;
    fe-*) need_clos=1; need_fe=1 ;;
    ev-*) need_clos=1; need_fe=1; need_ev=1 ;;
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
if [ -n "${KILN_COMPILER:-}" ]; then
  # kiln compiles the tests: KILN_COMPILER is a kiln built
  # by tools/bootstrap.sh (build/boot/kiln1). SBCL only writes the
  # manifest; the build program compiles the five modules and then each
  # test, in one session, as SBCL does above.
  compiler=$(realpath "$KILN_COMPILER")
  programs=""
  # kiln runs in the build directory.
  for src in "${sources[@]}"; do programs+=" \"$(realpath "$src")\""; done
  sbcl --noinform --non-interactive \
    --load "$root/tools/env.lisp" \
    --eval '(ql:quickload "kiln" :silent t)' \
    --eval "(kiln:write-manifest \"$build/modules.lisp-expr\" :programs '($programs))" \
    >"$build/compile.log" 2>&1 || { cat "$build/compile.log"; exit 1; }
  # The five modules compiled are saved as a heap image,
  # reused while the compiler and module sources match.
  image=$build/kiln-compiler.img
  key=$( { sha256sum "$compiler"
           sbcl --noinform --non-interactive --eval '(require :sb-md5)' --eval "
             (with-open-file (in \"$build/modules.lisp-expr\")
               (dolist (entry (subseq (read in) 0 5))
                 (dolist (f (rest entry))
                   (let ((f (if (consp f) (car (last f)) f)))
                     (format t \"~a ~(~{~2,'0x~}~)~%\" f (coerce (sb-md5:md5sum-file f) 'list))))))"
         } | sha256sum | cut -d' ' -f1)
  if [ -f "$image" ] && [ "$(cat "$image.key" 2>/dev/null)" = "$key" ]; then
    run=(env KILN_IMAGE="$image")
  else
    rm -f "$image" "$image.key"
    run=(env KILN_SAVE_IMAGE="$image")
  fi
  (cd "$build" && KILN_OUTPUT_FORMAT=kir "${run[@]}" MMTK_GC_TRIGGER=FixedHeapSize:${KILN_COMPILER_HEAP:-8589934592} "$compiler") \
    >>"$build/compile.log" 2>&1 || { cat "$build/compile.log"; exit 1; }
  if [ -f "$image" ] && [ ! -f "$image.key" ]; then echo "$key" >"$image.key"; fi
else
  sbcl --dynamic-space-size 4GB --noinform --non-interactive \
    --load "$root/tools/env.lisp" \
    --eval '(ql:quickload "kiln" :silent t)' \
    "${args[@]}" >"$build/compile.log" 2>&1 || { cat "$build/compile.log"; exit 1; }
fi

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
    ev-*) modules+=("$build/clos.kir" "$build/frontend.kir" "$build/eval.kir"); heap=67108864 ;;
    co-*) modules+=("$build/clos.kir" "$build/frontend.kir" "$build/eval.kir" "$build/compiler.kir")
          heap=67108864 ;;
  esac
  # Compiling a module on kiln keeps the module and the session live.
  case $name in
    co-kernel) heap=268435456 ;;
  esac
  # A slow test runs once, with the JIT and its heap: the three modes run
  # the same code, and its heap is too big for GC stress.
  if [ -f "${src%.lisp}.slow" ]; then
    if MMTK_GC_TRIGGER=FixedHeapSize:$(cat "${src%.lisp}.slow") "$cg" jit "${modules[@]}" "$kir" \
         >"$build/$name.jit.out" 2>&1 && diff -q "$expected" "$build/$name.jit.out"; then
      echo "PASS jit $name"
    else
      echo "FAIL jit $name"; fail=1
    fi
    continue
  fi
  # A test NAME.lisp with a file NAME.image saves a heap image
  # as NAME.img and an executable with it appended as NAME.exe, running in
  # the build directory: only an AOT executable can. NAME.image is the
  # expected output of the runs from the image, with the usual heap,
  # under GC stress, and of the executable if the program wrote one. The expected output of the
  # program run from NAME-2.img, if the run from the image saves one, is
  # NAME.image2.
  if [ -f "${src%.lisp}.image" ]; then
    if "$cg" obj "${modules[@]}" "$kir" -o "$build/$name.o" \
       && cc "$build/$name.o" "$launcher" -o "$build/$name" -lpthread -ldl -lm \
       && rm -f "$build/$name.img" "$build/$name.exe" "$build/$name-2.img" \
       && (cd "$build" && "./$name") >"$build/$name.aot.out" 2>&1 \
       && diff -u "$expected" "$build/$name.aot.out"; then
      echo "PASS aot $name"
    else
      echo "FAIL aot $name"; fail=1
    fi
    for mode in image stress exe; do
      case $mode in
        image) run=(env KILN_IMAGE="$build/$name.img" "$build/$name") ;;
        stress) run=(env KILN_IMAGE="$build/$name.img" MMTK_GC_TRIGGER=FixedHeapSize:$heap "$build/$name") ;;
        exe) [ -f "$build/$name.exe" ] || continue
             run=("$build/$name.exe") ;;
      esac
      if (cd "$build" && "${run[@]}") >"$build/$name.$mode.out" 2>&1 \
         && diff -u "${src%.lisp}.image" "$build/$name.$mode.out"; then
        echo "PASS $mode $name"
      else
        echo "FAIL $mode $name"; fail=1
      fi
    done
    # The run from the image saves NAME-2.img (NAME.image2: its output).
    if [ -f "${src%.lisp}.image2" ]; then
      if (cd "$build" && KILN_IMAGE="$build/$name-2.img" MMTK_GC_TRIGGER=FixedHeapSize:$heap "$build/$name") \
           >"$build/$name.image2.out" 2>&1 \
         && diff -u "${src%.lisp}.image2" "$build/$name.image2.out"; then
        echo "PASS image2 $name"
      else
        echo "FAIL image2 $name"; fail=1
      fi
    fi
    continue
  fi
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
