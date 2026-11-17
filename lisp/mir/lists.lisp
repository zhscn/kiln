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
    (loop for block across (hir-buffer-view (mir-function-blocks function))
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
        (loop for id across (hir-buffer-view (mir-block-instructions block))
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
      (loop for id across (hir-buffer-view rebuilt) for position from 0
            for result = (mir-instruction-result (mir-at instructions id))
            when result do (setf (mir-value-position (mir-at (mir-function-values function) result)) position))
      (setf (mir-block-instructions block) rebuilt)))
  function)

(defun mir-expand-list-calls (unit &key (cell-budget 16))
  (let ((transformations nil))
    (loop for function across (hir-buffer-view (mir-unit-functions unit)) do
      (let ((remaining cell-budget) (selected nil) (reachable (mir-reachable-blocks function)))
        (loop for block across (hir-buffer-view (mir-function-blocks function))
              when (logbitp (mir-block-id block) reachable) do
          (loop for id across (hir-buffer-view (mir-block-instructions block))
                for cells = (mir-short-list-cells (mir-at (mir-function-instructions function) id))
                when (and cells (<= cells remaining)) do
                  (decf remaining cells) (push (cons id cells) selected)))
        (when selected
          (push (cons function (lambda (function) (mir-expand-list-function function selected))) transformations))))
    (mir-run-passes unit (nreverse transformations)))
  unit)

(defun mir-sequence-call-helper (instruction definitions)
  "Select a two-argument search when its complete keyword contract is known."
  (let ((name (mir-instruction-data instruction))
        (args (mir-instruction-operands instruction)))
    (when (and (= (mir-instruction-kind instruction) 6) (member name '(member assoc))
               (member (length args) '(2 4))
               (hir-policy-optimize-p (mir-instruction-policy instruction))
               (not (mir-instruction-notinline instruction)))
      (labels ((definition (index)
                 (svref definitions (mir-primary-origin (svref args index) definitions))))
        (let ((test (if (= (length args) 2) 'eql
                        (let ((key (definition 2)) (value (definition 3)))
                          (and key (= (mir-instruction-kind key) 0)
                               (eq (mir-instruction-data key) :test)
                               value (member (mir-instruction-kind value) '(0 4))
                               (mir-instruction-data value))))))
          (cdr (assoc (list name test)
                      '(((member eq) . kiln.kernel::%member-eq)
                        ((member eql) . kiln.kernel::%member-eql)
                        ((assoc eq) . kiln.kernel::%assoc-eq)
                        ((assoc eql) . kiln.kernel::%assoc-eql)) :test #'equal)))))))

(defun mir-specialize-sequence-calls (unit)
  (let ((transformations nil))
    (loop for function across (hir-buffer-view (mir-unit-functions unit)) do
      (let ((definitions (mir-value-definitions function))
            (reachable (mir-reachable-blocks function)) (selected nil))
        (loop for block across (hir-buffer-view (mir-function-blocks function))
              when (logbitp (mir-block-id block) reachable) do
          (loop for id across (hir-buffer-view (mir-block-instructions block))
                for instruction = (mir-at (mir-function-instructions function) id)
                for helper = (mir-sequence-call-helper instruction definitions)
                when helper do (push (cons instruction helper) selected)))
        (when selected
          (push (cons function
            (lambda (function)
              (declare (ignore function))
              ;; Operand producers remain in place, including evaluation of the test.
              (dolist (entry selected)
                (setf (mir-instruction-data (car entry)) (cdr entry)
                      (mir-instruction-operands (car entry))
                      (subseq (mir-instruction-operands (car entry)) 0 2))))) transformations))))
    (mir-run-passes unit (nreverse transformations) :changes '(:instructions)))
  unit)

(defun mir-value-call-plan (instruction definitions)
  "Simplify constant comparisons and APPEND's fixed argument contract."
  (when (and (= (mir-instruction-kind instruction) 6)
             (hir-policy-optimize-p (mir-instruction-policy instruction))
             (not (mir-instruction-notinline instruction)))
    (let* ((name (mir-instruction-data instruction))
           (args (mir-instruction-operands instruction)) (count (length args)))
      (labels ((definition (id) (svref definitions (mir-primary-origin id definitions)))
               (nil-value-p (id)
                 (let ((definition (definition id)))
                   (and definition (= (mir-instruction-kind definition) 0)
                        (null (mir-instruction-data definition))))))
        (cond ((and (eq name 'eql) (= count 2)
                    (loop for id across args for definition = (definition id)
                          thereis (and definition (= (mir-instruction-kind definition) 0)
                                       (eq-comparable-value-p (mir-instruction-data definition)))))
               (cons 'eq args))
              ((eq name 'append)
               ;; The last NIL forces a copy of preceding lists, so retain it.
               (let* ((kept (loop for id across args for index from 0
                                  when (or (= index (1- count)) (not (nil-value-p id))) collect id))
                      (length (length kept))
                      (target (case length (0 'list) (1 'identity) (2 'kiln.kernel::append-2) (otherwise 'append))))
                 (unless (and (eq target name) (= length count))
                   (cons target (coerce kept 'simple-vector))))))))))

(defun mir-specialize-value-calls (unit)
  (let ((transformations nil))
    (loop for function across (hir-buffer-view (mir-unit-functions unit)) do
      (let ((definitions (mir-value-definitions function))
            (reachable (mir-reachable-blocks function)) (selected nil))
        (loop for block across (hir-buffer-view (mir-function-blocks function))
              when (logbitp (mir-block-id block) reachable) do
          (loop for id across (hir-buffer-view (mir-block-instructions block))
                for instruction = (mir-at (mir-function-instructions function) id)
                for plan = (mir-value-call-plan instruction definitions)
                when plan do (push (list instruction (car plan) (cdr plan)) selected)))
        (when selected
          (push (cons function
            (lambda (function)
              (declare (ignore function))
              (dolist (entry selected)
                (setf (mir-instruction-data (car entry)) (cadr entry)
                      (mir-instruction-operands (car entry)) (third entry))))) transformations))))
    (mir-run-passes unit (nreverse transformations) :changes '(:instructions)))
  unit)
