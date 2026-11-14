#!/usr/bin/env bash
# Bootstraps kiln.
#   stage0: SBCL compiles the five modules and the build program
#           (lisp/target/build.lisp) to binary LIR requests.
#   kiln0:  the stage0 LIR requests, linked into an AOT executable; run, it writes
#           stage1, the same modules and build program compiled by kiln.
#   kiln1:  the stage1 LIR requests, linked; run, it writes stage2.
# stage1 must be stage0 and stage2 stage1, file for file, and kiln1 kiln0,
# byte for byte (kiln-cg's output depends only on the program records).
# Usage: tools/bootstrap.sh [--from-stage1]  (--from-stage1 reuses stage0,
# stage1 and kiln0 and only builds kiln1 and stage2.)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
boot=$(realpath -m "${KILN_BOOT_DIR:-$root/build/boot}")
case "$boot" in
  "$root/build/"*) ;;
  *) echo "KILN_BOOT_DIR must name a directory below $root/build" >&2; exit 2 ;;
esac
pipeline=${KILN_BUILD_PIPELINE:-hir}
case "$pipeline" in
  hir|mir) ;;
  *) echo "KILN_BUILD_PIPELINE must be hir or mir" >&2; exit 2 ;;
esac
if [ "${1:-}" = --from-stage1 ]; then
  previous=$(cat "$boot/pipeline" 2>/dev/null || echo hir)
  if [ "$previous" != "$pipeline" ]; then
    echo "Bootstrap pipeline differs from stage0; rebuild without --from-stage1" >&2
    exit 2
  fi
fi
cd "$root"
cargo build -q
cg=$root/target/debug/kiln-cg
launcher=$root/target/debug/libkiln_launcher.a
# Compiling the compiler module keeps the session's environment and the
# modules compiled before it live.
heap=${KILN_BOOT_HEAP:-8589934592}
modules=(kernel clos frontend eval compiler build)

link() { # link STAGE-DIR EXECUTABLE
  local kirs=() ext=lir
  [ -f "$1/kernel.lir" ] || ext=kir
  for m in "${modules[@]}"; do kirs+=("$1/$m.$ext"); done
  "$cg" obj "${kirs[@]}" -o "$2.o"
  cc "$2.o" "$launcher" -o "$2" -lpthread -ldl -lm
  rm "$2.o"
}

run() { # run EXECUTABLE STAGE-DIR (with the manifest of stage0)
  rm -rf "$2"
  mkdir -p "$2"
  cp "$boot/stage0/modules.lisp-expr" "$2/"
  local ext=lir
  [ -f "$boot/stage0/kernel.lir" ] || ext=kir
  (cd "$2" && KILN_OUTPUT_FORMAT=$ext MMTK_GC_TRIGGER=FixedHeapSize:$heap /usr/bin/time -f "%e s, %M KiB" "$1") \
    2>&1 | tee "$2/build.log"
}

compare() { # compare STAGE-DIR STAGE-DIR
  local ok=0 ext=lir
  [ -f "$1/kernel.lir" ] || ext=kir
  for m in "${modules[@]}"; do
    if cmp -s "$1/$m.$ext" "$2/$m.$ext"; then
      echo "same $m.$ext"
    else
      echo "DIFFERENT $m.$ext ($(basename "$1") and $(basename "$2"))"; ok=1
    fi
  done
  return $ok
}

if [ "${1:-}" != --from-stage1 ]; then
  rm -rf "$boot"
  mkdir -p "$boot/stage0"
  printf '%s\n' "$pipeline" >"$boot/pipeline"
  echo "stage0 (SBCL)"
  KILN_STAGE0_DIR="$boot/stage0/" sbcl --dynamic-space-size 4GB --noinform --non-interactive \
    --load "$root/tools/env.lisp" \
    --eval '(ql:quickload "kiln" :silent t)' \
    --eval "(kiln:bootstrap-stage0 (uiop:getenv \"KILN_STAGE0_DIR\") :pipeline :$pipeline)" \
    >"$boot/stage0.log" 2>&1 || { cat "$boot/stage0.log"; exit 1; }
  echo "kiln0"
  link "$boot/stage0" "$boot/kiln0"
  echo "stage1 (kiln0)"
  run "$boot/kiln0" "$boot/stage1"
fi
compare "$boot/stage0" "$boot/stage1"
echo "kiln1"
link "$boot/stage1" "$boot/kiln1"
if cmp -s "$boot/kiln0" "$boot/kiln1"; then
  echo "same kiln1 (kiln0)"
else
  echo "DIFFERENT kiln1 (kiln0)"; exit 1
fi
echo "stage2 (kiln1)"
run "$boot/kiln1" "$boot/stage2"
compare "$boot/stage1" "$boot/stage2"
echo "bootstrap: kiln1 compiles itself to itself"
