#!/usr/bin/env bash
# Fetch the pinned Lisp dependencies listed in deps.lock.
#
#   tools/fetch-deps.sh          clone/update into $KILN_DEPS_DIR (default: deps/)
#   tools/fetch-deps.sh --check  only verify that each checkout is at its pinned commit
#
# Dependencies not in deps.lock come from Quicklisp; tools/load-deps.lisp
# loads everything.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir=${KILN_DEPS_DIR:-$root/deps}
check=0
[[ ${1:-} == --check ]] && check=1
mkdir -p "$dir"
bad=0
while read -r name url branch commit; do
  [[ -z $name || $name == \#* ]] && continue
  d=$dir/$name
  if (( check )); then
    have=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo missing)
    if [[ $have != "$commit" ]]; then echo "MISMATCH $name: have $have, want $commit"; bad=1; fi
    continue
  fi
  if [[ ! -d $d/.git ]]; then
    git clone -q --branch "$branch" "$url" "$d"
  elif ! git -C "$d" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$d" fetch -q origin "$branch"
  fi
  git -C "$d" checkout -q "$commit"
  echo "$name $commit"
done < "$root/deps.lock"
exit $bad
