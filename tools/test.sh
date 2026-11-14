#!/usr/bin/env bash
# Runs file compilation tests from a shared base image; --cross selects
# the independent LIR JIT/AOT backend suite.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ "${1:-}" == --cross ]]; then
  shift
  exec "$root/tools/test-cross.sh" "$@"
fi
# KILN_COMPILER selects the cross-compiling build program, as before.
if [[ -n "${KILN_COMPILER:-}" ]]; then
  exec "$root/tools/test-cross.sh" "$@"
fi
exec python3 "$root/tools/test-fasl.py" "$@"
