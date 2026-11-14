(in-package #:kiln.compiler)

;;; The value domain and declaration proofs are shared with the HIR pipeline.
;;; Only the transfer of facts belongs to an IR: MIR follows SSA edges rather
;;; than reimplementing the evaluation order of tree-shaped control forms.
(defun mir-type-join (old new)
  (cond ((eq old :unseen) new)
        ((eq new :unseen) old)
        (t (hir-type-join old new))))

(defun mir-compute-types (function)
  "Infer primary-value types. :UNSEEN is solver bottom; T is unknown."
  (let* ((types (make-array (hir-buffer-count (mir-function-values function))
                            :initial-element :unseen))
         (blocks (hir-vector (mir-function-blocks function)))
         (reachable (mir-control-flow function))
         (changed t))
    ;; Transfers only copy facts or introduce constants. Interval endpoints
    ;; therefore come from a finite set; arithmetic will require widening.
    (labels ((merge-type (id type)
               (let ((joined (mir-type-join (svref types id) type)))
                 (unless (equal joined (svref types id))
                   (setf (svref types id) joined changed t))))
             (transfer (instruction)
               (let ((args (mir-instruction-operands instruction)))
                 (case (mir-instruction-kind instruction)
                   (0 (hir-constant-type (mir-instruction-data instruction)))
                   ((4 5) 'function)
                   ;; A bundle carries only a primary-value fact here. Unknown
                   ;; calls include the zero-values case, whose primary is NIL.
                   ((3 9 10) (svref types (svref args 0)))
                   (otherwise t)))))
      (loop while changed do
        (setf changed nil)
        (loop for block across blocks when (logbitp (mir-block-id block) reachable) do
          (loop for id across (hir-vector (mir-block-instructions block))
                for instruction = (mir-at (mir-function-instructions function) id)
                for result = (mir-instruction-result instruction)
                when result do (merge-type result (transfer instruction)))
          (loop for edge across (mir-terminator-edges (mir-block-terminator block)) do
            (loop for parameter across (mir-block-parameters (svref blocks (mir-edge-target edge)))
                  for argument across (mir-edge-arguments edge)
                  do (merge-type parameter (svref types argument)))))))
    ;; Unreachable definitions and cyclic facts with no seed prove nothing.
    (dotimes (id (length types))
      (when (eq (svref types id) :unseen) (setf (svref types id) t)))
    types))

(defun mir-infer-types (function)
  "Return revision-cached types indexed by SSA value ID."
  (mir-analysis function :types #'mir-compute-types))

(defun mir-check-proven-p (instruction types)
  (and (= (mir-instruction-kind instruction) 11)
       (hir-declaration-proven-p
        (svref types (svref (mir-instruction-operands instruction) 0))
        (mir-instruction-data instruction))))
