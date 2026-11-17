(in-package #:kiln.compiler)

(defvar *mir-check-pass-contracts* nil)

(defparameter *mir-change-kinds* '(:instructions :values :control-flow :bindings))

(defun mir-pass-changes (changes)
  (cond ((eq changes :all) :all)
        ((and (listp changes) changes
              (every (lambda (kind) (member kind *mir-change-kinds*)) changes)) changes)
        (t (mir-fail "Invalid MIR change declaration ~S" changes))))

(defun mir-invalidate-function (function changes)
  "Retain only registered facts whose inputs cannot change in this edit."
  (incf (mir-function-revision function))
  (if (or (eq changes :all) (member :control-flow changes))
      (clrhash (mir-function-analyses function))
      (let ((remove nil))
        (maphash (lambda (name analysis)
                   ;; Only these registered facts depend solely on the CFG.
                   (case name
                     ((:reachable :control-flow :cyclic :loop-polls)
                      (setf (car analysis) (mir-function-revision function)))
                     (otherwise (push name remove))))
                 (mir-function-analyses function))
        (dolist (name remove) (remhash name (mir-function-analyses function))))))

(defun mir-invalidate-unit (unit)
  (incf (mir-unit-revision unit))
  (clrhash (mir-unit-analyses unit))
  (loop for function across (hir-vector (mir-unit-functions unit))
        do (mir-invalidate-function function :all)))

(defun mir-function-signature (function)
  "Snapshot entry and capture layout fields independently of mutable vectors."
  (list (mir-function-id function) (mir-function-required function) (mir-function-optional function)
        (mir-function-rest function) (mir-function-key-p function)
        (copy-seq (mir-function-keys function)) (mir-function-allow-other-keys function)
        (copy-seq (mir-function-captures function)) (mir-function-capture-cells function)
        (copy-seq (mir-function-capture-functions function))
        (mir-function-internal-prefix function) (mir-function-argument-cells function)))

(defun mir-pass-body-state (function identities)
  "Snapshot owned graph fields for optional pass-contract checking."
  (let ((seen (make-hash-table :test 'eq)))
    (labels ((identity-token (object)
               (or (gethash object identities)
                   (setf (gethash object identities) (gensym "NODE"))))
             (data (object)
               (if (or (consp object) (typep object 'simple-vector))
                   (let ((token (identity-token object)))
                     (if (gethash object seen) (list :ref token)
                         (progn
                           (setf (gethash object seen) t)
                           (if (consp object)
                               (list :cons token (data (car object)) (data (cdr object)))
                               (list :vector token (map 'list #'data object))))))
                   (identity-token object)))
             (buffer (buffer)
               (list (identity-token buffer) (identity-token (hir-buffer-data buffer))
                     (hir-buffer-count buffer)))
             (instructions ()
               (list (buffer (mir-function-instructions function))
                     (loop for instruction across (hir-vector (mir-function-instructions function)) collect
                       (list (identity-token instruction) (mir-instruction-id instruction)
                             (mir-instruction-kind instruction) (data (mir-instruction-operands instruction))
                             (mir-instruction-result instruction)
                             ;; Constant objects belong to the language, not the MIR graph.
                             (if (zerop (mir-instruction-kind instruction))
                                 (identity-token (mir-instruction-data instruction))
                                 (data (mir-instruction-data instruction)))
                             (mir-instruction-effects instruction) (mir-instruction-policy instruction)
                             (mir-instruction-notinline instruction) (identity-token (mir-instruction-source instruction))
                             (identity-token (mir-instruction-origin instruction))))
                     (loop for block across (hir-vector (mir-function-blocks function))
                           for term = (mir-block-terminator block) collect
                       (list (buffer (mir-block-instructions block))
                             (coerce (hir-vector (mir-block-instructions block)) 'list)
                             (data (mir-terminator-operands term)) (mir-terminator-policy term)
                             (identity-token (mir-terminator-source term)) (identity-token (mir-terminator-origin term))))))
             (values-state ()
               (list (buffer (mir-function-values function))
                     (loop for value across (hir-vector (mir-function-values function)) collect
                       (list (identity-token value) (mir-value-id value) (mir-value-representation value)
                             (mir-value-block value) (mir-value-position value)))
                     (loop for block across (hir-vector (mir-function-blocks function)) collect
                       (list (data (mir-block-parameters block))
                             (loop for edge across (mir-terminator-edges (mir-block-terminator block))
                                   collect (data (mir-edge-arguments edge)))))))
             (control-flow ()
               (list (buffer (mir-function-blocks function))
                     (loop for block across (hir-vector (mir-function-blocks function))
                           for term = (mir-block-terminator block) collect
                       (list (identity-token block) (mir-block-id block) (identity-token term)
                             (mir-terminator-kind term) (data (mir-terminator-region term))
                             (loop for edge across (mir-terminator-edges term) collect
                               (list (identity-token edge) (mir-edge-target edge))))))))
      (list (cons :instructions (instructions)) (cons :values (values-state))
            (cons :control-flow (control-flow))
            (cons :bindings (list (mir-function-id function) (data (mir-function-bindings function)) (mir-function-binding-cells function)
                                  (mir-function-policy function) (identity-token (mir-function-name function))
                                  (identity-token (mir-function-source function))
                                  (identity-token (mir-function-debug-name function))))))))

(defun mir-apply-body-edit (unit function transform changes)
  (let* ((identities (and *mir-check-pass-contracts* (make-hash-table :test 'eq)))
         (before (when identities
                   (loop for entry across (hir-vector (mir-unit-functions unit))
                         collect (cons entry (mir-pass-body-state entry identities))))))
    (incf (mir-unit-revision unit))
    (mir-invalidate-function function changes)
    (let ((*mir-edit-scopes* (cons (make-mir-edit-scope :unit unit :function function) *mir-edit-scopes*))
          (*mir-edit-analysis-cache* nil) (*hir-buffer-views* nil))
      (funcall transform function))
    ;; A callback can run an explicit verifier or compute current graph facts.
    ;; None of its intermediate results may escape into the next stable revision.
    (incf (mir-unit-revision unit))
    (mir-invalidate-function function changes)
    (dolist (saved before)
      (let* ((entry (car saved)) (after (mir-pass-body-state entry identities)))
        (dolist (state (cdr saved))
          (unless (or (and (eq entry function) (or (eq changes :all) (member (car state) changes)))
                      (equal (cdr state) (cdr (assoc (car state) after))))
            (mir-fail "MIR pass changed undeclared ~S in function ~D" (car state) (mir-function-id entry))))))))

(defun mir-run-passes (unit transformations &key (changes :all))
  "Apply (FUNCTION . TRANSFORM) body rewrites, then verify their shared contracts."
  (when (mir-unit-editing-p unit) (mir-fail "Nested MIR edits require a separate unit"))
  (setf changes (mir-pass-changes changes))
  (unless transformations (return-from mir-run-passes unit))
  (let ((load-time-functions (copy-seq (mir-unit-load-time-functions unit)))
        (signatures (map 'simple-vector
                         (lambda (entry) (cons entry (mir-function-signature entry)))
                         (hir-vector (mir-unit-functions unit))))
        (changed (make-hash-table :test 'eq)))
    (dolist (entry transformations)
      (let ((function (car entry)))
        (unless (eq function (mir-at (mir-unit-functions unit) (mir-function-id function)))
          (mir-fail "MIR body pass requires a member function"))
        (setf (gethash function changed) t)
        (mir-apply-body-edit unit function (cdr entry) changes)))
    (unless (equalp load-time-functions (mir-unit-load-time-functions unit))
      (mir-fail "MIR load-time entry changes require a unit pass"))
    (unless (= (length signatures) (hir-buffer-count (mir-unit-functions unit)))
      (mir-fail "MIR function membership changes require a unit pass"))
    (let ((*mir-verification-identities* (make-hash-table :test 'eq))
          (*hir-buffer-views* (make-hash-table :test 'eq)))
      (loop for saved across signatures for entry across (hir-vector (mir-unit-functions unit))
            do (unless (eq (car saved) entry) (mir-fail "MIR function replacement requires a unit pass"))
               (mir-verify-function-layout unit entry)
               (unless (equalp (cdr saved) (mir-function-signature entry))
                 (mir-fail "MIR function identity, entry or capture changes require a unit pass")))
      (mir-verify-load-time-functions unit)
      ;; Iterate the unit's order, not the hash table, for deterministic diagnostics.
      (loop for function across (hir-vector (mir-unit-functions unit))
            when (gethash function changed) do (verify-mir-function unit function))
      (mir-verify-private-entries unit))
    unit))

(defun mir-run-pass (unit function transform &key (changes :all))
  "Rewrite one body while preserving function and load-time entry layouts."
  (mir-run-passes unit (list (cons function transform)) :changes changes)
  function)

(defun mir-run-unit-pass (unit transform)
  "Invalidate the whole unit before a coordinated signature and caller rewrite."
  (when (mir-unit-editing-p unit) (mir-fail "Nested MIR edits require a separate unit"))
  (mir-invalidate-unit unit)
  (let ((*mir-edit-scopes*
          (cons (make-mir-edit-scope :unit unit :function :all
                                    :initial-functions (hir-vector (mir-unit-functions unit)))
                *mir-edit-scopes*))
        (*mir-edit-analysis-cache* nil) (*hir-buffer-views* nil))
    (funcall transform unit))
  (mir-invalidate-unit unit)
  (verify-mir unit)
  unit)
