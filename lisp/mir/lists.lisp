(in-package #:kiln.compiler)

(defun mir-short-list-cells (instruction)
  (when (and (= (mir-instruction-kind instruction) 6)
             (member (mir-instruction-data instruction) '(list list*))
             (hir-policy-optimize-p (mir-instruction-policy instruction))
             (not (mir-instruction-notinline instruction)))
    (let ((cells (- (length (mir-instruction-operands instruction))
                    (if (eq (mir-instruction-data instruction) 'list*) 1 0))))
      (when (<= 1 cells 8) cells))))

(defun mir-expand-list-function (function selected)
  (let ((instructions (mir-function-instructions function)))
    (loop for block across (hir-vector (mir-function-blocks function))
          for rebuilt = (make-hir-buffer) do
      (labels ((emit (template kind representation args data)
                 (let* ((id (hir-buffer-count instructions))
                        (value (mir-add-value function representation (mir-block-id block)
                                              (hir-buffer-count rebuilt)))
                        (instruction (copy-mir-instruction template)))
                   (setf (mir-instruction-id instruction) id
                         (mir-instruction-kind instruction) kind
                         (mir-instruction-operands instruction) args
                         (mir-instruction-result instruction) value
                         (mir-instruction-data instruction) data
                         (mir-instruction-effects instruction) (svref *mir-instruction-effects* kind))
                   (hir-push instruction instructions) (hir-push id rebuilt) value)))
        (loop for id across (hir-vector (mir-block-instructions block))
              for instruction = (mir-at instructions id)
              for plan = (assoc id selected) do
          (when plan
            (let* ((args (mir-instruction-operands instruction)) (cells (cdr plan))
                   (tail (if (eq (mir-instruction-data instruction) 'list*)
                             (svref args cells) (emit instruction 0 :obj #() nil))))
              ;; Operands are already evaluated. Allocate from the tail while
              ;; keeping the original head bundle definition for its consumers.
              (loop for index downfrom (1- cells) above 0
                    do (setf tail (emit instruction 10 :obj
                                        (vector (emit instruction 6 :bundle
                                                      (vector (svref args index) tail) 'cons)) nil)))
              (setf (mir-instruction-data instruction) 'cons
                    (mir-instruction-operands instruction) (vector (svref args 0) tail))))
          (hir-push id rebuilt)))
      (loop for id across (hir-vector rebuilt) for position from 0
            for result = (mir-instruction-result (mir-at instructions id))
            when result do (setf (mir-value-position (mir-at (mir-function-values function) result)) position))
      (setf (mir-block-instructions block) rebuilt)))
  function)

(defun mir-expand-list-calls (unit &key (cell-budget 16))
  (loop for function across (hir-vector (mir-unit-functions unit)) do
    (let ((remaining cell-budget) (selected nil) (reachable (mir-reachable-blocks function)))
      (loop for block across (hir-vector (mir-function-blocks function))
            when (logbitp (mir-block-id block) reachable) do
        (loop for id across (hir-vector (mir-block-instructions block))
              for cells = (mir-short-list-cells (mir-at (mir-function-instructions function) id))
              when (and cells (<= cells remaining)) do
                (decf remaining cells) (push (cons id cells) selected)))
      (when selected
        (mir-run-pass unit function (lambda (function) (mir-expand-list-function function selected))))))
  unit)
