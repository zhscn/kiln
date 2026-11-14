(in-package #:kiln.compiler)

(defun mir-type-predicate-folds (function unit)
  "Collect proven unary predicates without changing their argument evaluations."
  (let ((types (mir-infer-types function unit)) (folds nil)
        (reachable (mir-reachable-blocks function)))
    (loop for block across (hir-vector (mir-function-blocks function))
          when (logbitp (mir-block-id block) reachable)
            do (loop for id across (hir-vector (mir-block-instructions block))
                     for instruction = (mir-at (mir-function-instructions function) id)
                     for operands = (mir-instruction-operands instruction)
                     when (and (= (mir-instruction-kind instruction) 6) (= (length operands) 1)
                               (hir-policy-optimize-p (mir-instruction-policy instruction))
                               (not (mir-instruction-notinline instruction)))
                       do (multiple-value-bind (truth known)
                              (hir-type-predicate (mir-instruction-data instruction) (svref types (svref operands 0)))
                            (when known (push (cons id truth) folds)))))
    folds))

(defun mir-replace-type-predicates (function folds)
  (let ((instructions (mir-function-instructions function)))
    (loop for block across (hir-vector (mir-function-blocks function))
          for rebuilt = (make-hir-buffer)
          do (loop for id across (hir-vector (mir-block-instructions block))
                   for instruction = (mir-at instructions id) for fold = (assoc id folds)
                   do (when fold
                        (let* ((constant (hir-buffer-count instructions))
                               (value (mir-add-value function :obj (mir-block-id block) (hir-buffer-count rebuilt))))
                          (hir-push (make-mir-instruction :id constant :kind 0 :result value :data (cdr fold)
                                                         :source (mir-instruction-source instruction)
                                                         :origin (mir-instruction-origin instruction)
                                                         :policy (mir-instruction-policy instruction)) instructions)
                          (hir-push constant rebuilt)
                          (setf (mir-instruction-kind instruction) 9
                                (mir-instruction-operands instruction) (vector value)
                                (mir-instruction-data instruction) nil
                                (mir-instruction-effects instruction) (svref *mir-instruction-effects* 9))))
                      (hir-push id rebuilt))
             (loop for id across (hir-vector rebuilt) for position from 0
                   for result = (mir-instruction-result (mir-at instructions id))
                   when result do (setf (mir-value-position (mir-at (mir-function-values function) result)) position))
             (setf (mir-block-instructions block) rebuilt)))
  function)

(defun mir-fold-type-predicates (unit)
  ;; A callee's folded result can prove a caller predicate. Recompute unit
  ;; summaries after each revision and stop once no predicate call changes.
  (loop with changed = t while changed
        do (setf changed nil)
           (loop for function across (hir-vector (mir-unit-functions unit))
                 for folds = (mir-type-predicate-folds function unit)
                 when folds do (mir-run-pass unit function
                                 (lambda (function) (mir-replace-type-predicates function folds)))
                               (setf changed t)))
  unit)
