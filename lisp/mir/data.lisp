(in-package #:kiln.compiler)

(define-condition mir-error (kiln-compile-error) ())
(define-condition mir-unsupported (mir-error) ())

(defun mir-fail (control &rest args)
  (error 'mir-error :message (apply #'format nil control args)))

(defstruct mir-values-declaration (required #()) (optional #()) (rest t))

(defstruct mir-unit (revision 0 :type fixnum) (load-time-functions #()) (functions (make-hir-buffer)) (analyses (make-hash-table :test 'eq)))
(defstruct mir-function
  (id 0 :type fixnum) name source (policy 1023) (internal-prefix 0) (argument-cells 0) (required 0) (optional 0) (rest nil) (key-p nil) (keys #()) (allow-other-keys nil) (bindings #()) (binding-cells 0) (captures #()) (capture-cells 0) (capture-functions #())
  (blocks (make-hir-buffer)) (instructions (make-hir-buffer)) (values (make-hir-buffer))
  (revision 0 :type fixnum) (analyses (make-hash-table :test 'eq)) debug-name)
(defun mir-function-positional-count (function)
  (+ (mir-function-required function) (mir-function-optional function)))

(defun mir-function-tail-p (function)
  (or (mir-function-rest function) (mir-function-key-p function)))

(defun mir-function-maximum (function)
  (unless (mir-function-tail-p function) (mir-function-positional-count function)))

(defstruct mir-block (id 0 :type fixnum) (parameters #()) (instructions (make-hir-buffer)) terminator)
(defstruct mir-value (id 0 :type fixnum) (representation :obj) (block 0 :type fixnum) (position -1 :type fixnum))
(defstruct mir-instruction (id 0 :type fixnum) (kind 0 :type fixnum) (operands #()) result data source origin (notinline nil) (policy 1023) (effects 0))
(defun mir-call-prefix-count (instruction)
  (if (and (= (mir-instruction-kind instruction) 15) (integerp (mir-instruction-data instruction)))
      (mir-instruction-data instruction) 0))

(defstruct mir-edge (target 0 :type fixnum) (arguments #()))
;;; Terminators: jump, branch, return, trap, throw, region-entry, continue-unwind, exit-to.
(defstruct mir-terminator (kind 0 :type fixnum) (operands #()) (edges #()) region source origin (policy 1023))

;;; Instruction kinds: constant, argument, global-read, global-write,
;;; global-function, function, global-call, call, primop, single, primary,
;;; declaration-check, argument-count, arity-check, value-ref, multiple-value-call,
;;; argument-present, rest-list, argument-error, cell, cell-read, cell-write,
;;; capture, closure, closure-set, unbound-cell, load-time-value, special-bind, special-unbind, progv-enter, catch-enter, landed-values, protect-enter, cleanup-landing, block-enter, tagbody-enter, go-landing, value-present, values-tail, values-asserted, debug-binding.
(defparameter *mir-instruction-effects* #(0 0 33 34 33 8 127 127 127 56 56 127 0 32 56 127 0 56 127 56 1 2 1 56 2 0 1 7 7 63 7 57 7 4 7 7 7 0 127 0 0))
;;; Effects: heap/global read/write, dynamic environment, allocation, GC,
;;; possible exit, unknown call. No operation is deleted from this summary alone.

(defun mir-active-binding-id (binding)
  (if (consp binding) (car binding) binding))

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

(defstruct mir-edit-scope unit function initial-functions)
(defvar *mir-edit-scopes* nil)

(defun mir-unit-editing-p (unit)
  (find unit *mir-edit-scopes* :key #'mir-edit-scope-unit :test #'eq))

(defun mir-function-editing-p (function)
  (some (lambda (scope)
          (or (eq function (mir-edit-scope-function scope))
              (and (eq :all (mir-edit-scope-function scope))
                   (or (find function (mir-edit-scope-initial-functions scope) :test #'eq)
                       (let ((functions (mir-unit-functions (mir-edit-scope-unit scope))))
                         (loop for index below (hir-buffer-count functions)
                               thereis (eq function (svref (hir-buffer-data functions) index))))))))
        *mir-edit-scopes*))
(defvar *mir-edit-analysis-cache* nil)

(defun mir-edit-analysis (owner name compute)
  "Share dependencies within one read query, never across edits in a callback."
  (let* ((root (null *mir-edit-analysis-cache*))
         (*mir-edit-analysis-cache* (or *mir-edit-analysis-cache* (make-hash-table :test 'eq)))
         (*hir-buffer-views* (if root (make-hash-table :test 'eq) *hir-buffer-views*))
         (entries (or (gethash owner *mir-edit-analysis-cache*)
                      (setf (gethash owner *mir-edit-analysis-cache*) (make-hash-table :test 'eq)))))
    (multiple-value-bind (result present) (gethash name entries)
      (if present result (setf (gethash name entries) (with-compilation-phase (:mir-analysis) (funcall compute owner)))))))

(defun mir-analysis-buffer-views (analyses revision)
  (let ((entry (gethash :buffer-views analyses)))
    (if (and entry (= (car entry) revision)) (cdr entry)
        (let ((views (make-hash-table :test 'eq)))
          (setf (gethash :buffer-views analyses) (cons revision views))
          views))))

(defun mir-analysis (function name compute)
  "Cache an analysis at the current revision; COMPUTE receives FUNCTION."
  (when (mir-function-editing-p function)
    (return-from mir-analysis (mir-edit-analysis function name compute)))
  (let ((entry (gethash name (mir-function-analyses function))))
    (if (and entry (= (car entry) (mir-function-revision function))) (cdr entry)
        (let* ((*hir-buffer-views*
                 (or *hir-buffer-views*
                     (mir-analysis-buffer-views (mir-function-analyses function) (mir-function-revision function))))
               (result (with-compilation-phase (:mir-analysis) (funcall compute function))))
          (setf (gethash name (mir-function-analyses function))
                (cons (mir-function-revision function) result))
          result))))

(defun mir-unit-analysis (unit name compute)
  "Cache against the unit epoch advanced before every graph rewrite."
  (when (mir-unit-editing-p unit)
    (return-from mir-unit-analysis (mir-edit-analysis unit name compute)))
  (let ((entry (gethash name (mir-unit-analyses unit))))
    (if (and entry (= (car entry) (mir-unit-revision unit))) (cdr entry)
        (let* ((*hir-buffer-views*
                 (or *hir-buffer-views*
                     (mir-analysis-buffer-views (mir-unit-analyses unit) (mir-unit-revision unit))))
               (result (with-compilation-phase (:mir-analysis) (funcall compute unit))))
          (setf (gethash name (mir-unit-analyses unit))
                (cons (mir-unit-revision unit) result))
          result))))

(defvar *mir-verification-identities* nil)
