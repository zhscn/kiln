(in-package #:kiln.compiler)

(defvar *compiler-pipeline* :hir
  "Native COMPILE pipeline: :HIR for production, :MIR for the experimental middle end.")

(define-condition mir-error (kiln-compile-error) ())
(define-condition mir-unsupported (mir-error) ())

(defun mir-fail (control &rest args)
  (error 'mir-error :message (apply #'format nil control args)))

(defstruct mir-unit (load-time-functions #()) (functions (make-hir-buffer)) (analyses (make-hash-table :test 'eq)))
(defstruct mir-function
  (id 0) name source (policy 1023) (internal-prefix 0) (argument-cells 0) (required 0) (optional 0) (rest nil) (key-p nil) (keys #()) (allow-other-keys nil) (bindings #()) (binding-cells 0) (captures #()) (capture-cells 0) (capture-functions #())
  (blocks (make-hir-buffer)) (instructions (make-hir-buffer)) (values (make-hir-buffer))
  (revision 0) (analyses (make-hash-table :test 'eq)))
(defun mir-function-positional-count (function)
  (+ (mir-function-required function) (mir-function-optional function)))

(defun mir-function-tail-p (function)
  (or (mir-function-rest function) (mir-function-key-p function)))

(defun mir-function-maximum (function)
  (unless (mir-function-tail-p function) (mir-function-positional-count function)))

(defstruct mir-block (id 0) (parameters #()) (instructions (make-hir-buffer)) terminator)
(defstruct mir-value (id 0) (representation :obj) (block 0) (position -1))
(defstruct mir-instruction (id 0) (kind 0) (operands #()) result data source origin (notinline nil) (policy 1023) (effects 0))
(defun mir-call-prefix-count (instruction)
  (if (and (= (mir-instruction-kind instruction) 15) (integerp (mir-instruction-data instruction)))
      (mir-instruction-data instruction) 0))

(defstruct mir-edge (target 0) (arguments #()))
;;; Terminators: jump, branch, return, trap, throw, catch-entry.
(defstruct mir-terminator (kind 0) (operands #()) (edges #()) source origin (policy 1023))

;;; Instruction kinds: constant, argument, global-read, global-write,
;;; global-function, function, global-call, call, primop, single, primary,
;;; declaration-check, argument-count, arity-check, value-ref, multiple-value-call,
;;; argument-present, rest-list, argument-error, cell, cell-read, cell-write,
;;; capture, closure, closure-set, unbound-cell, load-time-value, special-bind, special-unbind, progv-enter, catch-enter, landed-values.
(defparameter *mir-instruction-effects* #(0 0 33 34 33 8 127 127 127 56 56 127 0 32 56 127 0 56 127 56 1 2 1 56 2 0 1 7 7 63 7 57))
;;; Effects: heap/global read/write, dynamic environment, allocation, GC,
;;; possible exit, unknown call. No operation is deleted from this summary alone.

(defun mir-binding-entry-id (instruction)
  (if (= 27 (mir-instruction-kind instruction))
      (car (mir-instruction-data instruction)) (mir-instruction-data instruction)))

(defun mir-at (buffer id)
  (unless (and (integerp id) (<= 0 id) (< id (hir-buffer-count buffer)))
    (mir-fail "MIR index ~S outside 0..~D" id (hir-buffer-count buffer)))
  (svref (hir-buffer-data buffer) id))

(defun mir-add-value (function representation block position)
  (let ((id (hir-buffer-count (mir-function-values function))))
    (hir-push (make-mir-value :id id :representation representation :block block :position position)
              (mir-function-values function))
    id))

(defun mir-analysis (function name compute)
  "Cache an analysis at the current revision; COMPUTE receives FUNCTION."
  (let ((entry (gethash name (mir-function-analyses function))))
    (if (and entry (= (car entry) (mir-function-revision function))) (cdr entry)
        (let ((result (funcall compute function)))
          (setf (gethash name (mir-function-analyses function))
                (cons (mir-function-revision function) result))
          result))))

(defun mir-unit-analysis (unit name compute)
  "Cache an analysis against load-time entries and every function revision."
  (let* ((revisions (cons (coerce (mir-unit-load-time-functions unit) 'list)
                           (loop for function across (hir-vector (mir-unit-functions unit))
                                collect (cons function (mir-function-revision function)))))
         (entry (gethash name (mir-unit-analyses unit))))
    (if (and entry (equal (car entry) revisions)) (cdr entry)
        (let ((result (funcall compute unit)))
          (setf (gethash name (mir-unit-analyses unit)) (cons revisions result))
          result))))

(defun mir-function-signature (function)
  "Snapshot entry and capture layout fields independently of mutable vectors."
  (list (mir-function-required function) (mir-function-optional function)
        (mir-function-rest function) (mir-function-key-p function)
        (copy-seq (mir-function-keys function)) (mir-function-allow-other-keys function)
        (copy-seq (mir-function-captures function)) (mir-function-capture-cells function)
        (copy-seq (mir-function-capture-functions function))
        (mir-function-internal-prefix function) (mir-function-argument-cells function)))

(defun mir-run-pass (unit function transform &key preserves)
  "Rewrite one body while preserving function and load-time entry layouts."
  (let ((load-time-functions (copy-seq (mir-unit-load-time-functions unit)))
        (signatures (map 'simple-vector
                         (lambda (entry) (cons entry (mir-function-signature entry)))
                         (hir-vector (mir-unit-functions unit)))))
    (incf (mir-function-revision function))
    (let ((remove nil))
      (maphash (lambda (name entry)
                 (if (member name preserves)
                     (setf (car entry) (mir-function-revision function))
                     (push name remove)))
               (mir-function-analyses function))
      (dolist (name remove) (remhash name (mir-function-analyses function))))
    (funcall transform function)
    (unless (equalp load-time-functions (mir-unit-load-time-functions unit))
      (mir-fail "MIR load-time entry changes require a unit pass"))
    (unless (= (length signatures) (hir-buffer-count (mir-unit-functions unit)))
      (mir-fail "MIR function membership changes require a unit pass"))
    (loop for saved across signatures for entry across (hir-vector (mir-unit-functions unit))
          do (unless (eq (car saved) entry) (mir-fail "MIR function replacement requires a unit pass"))
             (mir-verify-function-layout unit entry)
             (unless (equalp (cdr saved) (mir-function-signature entry))
               (mir-fail "MIR entry or capture layout changes require a unit pass")))
    (mir-verify-load-time-functions unit)
    (verify-mir-function unit function)
    (mir-verify-private-entries unit)
    function))

(defun mir-run-unit-pass (unit transform)
  "Invalidate the whole unit before a coordinated signature and caller rewrite."
  (loop for function across (hir-vector (mir-unit-functions unit))
        do (incf (mir-function-revision function)) (clrhash (mir-function-analyses function)))
  (clrhash (mir-unit-analyses unit))
  (funcall transform unit)
  (verify-mir unit)
  unit)
