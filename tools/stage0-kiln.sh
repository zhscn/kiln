#!/usr/bin/env bash
# Makes stage0 (SBCL) and links kiln0, as tools/bootstrap.sh does, into
# DIR (default build/boot): for trying a change to the compiler quickly.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$(realpath -m "${1:-$root/build/boot}")
cd "$root"
pipeline=${KILN_BUILD_PIPELINE:-hir}
case "$pipeline" in
  hir|mir) ;;
  *) echo "KILN_BUILD_PIPELINE must be hir or mir" >&2; exit 2 ;;
esac
cargo build -q
rm -rf "$dir/stage0"
mkdir -p "$dir/stage0"
printf '%s\n' "$pipeline" >"$dir/pipeline"
KILN_STAGE0_DIR="$dir/stage0/" sbcl --dynamic-space-size 4GB --noinform --non-interactive \
  --load "$root/tools/env.lisp" \
  --eval '(ql:quickload "kiln" :silent t)' \
  --eval "(kiln:bootstrap-stage0 (uiop:getenv \"KILN_STAGE0_DIR\") :pipeline :$pipeline)" \
  >"$dir/stage0.log" 2>&1 || { cat "$dir/stage0.log"; exit 1; }
kirs=()
for m in kernel clos frontend eval compiler build; do kirs+=("$dir/stage0/$m.lir"); done
"$root/target/debug/kiln-cg" obj "${kirs[@]}" -o "$dir/kiln0.o"
cc "$dir/kiln0.o" "$root/target/debug/libkiln_launcher.a" -o "$dir/kiln0" -lpthread -ldl -lm
rm "$dir/kiln0.o"
