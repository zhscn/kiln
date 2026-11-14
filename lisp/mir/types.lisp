(in-package #:kiln.compiler)

;;; The value domain and declaration proofs are shared with the HIR pipeline.
;;; Only the transfer of facts belongs to an IR: MIR follows SSA edges rather
;;; than reimplementing the evaluation order of tree-shaped control forms.
(defun mir-type-join (old new)
  (cond ((eq old :unseen) new)
        ((eq new :unseen) old)
        (t (hir-type-join old new))))

(defun mir-value-definitions (function)
  "Map SSA value IDs to defining instructions; block parameters map to NIL."
  (mir-analysis function :definitions
    (lambda (function)
      (let ((definitions (make-array (hir-buffer-count (mir-function-values function))
                                     :initial-element nil)))
        (loop for instruction across (hir-vector (mir-function-instructions function))
              for result = (mir-instruction-result instruction)
              when result do (setf (svref definitions result) instruction))
        definitions))))

(defun mir-primary-origin (id definitions)
  "Follow operations that preserve a value's primary identity."
  (loop for instruction = (svref definitions id)
        while (and instruction (member (mir-instruction-kind instruction) '(9 10 11 39)))
        do (setf id (svref (mir-instruction-operands instruction) 0))
        finally (return id)))

(defun mir-edge-type (terminator positive argument type definitions types)
  "Refine only the actual SSA value tested on this conditional edge."
  (unless (= (mir-terminator-kind terminator) 1) (return-from mir-edge-type type))
  (let* ((test (mir-primary-origin (svref (mir-terminator-operands terminator) 0) definitions))
         (source (mir-primary-origin argument definitions))
         (instruction (svref definitions test)))
    (cond
      ((and (= source test) (not positive)) (hir-type-intersection type 'null))
      ((and instruction (= (mir-instruction-kind instruction) 6)
            (= (length (mir-instruction-operands instruction)) 1)
            (= source (mir-primary-origin (svref (mir-instruction-operands instruction) 0) definitions)))
       (let* ((name (mir-instruction-data instruction))
              (predicate (and (symbolp name) (eq (symbol-package name) (find-package :cl))
                              (hir-predicate-type name))))
         (if (and predicate positive) (hir-type-intersection type predicate) type)))
      ((and instruction (= (mir-instruction-kind instruction) 6)
            (= (length (mir-instruction-operands instruction)) 2)
            (member (mir-instruction-data instruction) '(< <= > >= =)))
       (let* ((name (mir-instruction-data instruction))
              (arguments (mir-instruction-operands instruction))
              (left (svref arguments 0)) (right (svref arguments 1)))
         (cond ((= source (mir-primary-origin left definitions))
                (inferred-comparison-range name type (svref types right) positive))
               ((= source (mir-primary-origin right definitions))
                (inferred-comparison-range
                 (case name (< '>) (<= '>=) (> '<) (>= '<=) (= '=))
                 type (svref types left) positive))
               (t type))))
      (t type))))

(defun mir-cell-read-type (bits cells)
  (when (logbitp 0 bits) (return-from mir-cell-read-type t))
  (let ((result :unseen))
    (dotimes (index (length cells) result)
      (when (logbitp (1+ index) bits) (setf result (mir-type-join result (svref cells index)))))))

(defun mir-compute-types (function &key summaries value-summaries functions inputs captures cell-types cell-points (finalize t))
  "Infer primary-value types. :UNSEEN is solver bottom; T is unknown."
  (let* ((types (make-array (hir-buffer-count (mir-function-values function))
                            :initial-element :unseen))
         (packets (make-array (length types) :initial-element :unseen))
         (packet-changes (make-array (length types) :initial-element nil))
         (blocks (hir-vector (mir-function-blocks function)))
         (reachable (mir-reachable-blocks function))
         (definitions (mir-value-definitions function))
         (changes (make-array (length types) :initial-element 0))
         (changed t))
    ;; A loop can keep expanding an integer interval. After two expansions
    ;; of a value, widen to INTEGER; later transfers cannot narrow it again.
    (labels ((merge-type (id type)
               (let ((joined (mir-type-join (svref types id) type)))
                 (when (and (hir-range-p (svref types id)) (hir-range-p joined)
                            (not (equal joined (svref types id))))
                   (incf (svref changes id))
                   (when (>= (svref changes id) 2) (setf joined 'integer)))
                 (unless (equal joined (svref types id))
                   (setf (svref types id) joined changed t))))
             (merge-packet (id packet)
               (unless (svref packet-changes id)
                 (setf (svref packet-changes id) (make-array +mir-values-prefix-limit+ :initial-element 0)))
               (let ((joined (mir-join-values (svref packets id) packet (svref packet-changes id))))
                 (unless (equalp joined (svref packets id))
                   (setf (svref packets id) joined changed t))))
             (transfer-packet (instruction)
               (let ((args (mir-instruction-operands instruction))
                     (result (mir-instruction-result instruction)))
                 (case (mir-instruction-kind instruction)
                   (8 (if (member (mir-instruction-data instruction) '(:make-simple-vector :make-string))
                          (mir-fixed-values (vector (svref types result)))
                          (mir-unknown-values (svref types result))))
                   (9 (mir-fixed-values (vector (svref types (svref args 0)))))
                   (39 (mir-asserted-values (svref packets (svref args 0)) (mir-instruction-data instruction)))
                   (11 (mir-check-values (svref packets (svref args 0)) (svref types result)))
                   (6 (let ((name (mir-instruction-data instruction)))
                        (cond ((eq name 'values)
                               (mir-fixed-values (map 'simple-vector (lambda (id) (svref types id)) args)))
                              ((and (mir-standard-call-p name) (mir-single-value-call-p name))
                               (mir-fixed-values (vector (svref types result))))
                              ((eq (svref types result) :unseen) :unseen)
                              (t (mir-unknown-values (svref types result))))))
                   ((7 15) (let ((target (and functions (svref functions (svref args 0)))))
                        (if (and value-summaries (integerp target)) (svref value-summaries target)
                            (if (eq (svref types result) :unseen) :unseen
                                (mir-unknown-values (svref types result))))))
                   (otherwise (mir-unknown-values (svref types result))))))
             (transfer (instruction)
               (let ((args (mir-instruction-operands instruction)))
                 (case (mir-instruction-kind instruction)
                   (0 (hir-constant-type (mir-instruction-data instruction)))
                   (1 (if (logbitp (mir-instruction-data instruction) (mir-function-argument-cells function)) t
                          (if inputs (svref inputs (mir-instruction-data instruction)) t)))
                   (8 (case (mir-instruction-data instruction)
                        (:make-simple-vector 'simple-vector) (:make-string :native-string) (otherwise t)))
                   ((4 5 23) 'function)
                   (22 (if captures (svref captures (mir-instruction-data instruction))
                           (if (svref (mir-function-capture-functions function) (mir-instruction-data instruction)) 'function t)))
                   (20 (if (and cell-types cell-points)
                           (mir-cell-read-type (svref cell-points (svref args 0)) cell-types) t))
                   ((16 37) 'boolean)
                   (38 'list)
                   (39 (let ((fact (mir-asserted-values (svref packets (svref args 0)) (mir-instruction-data instruction))))
                         (if (eq fact :unseen) :unseen (mir-values-ref-type fact 0))))
                   (17 'list)
                   ;; A bundle carries only a primary-value fact here. Unknown
                   ;; calls include the zero-values case, whose primary is NIL.
                   ((3 9 10) (svref types (svref args 0)))
                   (11 (let ((input (svref types (svref args 0))))
                         (if (eq input :unseen) :unseen
                             (hir-type-intersection input
                               (hir-declaration-type (mir-instruction-data instruction))))))
                   (6 (let ((name (mir-instruction-data instruction)))
                        ;; CL function semantics are stable. Image-defined
                        ;; globals need guards or dependency records first.
                        (if (mir-standard-call-p name)
                            (let ((inputs (map 'simple-vector (lambda (id) (svref types id)) args)))
                              (if (find :unseen inputs) :unseen
                                  (inferred-call-type name inputs)))
                            t)))
                   ((7 15) (let ((target (and functions (svref functions (svref args 0)))))
                        (cond ((eq target :unseen) :unseen)
                              ((and summaries (integerp target)) (svref summaries target))
                              (t t))))
                   (14 (if (zerop (mir-instruction-data instruction)) (svref types (svref args 0))
                           (mir-values-ref-type (svref packets (svref args 0))
                                                (mir-instruction-data instruction))))
                   (otherwise t)))))
      (loop while changed do
        (setf changed nil)
        (loop for block across blocks when (logbitp (mir-block-id block) reachable) do
          (loop for id across (hir-vector (mir-block-instructions block))
                for instruction = (mir-at (mir-function-instructions function) id)
                for result = (mir-instruction-result instruction)
                when result do (merge-type result (transfer instruction))
                               (when (eq (mir-value-representation (mir-at (mir-function-values function) result)) :bundle)
                                 (merge-packet result (transfer-packet instruction))))
          (loop for edge across (mir-terminator-edges (mir-block-terminator block))
                for index from 0 do
            (loop for parameter across (mir-block-parameters (svref blocks (mir-edge-target edge)))
                  for argument across (mir-edge-arguments edge)
                  for input = (svref types argument)
                  do (merge-type parameter
                       (if (eq input :unseen) :unseen
                           (mir-edge-type (mir-block-terminator block) (zerop index)
                                          argument input definitions types)))
                     (when (eq (mir-value-representation (mir-at (mir-function-values function) parameter)) :bundle)
                       (merge-packet parameter (svref packets argument))))))))
    ;; Unreachable definitions and cyclic facts with no seed prove nothing.
    (when finalize
      (dotimes (id (length types))
        (when (eq (svref types id) :unseen) (setf (svref types id) t))))
    (values types packets)))

(defun mir-infer-types (function &optional unit)
  "Return SSA types, using local call summaries when UNIT is supplied."
  (if unit
      (svref (mir-call-analysis-types (mir-infer-calls unit)) (mir-function-id function))
      (mir-analysis function :types #'mir-compute-types)))

(defun mir-infer-value-facts (function &optional unit)
  "Return bundle facts indexed by SSA value ID."
  (if unit
      (svref (mir-call-analysis-packets (mir-infer-calls unit)) (mir-function-id function))
      (mir-analysis function :values (lambda (function) (nth-value 1 (mir-compute-types function))))))

(defun mir-check-proven-p (instruction types)
  (and (= (mir-instruction-kind instruction) 11)
       (hir-declaration-proven-p
        (svref types (svref (mir-instruction-operands instruction) 0))
        (mir-instruction-data instruction))))
