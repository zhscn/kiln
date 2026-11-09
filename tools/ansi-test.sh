#!/usr/bin/env bash
# Runs the ANSI Common Lisp test suite (~/package/ansi-test) on kiln,
# one group per process from a shared prelude heap image.
#
# Usage:
#   tools/ansi-test.sh [GROUP...]
# Environment:
#   KILN_COMPILER   kiln executable (default: build/boot/kiln1, or build/stage0/kiln0)
#   ANSI_TEST_DIR   path to ansi-test checkout (default: ~/package/ansi-test)
#   ANSI_EVAL       "hybrid" (default: Maclina + native DEFSTRUCT) or "native"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ANSI_TEST_DIR="${ANSI_TEST_DIR:-$HOME/package/ansi-test}"
if [[ ! -d "$ANSI_TEST_DIR" ]]; then
  echo "ansi-test not found at $ANSI_TEST_DIR" >&2
  exit 1
fi

if [[ -z "${KILN_COMPILER:-}" ]]; then
  if [[ -x build/boot/kiln1 ]]; then
    KILN_COMPILER=build/boot/kiln1
  elif [[ -x build/stage0/kiln0 ]]; then
    KILN_COMPILER=build/stage0/kiln0
  else
    echo "No kiln executable found (run tools/stage0-kiln.sh or tools/bootstrap.sh)" >&2
    exit 1
  fi
fi

OUT_DIR="$ROOT/build/ansi-test"
SANDBOX_DIR="$OUT_DIR/sandbox/"
IMAGE="$OUT_DIR/prelude.img"
PRELUDE_LISP="$OUT_DIR/make-prelude.lisp"
HEAP_SIZE="${KILN_HEAP_SIZE:-4294967296}"

mkdir -p "$OUT_DIR" "$SANDBOX_DIR"

if [[ ! -f "$IMAGE" || "$KILN_COMPILER" -nt "$IMAGE" || "$0" -nt "$IMAGE" ]]; then
  cat > "$PRELUDE_LISP" <<'EOF'
(in-package :cl-user)

(defun ansi-getenv (name)
  (let ((value (kiln.kernel::sys-string 10 (kiln.kernel::string-octets name))))
    (and (stringp value) (plusp (length value)) value)))

(defparameter *ansi-test-dir*
  (pathname (or (ansi-getenv "ANSI_TEST_DIR")
                "/home/zhscn/package/ansi-test/")))
(defvar *aux-dir* (merge-pathnames "auxiliary/" *ansi-test-dir*))

