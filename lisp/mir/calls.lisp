(in-package #:kiln.compiler)

(defstruct mir-call-analysis identities outgoing components external inputs summaries value-summaries types packets)

(defun mir-function-identity-join (old new)
  (cond ((eq old :unseen) new) ((eq new :unseen) old)
        ((eql old new) old) (t :unknown)))

(defun mir-compute-function-identities (function)
  "Track one local function ID, or :UNKNOWN, through primary values."
  (let* ((identities (make-array (hir-buffer-count (mir-function-values function))
                                 :initial-element :unseen))
         (blocks (hir-vector (mir-function-blocks function)))
         (reachable (mir-reachable-blocks function)) (changed t))
    (labels ((merge-identity (id identity)
               (let ((joined (mir-function-identity-join (svref identities id) identity)))
                 (unless (eql joined (svref identities id))
                   (setf (svref identities id) joined changed t))))
             (transfer (instruction)
               (let ((args (mir-instruction-operands instruction)))
                 (case (mir-instruction-kind instruction)
                   (5 (mir-instruction-data instruction))
                   ((3 9 10 11) (svref identities (svref args 0)))
                   (14 (if (zerop (mir-instruction-data instruction))
                           (svref identities (svref args 0)) :unknown))
                   (6 (if (and (member (mir-instruction-data instruction) '(identity values))
                               (plusp (length args)))
                          (svref identities (svref args 0)) :unknown))
                   (otherwise :unknown)))))
      (loop while changed do
        (setf changed nil)
        (loop for block across blocks when (logbitp (mir-block-id block) reachable) do
          (loop for id across (hir-vector (mir-block-instructions block))
                for instruction = (mir-at (mir-function-instructions function) id)
                for result = (mir-instruction-result instruction)
                when result do (merge-identity result (transfer instruction)))
          (loop for edge across (mir-terminator-edges (mir-block-terminator block)) do
            (loop for parameter across (mir-block-parameters (svref blocks (mir-edge-target edge)))
                  for argument across (mir-edge-arguments edge)
                  do (merge-identity parameter (svref identities argument)))))))
    (dotimes (id (length identities))
      (when (eq (svref identities id) :unseen) (setf (svref identities id) :unknown)))
    identities))

(defun mir-function-identities (function)
  (mir-analysis function :functions #'mir-compute-function-identities))

(defun mir-strong-components (outgoing)
  "Return integer-indexed graph SCCs with successors before predecessors."
  (let* ((count (length outgoing)) (indices (make-array count :initial-element -1))
         (low (make-array count :initial-element 0)) (active (make-array count :initial-element nil))
         (stack nil) (next 0) (components nil))
    (labels ((visit (id)
               (setf (svref indices id) next (svref low id) next (svref active id) t)
               (incf next) (push id stack)
               (dolist (callee (svref outgoing id))
                 (cond ((minusp (svref indices callee))
                        (visit callee) (setf (svref low id) (min (svref low id) (svref low callee))))
                       ((svref active callee)
                        (setf (svref low id) (min (svref low id) (svref indices callee))))))
               (when (= (svref low id) (svref indices id))
                 (let ((component nil))
                   (loop for member = (pop stack)
                         do (setf (svref active member) nil) (push member component)
                         until (= member id))
                   (push component components)))))
      (dotimes (id count) (when (minusp (svref indices id)) (visit id))))
    (nreverse components)))

(defun mir-return-type (function types)
  (let ((result :unseen) (reachable (mir-reachable-blocks function)))
    (loop for block across (hir-vector (mir-function-blocks function))
          for term = (mir-block-terminator block)
          when (and (logbitp (mir-block-id block) reachable) (= (mir-terminator-kind term) 2))
            do (setf result (mir-type-join result (svref types (svref (mir-terminator-operands term) 0)))))
    result))

(defun mir-return-values (function packets)
  (let ((result :unseen) (reachable (mir-reachable-blocks function))
        (expansions (make-array +mir-values-prefix-limit+ :initial-element 0)))
    (loop for block across (hir-vector (mir-function-blocks function))
          for term = (mir-block-terminator block)
          when (and (logbitp (mir-block-id block) reachable) (= (mir-terminator-kind term) 2))
            do (setf result (mir-join-values result
                             (svref packets (svref (mir-terminator-operands term) 0)) expansions)))
    result))

(defun mir-contained-functions (function)
  "Overapproximate local functions carried by each scalar or saved bundle."
  (let* ((sets (make-array (hir-buffer-count (mir-function-values function)) :initial-element 0))
         (blocks (hir-vector (mir-function-blocks function)))
         (reachable (mir-reachable-blocks function)) (changed t))
    (labels ((merge-set (id bits)
               (let ((joined (logior (svref sets id) bits)))
                 (unless (= joined (svref sets id))
                   (setf (svref sets id) joined changed t))))
             (transfer (instruction)
               (let ((args (mir-instruction-operands instruction)))
                 (case (mir-instruction-kind instruction)
                   (5 (ash 1 (mir-instruction-data instruction)))
                   ((3 9 10 11 14) (svref sets (svref args 0)))
                   (6 (case (mir-instruction-data instruction)
                        (identity (if (plusp (length args)) (svref sets (svref args 0)) 0))
                        (values (loop for arg across args for bits = (svref sets arg)
                                      with result = 0 do (setf result (logior result bits))
                                      finally (return result)))
                        (otherwise 0)))
                   (otherwise 0)))))
      (loop while changed do
        (setf changed nil)
        (loop for block across blocks when (logbitp (mir-block-id block) reachable) do
          (loop for id across (hir-vector (mir-block-instructions block))
                for instruction = (mir-at (mir-function-instructions function) id)
                for result = (mir-instruction-result instruction)
                when result do (merge-set result (transfer instruction)))
          (loop for edge across (mir-terminator-edges (mir-block-terminator block)) do
            (loop for parameter across (mir-block-parameters (svref blocks (mir-edge-target edge)))
                  for argument across (mir-edge-arguments edge)
                  do (merge-set parameter (svref sets argument)))))))
    sets))

(defun mir-external-functions (functions identities)
  "Find functions that may be invoked outside the known local call sites."
  (let ((external 1))
    (loop for function across functions for known across identities
          for sets = (mir-contained-functions function)
          for reachable = (mir-reachable-blocks function) do
      (loop for block across (hir-vector (mir-function-blocks function))
            when (logbitp (mir-block-id block) reachable) do
        (loop for id across (hir-vector (mir-block-instructions block))
              for instruction = (mir-at (mir-function-instructions function) id)
              for kind = (mir-instruction-kind instruction)
              for args = (mir-instruction-operands instruction) do
          ;; Parameter identities and heap contents are not yet tracked across
          ;; calls. Passing a function to any callee therefore exposes it.
          (unless (or (member kind '(0 1 2 4 5 9 10 12 13 14 16))
                      (and (= kind 6) (member (mir-instruction-data instruction) '(identity values))))
            (loop for arg across args for index from 0
                  unless (and (member kind '(7 15)) (zerop index) (integerp (svref known arg)))
                    do (setf external (logior external (svref sets arg))))))
        (let ((term (mir-block-terminator block)))
          (when (= (mir-terminator-kind term) 2)
            (setf external (logior external (svref sets (svref (mir-terminator-operands term) 0))))))))
    external))

(defun mir-widen-summary (old candidate expansions)
  (let ((joined (mir-type-join old candidate)))
    (when (and (hir-range-p old) (hir-range-p joined) (not (equal old joined)))
      (incf expansions)
      (when (>= expansions 2) (setf joined 'integer)))
    (values joined expansions)))

(defun mir-call-argument-types (instruction facts packets required &optional (maximum required))
  "Flatten call facts, or return :UNSEEN, :UNKNOWN or :WRONG-ARITY."
  (let ((args (mir-instruction-operands instruction)))
    (if (= (mir-instruction-kind instruction) 7)
        (if (<= required (1- (length args)) maximum)
            (map 'simple-vector (lambda (id) (svref facts id)) (subseq args 1))
            :wrong-arity)
        (let ((count 0) (unknown nil))
          (loop for index from 1 below (length args) for packet = (svref packets (svref args index))
                do (when (eq packet :unseen) (return-from mir-call-argument-types :unseen))
                   (if (mir-values-fact-count packet) (incf count (mir-values-fact-count packet))
                       (setf unknown t)))
          (when unknown (return-from mir-call-argument-types :unknown))
          (unless (<= required count maximum) (return-from mir-call-argument-types :wrong-arity))
          (let ((result (make-array count)) (position 0))
            (loop for index from 1 below (length args) for packet = (svref packets (svref args index))
                  do (dotimes (slot (mir-values-fact-count packet))
                       (setf (svref result position) (mir-values-ref-type packet slot)) (incf position)))
            result)))))

(defun mir-compute-calls (unit)
  (let* ((functions (hir-vector (mir-unit-functions unit))) (count (length functions))
         (identities (map 'simple-vector #'mir-function-identities functions))
         (external (mir-external-functions functions identities))
         (outgoing (make-array count :initial-element nil))
         (summaries (make-array count :initial-element :unseen))
         (changes (make-array count :initial-element 0))
         (value-summaries (make-array count :initial-element :unseen))
         (value-changes (map 'simple-vector
                             (lambda (function) (declare (ignore function))
                               (make-array +mir-values-prefix-limit+ :initial-element 0)) functions))
         (inputs (map 'simple-vector
                      (lambda (function)
                        (make-array (mir-function-positional-count function)
                                    :initial-element (if (logbitp (mir-function-id function) external) t :unseen)))
                      functions))
         (input-changes (map 'simple-vector
                             (lambda (function) (make-array (mir-function-positional-count function) :initial-element 0))
                             functions))
         (types (make-array count)) (packets (make-array count)))
    (loop for function across functions for id from 0
          for known across identities for reachable = (mir-reachable-blocks function) do
      (loop for block across (hir-vector (mir-function-blocks function))
            when (logbitp (mir-block-id block) reachable) do
        (loop for index across (hir-vector (mir-block-instructions block))
              for instruction = (mir-at (mir-function-instructions function) index)
              when (member (mir-instruction-kind instruction) '(7 15)) do
                (let ((target (svref known (svref (mir-instruction-operands instruction) 0))))
                  (when (integerp target) (pushnew target (svref outgoing id)))))))
    (let ((components (mir-strong-components outgoing)) (changed t))
      (labels ((merge-inputs (function facts packets known)
                 (let ((reachable (mir-reachable-blocks function)))
                   (loop for block across (hir-vector (mir-function-blocks function))
                         when (logbitp (mir-block-id block) reachable) do
                     (loop for index across (hir-vector (mir-block-instructions block))
                           for instruction = (mir-at (mir-function-instructions function) index)
                           for args = (mir-instruction-operands instruction)
                           when (member (mir-instruction-kind instruction) '(7 15)) do
                       (let ((target (svref known (svref args 0))))
                         (when (integerp target)
                           (let* ((row (svref inputs target)) (counts (svref input-changes target))
                                  (arguments (mir-call-argument-types instruction facts packets
                                                                      (mir-function-required (svref functions target)) (length row))))
                             ;; Unknown counts may match this signature; every
                             ;; argument must then allow arbitrary object types.
                             (when (or (vectorp arguments) (eq arguments :unknown))
                               (dotimes (position (length row))
                                 (let ((old (svref row position))
                                       (candidate (cond ((eq arguments :unknown) t)
                                                        ((< position (length arguments)) (svref arguments position))
                                                        (t 'null))))
                                   (multiple-value-bind (joined expansions)
                                       (mir-widen-summary old candidate (svref counts position))
                                     (setf (svref counts position) expansions)
                                     (unless (equal old joined)
                                       (setf (svref row position) joined changed t)))))))))))))
               (solve ()
                 ;; Inputs flow from caller to callee, results in the reverse
                 ;; direction. Repeat SCC sweeps until both have stabilized.
                 (loop while changed do
                   (setf changed nil)
                   (dolist (component components)
                     (dolist (id component)
                       (let ((function (svref functions id)))
                         (multiple-value-bind (facts packet-facts)
                             (mir-compute-types function :summaries summaries :value-summaries value-summaries
                                                :functions (svref identities id)
                                                :inputs (svref inputs id) :finalize nil)
                           (let ((old (svref summaries id)))
                             (multiple-value-bind (joined expansions)
                                 (mir-widen-summary old (mir-return-type function facts) (svref changes id))
                               (setf (svref changes id) expansions)
                               (unless (equal old joined) (setf (svref summaries id) joined changed t))))
                           (let* ((old (svref value-summaries id))
                                  (joined (mir-join-values old (mir-return-values function packet-facts)
                                                           (svref value-changes id))))
                             (unless (equalp old joined)
                               (setf (svref value-summaries id) joined changed t)))
                           (merge-inputs function facts packet-facts (svref identities id)))))))))
        (solve)
        ;; Uncalled functions and cycles without seeds must still have safe
        ;; code. Replace unresolved inputs/results with unknown and close the
        ;; fixed point again before publishing any optimization facts.
        (dotimes (id count)
          (when (eq (svref summaries id) :unseen) (setf (svref summaries id) t changed t))
          (when (eq (svref value-summaries id) :unseen)
            (setf (svref value-summaries id) (mir-unknown-values (svref summaries id)) changed t))
          (dotimes (position (length (svref inputs id)))
            (when (eq (svref (svref inputs id) position) :unseen)
              (setf (svref (svref inputs id) position) t changed t))))
        (solve)
        (dotimes (id count)
          (multiple-value-bind (facts packet-facts)
              (mir-compute-types (svref functions id) :summaries summaries :value-summaries value-summaries
                                 :functions (svref identities id) :inputs (svref inputs id))
            (setf (svref types id) facts (svref packets id) packet-facts)))
        (make-mir-call-analysis :identities identities :outgoing outgoing :components components
                                :external external :inputs inputs :summaries summaries :value-summaries value-summaries
                                :types types :packets packets)))))

(defun mir-infer-calls (unit)
  (mir-unit-analysis unit :calls #'mir-compute-calls))
