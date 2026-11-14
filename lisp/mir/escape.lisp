(in-package #:kiln.compiler)

(defstruct mir-storage-analysis points fields (escaped 0) (stack 0) (cyclic 0))

(defun mir-cons-allocation-p (instruction)
  (and (= (mir-instruction-kind instruction) 6) (eq (mir-instruction-data instruction) 'cons)
       (= (length (mir-instruction-operands instruction)) 2)))

(defun mir-borrow-call-p (instruction)
  "Calls lowered directly to operations that cannot retain their arguments."
  (and (= (mir-instruction-kind instruction) 6) (not (mir-instruction-notinline instruction))
       (let ((name (mir-instruction-data instruction)) (count (length (mir-instruction-operands instruction))))
         (or (eq name 'values)
             (and (zerop count) (member name '(kiln.sys:%gc kiln.sys:%gc-count)))
             (and (= count 1) (member name '(identity car cdr first rest consp listp atom null not)))
             (and (= count 2) (member name '(cons rplaca rplacd eq eql)))))))

(defun mir-cyclic-blocks (function)
  (mir-analysis function :cyclic
    (lambda (function)
      (let* ((blocks (hir-vector (mir-function-blocks function)))
             (outgoing (map 'simple-vector
                            (lambda (block) (map 'list #'mir-edge-target
                                               (mir-terminator-edges (mir-block-terminator block)))) blocks))
             (cyclic 0))
        (dolist (component (mir-strong-components outgoing))
          (when (or (cdr component) (member (car component) (svref outgoing (car component))))
            (dolist (id component) (setf cyclic (logior cyclic (ash 1 id))))))
        cyclic))))

(defun mir-compute-storage (function types packets)
  "Prove acyclic cons sites whose identities never enter heap storage."
  (let* ((instructions (hir-vector (mir-function-instructions function)))
         (blocks (hir-vector (mir-function-blocks function)))
         (points (make-array (hir-buffer-count (mir-function-values function)) :initial-element 0))
         (fields (make-array (length instructions) :initial-element nil))
         (reachable (mir-reachable-blocks function)) (cyclic (mir-cyclic-blocks function))
         (sites 0) (escaped 0) (changed t))
    ;; Bit zero represents an object from outside this allocation graph.
    ;; Site N uses bit N+1, leaving unknown receivers distinguishable from
    ;; a union of known local objects when checking field stores.
    (loop for block across blocks when (logbitp (mir-block-id block) reachable) do
      (loop for id across (hir-vector (mir-block-instructions block))
            for instruction = (svref instructions id) when (mir-cons-allocation-p instruction) do
        (setf (svref fields id) (cons 0 0) sites (logior sites (ash 1 (1+ id))))
        (when (or (logbitp (mir-block-id block) cyclic)
                  (mir-instruction-notinline instruction)
                  (not (hir-policy-optimize-p (mir-instruction-policy instruction))))
          (setf escaped (logior escaped (ash 1 (1+ id)))))))
    (labels ((merge-points (id bits)
               (let ((joined (logior (svref points id) bits)))
                 (unless (= joined (svref points id)) (setf (svref points id) joined changed t))))
             (field-value (receivers tail)
               (let ((result (logand receivers 1)))
                 (dotimes (id (length fields) result)
                   (when (and (svref fields id) (logbitp (1+ id) receivers))
                     (setf result (logior result (if tail (cdr (svref fields id)) (car (svref fields id)))))))))
             (store-field (receivers value tail)
               (when (logbitp 0 receivers) (setf escaped (logior escaped value)))
               (dotimes (id (length fields))
                 (when (and (svref fields id) (logbitp (1+ id) receivers))
                   (let* ((pair (svref fields id)) (old (if tail (cdr pair) (car pair)))
                          (joined (logior old value)))
                     (unless (= old joined)
                       (if tail (setf (cdr pair) joined) (setf (car pair) joined))
                       (setf changed t))))))
             (transfer (instruction)
               (let* ((args (mir-instruction-operands instruction))
                      (name (mir-instruction-data instruction)))
                 (case (mir-instruction-kind instruction)
                   (0 (if (consp name) 1 0))
                   ((1 2) 1)
                   ((4 5 12) 0)
                   ((3 9 10 11) (svref points (svref args 0)))
                   (14 (let ((fact (svref packets (svref args 0))))
                         (if (and (mir-values-fact-p fact) (mir-values-fact-count fact)
                                  (>= name (mir-values-fact-count fact))) 0
                             (svref points (svref args 0)))))
                   (6 (cond ((mir-cons-allocation-p instruction)
                             (let ((pair (svref fields (mir-instruction-id instruction))))
                               (let ((car (logior (car pair) (svref points (svref args 0))))
                                     (cdr (logior (cdr pair) (svref points (svref args 1)))))
                                 (unless (and (= car (car pair)) (= cdr (cdr pair)))
                                   (setf (car pair) car (cdr pair) cdr changed t))))
                             (ash 1 (1+ (mir-instruction-id instruction))))
                            ((mir-borrow-call-p instruction)
                             (case name
                               ((identity rplaca rplacd)
                                (when (member name '(rplaca rplacd))
                                  (store-field (svref points (svref args 0)) (svref points (svref args 1))
                                               (eq name 'rplacd)))
                                (svref points (svref args 0)))
                               ((car cdr first rest) (field-value (svref points (svref args 0))
                                                                (member name '(cdr rest))))
                               (values (loop for arg across args with result = 0
                                             do (setf result (logior result (svref points arg)))
                                             finally (return result)))
                               (otherwise 0)))
                            (t 1)))
                   (otherwise 1)))))
      (loop while changed do
        (setf changed nil)
        (loop for block across blocks when (logbitp (mir-block-id block) reachable) do
          (loop for id across (hir-vector (mir-block-instructions block))
                for instruction = (svref instructions id) for result = (mir-instruction-result instruction)
                when result do (merge-points result (transfer instruction)))
          (loop for edge across (mir-terminator-edges (mir-block-terminator block)) do
            (loop for parameter across (mir-block-parameters (svref blocks (mir-edge-target edge)))
                  for argument across (mir-edge-arguments edge)
                  do (merge-points parameter (svref points argument))))))
      (loop for block across blocks when (logbitp (mir-block-id block) reachable) do
        (loop for id across (hir-vector (mir-block-instructions block))
              for instruction = (svref instructions id) for kind = (mir-instruction-kind instruction)
              unless (or (member kind '(0 1 2 4 5 9 10 12 13 14))
                         (mir-cons-allocation-p instruction) (mir-borrow-call-p instruction)
                         (and (= kind 11) (mir-check-proven-p instruction types)))
                do (loop for arg across (mir-instruction-operands instruction)
                         do (setf escaped (logior escaped (svref points arg)))))
        (let ((term (mir-block-terminator block)))
          (when (= (mir-terminator-kind term) 2)
            (setf escaped (logior escaped (svref points (svref (mir-terminator-operands term) 0)))))))
      ;; Non-single bundles use heap carriers, including conversions at joins.
      ;; Their contents cannot include a stack object even when never returned.
      (dotimes (id (length points))
        (when (eq (mir-value-representation (mir-at (mir-function-values function) id)) :bundle)
          (unless (and (mir-values-fact-p (svref packets id))
                       (eql 1 (mir-values-fact-count (svref packets id))))
            (setf escaped (logior escaped (svref points id))))))
      (setf changed t)
      (loop while changed do
        (let ((before escaped))
          (dotimes (id (length fields))
            (when (and (svref fields id) (logbitp (1+ id) escaped))
              (setf escaped (logior escaped (car (svref fields id)) (cdr (svref fields id))))))
          (setf changed (/= before escaped))))
      (make-mir-storage-analysis :points points :fields fields :escaped escaped
                                 :stack (logand sites (lognot escaped)) :cyclic cyclic))))

(defun mir-infer-storage (unit)
  (mir-unit-analysis unit :storage
    (lambda (unit)
      (let ((calls (mir-infer-calls unit)))
        (map 'simple-vector
             (lambda (function)
               (let ((id (mir-function-id function)))
                 (mir-compute-storage function (svref (mir-call-analysis-types calls) id)
                                      (svref (mir-call-analysis-packets calls) id))))
             (hir-vector (mir-unit-functions unit)))))))