(defun compile-and-load (pathspec &key force)
  (declare (ignore force))
  (let* ((pathname (pathname pathspec))
         (pathname (if *load-pathname*
                       (merge-pathnames pathname *load-pathname*)
                       pathname))
         (kiln.kernel::*eval-function* 'kiln.compiler::native-eval))
    (load pathname)))

(defun compile-and-load* (pathspec &key force)
  (compile-and-load (merge-pathnames pathspec *aux-dir*) :force force))

(let ((*default-pathname-defaults* *ansi-test-dir*))
  (load "rt-package.lsp")
  (load "rt.lsp")
  (load "cl-test-package.lsp")
  (in-package :cl-test)
  (compile-and-load* "ansi-aux-macros.lsp")
  (load "universe.lsp")
  (compile-and-load* "random-aux.lsp")
  (compile-and-load* "ansi-aux.lsp")
  (load "cl-symbol-names.lsp")
  (load "notes.lsp"))

(in-package :cl-user)

(defun tree-has-defstruct-p (form)
  (and (consp form)
       (or (eq (car form) 'defstruct)
           (and (consp (cdr form))
                (or (tree-has-defstruct-p (car form))
                    (tree-has-defstruct-p (cdr form)))))))

(defun hybrid-eval (form)
  (if (tree-has-defstruct-p form)
      (kiln.compiler::native-eval form)
      (kiln.kernel::maclina-eval form)))

(defun run-ansi-group ()
  (let ((group (ansi-getenv "ANSI_GROUP"))
        (eval-mode (ansi-getenv "ANSI_EVAL"))
        (sandbox (ansi-getenv "ANSI_SANDBOX")))
    (when sandbox
      (setf regression-test::*sandbox-path* (pathname sandbox)))
    (unless (and eval-mode (string= eval-mode "native"))
      (setf kiln.kernel::*eval-function* #'hybrid-eval))
    (if group
        (let ((*default-pathname-defaults* *ansi-test-dir*)
              (*package* (find-package :cl-test)))
          (load (concatenate 'string group "/load.lsp"))
          (regression-test:do-tests))
        (let ((*default-pathname-defaults* *ansi-test-dir*)
              (*package* (find-package :cl-test)))
          (kiln.sys:serve)))))

(let ((img (or (ansi-getenv "ANSI_IMAGE")
               "build/ansi-test/prelude.img")))
  (kiln.sys:save-image img :toplevel #'run-ansi-group))
EOF
  echo "Building prelude image $IMAGE with $KILN_COMPILER..."
  printf '(:eval 1 "(load \\"%s\\")")\n' "$PRELUDE_LISP" \
    | ANSI_TEST_DIR="${ANSI_TEST_DIR%/}/" ANSI_IMAGE="$IMAGE" \
      KILN_HEAP_SIZE="$HEAP_SIZE" KILN_SERVE=1 "$KILN_COMPILER" > "$OUT_DIR/prelude.log" 2>&1
fi

ALL_GROUPS=(
  symbols
  eval-and-compile
  data-and-control-flow
  iteration
  objects
  conditions
  cons
  types-and-classes
  arrays
  hash-tables
  packages
  numbers
  sequences
  structures
  strings
  characters
  pathnames
  files
  streams
  printer
  reader
  system-construction
  environment
  misc
)

if [[ $# -gt 0 ]]; then
  TEST_GROUPS=("$@")
else
  TEST_GROUPS=("${ALL_GROUPS[@]}")
fi

printf "%-24s %7s %7s %7s %7s %8s\n" "Group" "Passed" "Failed" "Total" "Rate" "Time"
printf "%-24s %7s %7s %7s %7s %8s\n" "------------------------" "-------" "-------" "-------" "-------" "--------"

sum_passed=0
sum_failed=0
sum_total=0
sum_time=0

for g in "${TEST_GROUPS[@]}"; do
  rm -rf "$SANDBOX_DIR"
  mkdir -p "$SANDBOX_DIR"
  t0=$(date +%s.%N)
  set +e
  ANSI_GROUP="$g" ANSI_TEST_DIR="${ANSI_TEST_DIR%/}/" ANSI_SANDBOX="$SANDBOX_DIR" \
    KILN_HEAP_SIZE="$HEAP_SIZE" KILN_IMAGE="$IMAGE" "$KILN_COMPILER" > "$OUT_DIR/${g}.log" 2>&1
  rc=$?
  set -e
  t1=$(date +%s.%N)
  dt=$(awk "BEGIN {printf \"%.2f\", $t1 - $t0}")
  sum_time=$(awk "BEGIN {printf \"%.2f\", $sum_time + ($t1 - $t0)}")
  total=$(grep -a "^Doing .* pending tests" "$OUT_DIR/${g}.log" | tail -n 1 | awk '{print $2}' || true)
  failed=$(grep -a -c "^Test .* failed$" "$OUT_DIR/${g}.log" || true)
  if [[ -z "$total" || "$rc" -ne 0 ]]; then
    printf "%-24s %7s %7s %7s %7s %7ss (rc=%d)\n" "$g" "-" "$failed" "${total:--}" "CRASH" "$dt" "$rc"
  else
    passed=$((total - failed))
    rate=$(awk "BEGIN {printf \"%.1f%%\", ($passed * 100.0) / $total}")
    printf "%-24s %7d %7d %7d %7s %7ss\n" "$g" "$passed" "$failed" "$total" "$rate" "$dt"
    sum_passed=$((sum_passed + passed))
    sum_failed=$((sum_failed + failed))
    sum_total=$((sum_total + total))
  fi
done

if [[ ${#TEST_GROUPS[@]} -gt 1 && $sum_total -gt 0 ]]; then
  printf "%-24s %7s %7s %7s %7s %8s\n" "------------------------" "-------" "-------" "-------" "-------" "--------"
  tot_rate=$(awk "BEGIN {printf \"%.1f%%\", ($sum_passed * 100.0) / $sum_total}")
  printf "%-24s %7d %7d %7d %7s %7ss\n" "Total" "$sum_passed" "$sum_failed" "$sum_total" "$tot_rate" "$sum_time"
fi
