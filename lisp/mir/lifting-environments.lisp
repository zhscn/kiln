(in-package #:kiln.compiler)

;;; Capturing a function object normally exposes its public entry. A private
;;; group can instead pass its transitive data fields, provided each shared
;;; field denotes the same SSA value along every capture path. Conflicting
;;; instances retain public entries and their actual environment objects.

(defun mir-lifting-environment-external-functions (functions identities candidates &optional (entries #()))
  "Find functions that may be invoked outside the known local call sites."
  (let ((external 1))
    (loop for id across entries
          do (setf external (logior external (ash 1 id))))
    (loop for function across functions
          for known across identities
          for sets = (mir-contained-functions function)
          for reachable = (mir-reachable-blocks function)
          do (loop for block across (hir-buffer-view (mir-function-blocks function))
                   when (logbitp (mir-block-id block) reachable)
                   do (loop for id across (hir-buffer-view (mir-block-instructions block))
                            for instruction = (mir-at (mir-function-instructions function) id)
                            for kind = (mir-instruction-kind instruction)
                            for args = (mir-instruction-operands instruction)
                            do (unless
                                   (or (member kind '(0 1 2 4 5 9 10 12 13 14 16 22 23 25 37 39))
                                       (and (= kind 6)
                                            (member (mir-instruction-data instruction) '(identity values))))
                                 (loop for arg across args
                                       for index from 0
                                       unless (or
                                               (and (zerop index)
                                                    (or (= kind 24)
                                                        (and (member kind '(7 15))
                                                             (integerp (svref known arg)))))
                                               (and (= kind 24) (= index 1)
                                                    (let* ((data (mir-instruction-data instruction))
                                                           (destination (car data))
                                                           (expected
                                                            (svref
                                                             (mir-function-capture-functions
                                                              (svref functions destination))
                                                             (cdr data))))
                                                      (and (svref candidates destination) (integerp expected)
                                                           (svref candidates expected)
                                                           (eql expected (svref known arg))))))
                                       do (setf external (logior external (svref sets arg)))))) (let ((term
                                                                                                       (mir-block-terminator
                                                                                                        block)))
                                                                                                  (when
                                                                                                      (member
                                                                                                       (mir-terminator-kind
                                                                                                        term)
                                                                                                       '(2 4
                                                                                                         7))
                                                                                                    (loop for argument across (mir-terminator-operands
                                                                                                                               term)
                                                                                                          do (setf external
                                                                                                                     (logior
                                                                                                                      external
                                                                                                                      (svref
                                                                                                                       sets
                                                                                                                       argument))))))))
    external))

(defun mir-lifting-environment-candidates (unit &optional (excluded 0))
  (let* ((calls (mir-infer-calls unit))
         (functions (hir-buffer-view (mir-unit-functions unit)))
         (candidates (map 'simple-vector (lambda (f) (plusp (length (mir-function-captures f)))) functions)))
    (loop
     (let* ((external
             (mir-lifting-environment-external-functions functions (mir-call-analysis-identities calls) candidates
              (mir-unit-load-time-functions unit)))
            (copy (copy-mir-call-analysis calls)))
       (loop for f across functions
             for candidate across candidates
             unless candidate
             do (loop for target across (mir-function-capture-functions f)
                      when (integerp target)
                      do (setf external (logior external (ash 1 target)))))
       (setf (mir-call-analysis-external copy) (logior external excluded))
       (let ((widths (mir-lifting-widths unit copy)))
         (when (equalp candidates (map 'simple-vector (lambda (x) (not (null x))) widths)) (return widths))
         (setf candidates (map 'simple-vector (lambda (x) (not (null x))) widths)))))))

(defun mir-lifting-environment-layouts (unit candidates)
  "Collect data fields reachable through private function captures, in code/slot order."
  (let* ((functions (hir-buffer-view (mir-unit-functions unit)))
         (layouts (make-array (length functions) :initial-element nil)))
    (loop for root across functions for candidate across candidates when candidate do
      (let ((seen (make-array (length functions) :initial-element nil))
            (pending (list (mir-function-id root))) (keys nil) (count 0))
        (loop while pending for id = (pop pending) unless (svref seen id) do
          (setf (svref seen id) t)
          (loop for target across (mir-function-capture-functions (svref functions id))
                when (and (integerp target) (svref candidates target)) do (push target pending)))
        ;; An oversized layout is rejected before any field proof or graph rewrite.
        (block collect-fields
          (loop for function across functions when (svref seen (mir-function-id function)) do
            (loop for slot below (length (mir-function-captures function))
                  for target = (svref (mir-function-capture-functions function) slot)
                  unless (and (integerp target) (svref candidates target)) do
                    (push (cons (mir-function-id function) slot) keys)
                    (when (> (incf count) kiln.kir::+backend-argument-limit+) (return-from collect-fields)))))
        (setf (svref layouts (mir-function-id root)) (coerce (nreverse keys) 'simple-vector))))
    layouts))

(defun mir-lifting-environment-values (unit function candidates layouts)
  (let* ((functions (hir-buffer-view (mir-unit-functions unit)))
         (known (mir-function-identities function))
         (environments (make-array (length known) :initial-element nil))
         (own (mir-function-id function))
         (own-layout (svref layouts own))
         (instructions (hir-buffer-view (mir-function-instructions function)))
         (definitions (mir-value-definitions function))
         (constraints nil))
    (labels ((private (id)
               (and (integerp id) (svref candidates id)))
             (layout (id)
               (svref layouts id))
             (identity-of (value)
               (if (integerp value)
                   (let* ((origin (mir-primary-origin value definitions))
                          (instruction (svref definitions origin)))
                     (if (and instruction (= 22 (mir-instruction-kind instruction)) (svref candidates own))
                         (let ((index
                                (position (cons own (mir-instruction-data instruction)) own-layout :test
                                          #'equal)))
                           (if index
                               (list :prefix index)
                               origin))
                         origin))
                   value)))
      (loop for block across (hir-buffer-view (mir-function-blocks function))
            do (loop for parameter across (mir-block-parameters block)
                     for target = (svref known parameter)
                     when (private target)
                     do (setf (svref environments parameter)
                                (map 'simple-vector (lambda (key) (list :phi parameter key))
                                     (layout target)))))
      (loop for i across instructions
            for kind = (mir-instruction-kind i)
            for result = (mir-instruction-result i)
            do (cond
                ((and (= kind 23) (private (mir-instruction-data i)))
                 (setf (svref environments result)
                         (make-array (length (layout (mir-instruction-data i))) :initial-element nil)))
                ((and (= kind 22) (private (svref known result)))
                 (unless (svref candidates own)
                   (return-from mir-lifting-environment-values (values :unproved (svref known result))))
                 (setf (svref environments result)
                         (map 'simple-vector
                              (lambda (key)
                                (let ((index (position key own-layout :test #'equal)))
                                  (assert index)
                                  (list :prefix index)))
                              (layout (svref known result)))))))
      (loop with changed = t
            while changed
            do (setf changed nil) (loop for i across instructions
                                        for result = (mir-instruction-result i)
                                        for args = (mir-instruction-operands i)
                                        for kind = (mir-instruction-kind i)
                                        when (and result (private (svref known result))
                                                  (not (svref environments result)) (plusp (length args))
                                                  (or (member kind '(9 10 11 39))
                                                      (and (= kind 14) (zerop (mir-instruction-data i)))
                                                      (and (= kind 6)
                                                           (member (mir-instruction-data i)
                                                                   '(identity values))))
                                                  (svref environments (svref args 0)))
                                        do (setf (svref environments result)
                                                   (svref environments (svref args 0))
                                                 changed t)))
      (loop for i across instructions
            when (= 24 (mir-instruction-kind i))
            do (let* ((data (mir-instruction-data i))
                      (target (car data))
                      (slot (cdr data))
                      (args (mir-instruction-operands i))
                      (source (svref args 1))
                      (captured (svref (mir-function-capture-functions (svref functions target)) slot)))
                 (when (private target)
                   (let ((destination (svref environments (svref args 0))))
                     (unless destination
                       (return-from mir-lifting-environment-values (values :unproved target)))
                     (if (private captured)
                         (let ((fields (svref environments source)))
                           (unless fields
                             (return-from mir-lifting-environment-values (values :unproved captured)))
                           (loop for key across (layout captured)
                                 for index from 0
                                 for output = (position key (layout target) :test #'equal)
                                 do (assert output) (push (list destination output fields index key)
                                                          constraints)))
                         (setf (svref destination
                                      (position (cons target slot) (layout target) :test #'equal))
                                 source))))))
      (loop with changed = t
            while changed
            do (setf changed nil) (dolist (constraint constraints)
                                    (destructuring-bind
                                        (destination output fields input key)
                                        constraint
                                      (let ((old (svref destination output)) (new (svref fields input)))
                                        (cond
                                         ((and old new (not (equal (identity-of old) (identity-of new))))
                                          (return-from mir-lifting-environment-values
                                            (values :conflict (car key))))
                                         ((and (not old) new)
                                          (setf (svref destination output) new
                                                changed t)))))))
      (loop for i across instructions
            when (and (= 23 (mir-instruction-kind i)) (private (mir-instruction-data i)))
            do (when (find nil (svref environments (mir-instruction-result i)))
                 (return-from mir-lifting-environment-values (values :unproved (mir-instruction-data i)))))
      environments)))

(defun mir-lifting-environment-use-failure (function candidates environments)
  (multiple-value-bind (reachable dominators)
      (mir-cached-control-flow function)
    (let* ((known (mir-function-identities function))
           (blocks (hir-buffer-view (mir-function-blocks function)))
           (own (mir-function-id function))
           (entry (hir-buffer-view (mir-block-instructions (svref blocks 0))))
           (arity
            (position-if
             (lambda (id) (= 13 (mir-instruction-kind (mir-at (mir-function-instructions function) id))))
             entry)))
      (labels ((private (id)
                 (and (integerp id) (svref candidates id)))
               (dominating (value block position)
                 (cond
                  ((integerp value)
                   (let* ((definition (mir-at (mir-function-values function) value))
                          (owner (mir-value-block definition)))
                     (and (mir-block-dominates-p dominators owner block)
                          (or (/= owner block) (< (mir-value-position definition) position)))))
                  ((eq (first value) :prefix) (and arity (or (plusp block) (< arity position))))
                  ((eq (first value) :phi)
                   (let ((owner (mir-value-block (mir-at (mir-function-values function) (second value)))))
                     (mir-block-dominates-p dominators owner block)))
                  (t nil)))
               (environment-valid (value block position)
                 (let ((fields (svref environments value)))
                   (and fields (every (lambda (field) (dominating field block position)) fields)))))
        (when (and (private own) (null arity)) (return-from mir-lifting-environment-use-failure own))
        (loop for block across blocks
              for id = (mir-block-id block)
              when (logbitp id reachable)
              do (loop for instruction-id across (hir-buffer-view (mir-block-instructions block))
                       for position from 0
                       for i = (mir-at (mir-function-instructions function) instruction-id)
                       for kind = (mir-instruction-kind i)
                       for args = (mir-instruction-operands i)
                       do (when
                              (and (private own) (= kind 22)
                                   (or (not arity) (and (zerop id) (<= position arity))))
                            (return-from mir-lifting-environment-use-failure own)) (when (member kind '(7 15))
                                                                                    (let ((target
                                                                                           (svref known
                                                                                                  (svref args
                                                                                                         0))))
                                                                                      (when
                                                                                          (and
                                                                                           (private target)
                                                                                           (not
                                                                                            (environment-valid
                                                                                             (svref args 0)
                                                                                             id position)))
                                                                                        (return-from
                                                                                            mir-lifting-environment-use-failure
                                                                                          target))))) (loop for edge across (mir-terminator-edges
                                                                                                                             (mir-block-terminator
                                                                                                                              block))
                                                                                                            do (loop for parameter across (mir-block-parameters
                                                                                                                                           (svref
                                                                                                                                            blocks
                                                                                                                                            (mir-edge-target
                                                                                                                                             edge)))
                                                                                                                     for source across (mir-edge-arguments
                                                                                                                                        edge)
                                                                                                                     for target = (svref
                                                                                                                                   known
                                                                                                                                   parameter)
                                                                                                                     when (and
                                                                                                                           (private
                                                                                                                            target)
                                                                                                                           (not
                                                                                                                            (environment-valid
                                                                                                                             source
                                                                                                                             id
                                                                                                                             (hir-buffer-count
                                                                                                                              (mir-block-instructions
                                                                                                                               block)))))
                                                                                                                     do (return-from
                                                                                                                            mir-lifting-environment-use-failure
                                                                                                                          target))))
        nil))))

(defun mir-plan-lifted-environments (unit &key (parameter-budget 4096))
  (let* ((functions (hir-buffer-view (mir-unit-functions unit))) (calls (mir-infer-calls unit)) (excluded 0))
    (loop
     (let* ((candidates (let ((result (mir-lifting-environment-candidates unit excluded)))
                            (unless (loop for candidate across result for id from 0
                                          thereis (and candidate (logbitp id (mir-call-analysis-external calls))))
                              (return-from mir-plan-lifted-environments nil))
                            result))
            (layouts (mir-lifting-environment-layouts unit candidates))
            (environments (make-array (length functions)))
            (rejected nil))
       (labels ((private (id)
                  (and (integerp id) (svref candidates id)))
                (reject (id)
                  (assert (private id))
                  (pushnew id rejected)))
         (loop for f across functions
               for candidate across candidates
               for layout across layouts
               when (and candidate
                         (> (+ (length layout) (mir-function-positional-count f))
                            kiln.kir::+backend-argument-limit+))
               do (reject (mir-function-id f)))
         (loop for f across functions
               for known across (mir-call-analysis-identities calls)
               for packets across (mir-call-analysis-packets calls)
               for reachable = (mir-reachable-blocks f)
               do (let ((extra 0) (parameter-targets nil))
                    (loop for block across (hir-buffer-view (mir-function-blocks f))
                          do (loop for parameter across (mir-block-parameters block)
                                   for target = (svref known parameter)
                                   when (private target)
                                   do (incf extra (length (svref layouts target))) (when
                                                                                       (plusp
                                                                                        (length
                                                                                         (svref layouts
                                                                                                target)))
                                                                                     (pushnew target
                                                                                              parameter-targets))) (when
                                                                                                                       (logbitp
                                                                                                                        (mir-block-id
                                                                                                                         block)
                                                                                                                        reachable)
                                                                                                                     (loop for id across (hir-vector
                                                                                                                                          (mir-block-instructions
                                                                                                                                           block))
                                                                                                                           for i = (mir-at
                                                                                                                                    (mir-function-instructions
                                                                                                                                     f)
                                                                                                                                    id)
                                                                                                                           when (member
                                                                                                                                 (mir-instruction-kind
                                                                                                                                  i)
                                                                                                                                 '(7
                                                                                                                                   15))
                                                                                                                           do (let ((target
                                                                                                                                     (svref
                                                                                                                                      known
                                                                                                                                      (svref
                                                                                                                                       (mir-instruction-operands
                                                                                                                                        i)
                                                                                                                                       0))))
                                                                                                                                (when
                                                                                                                                    (private
                                                                                                                                     target)
                                                                                                                                  (multiple-value-bind
                                                                                                                                      (low
                                                                                                                                       high)
                                                                                                                                      (mir-lifting-call-range
                                                                                                                                       i
                                                                                                                                       packets)
                                                                                                                                    (declare
                                                                                                                                     (ignore
                                                                                                                                      low))
                                                                                                                                    (when
                                                                                                                                        (>
                                                                                                                                         (+
                                                                                                                                          high
                                                                                                                                          (length
                                                                                                                                           (svref
                                                                                                                                            layouts
                                                                                                                                            target)))
                                                                                                                                         kiln.kir::+backend-argument-limit+)
                                                                                                                                      (reject
                                                                                                                                       target))))))))
                    (when (> extra parameter-budget) (reject (first parameter-targets)))))
         (unless rejected
           (loop for f across functions
                 for id from 0
                 do (multiple-value-bind (plan failed)
                        (mir-lifting-environment-values unit f candidates layouts)
                      (if (vectorp plan)
                          (setf (svref environments id) plan)
                          (reject failed)))))
         (unless rejected
           (loop for f across functions
                 for plan across environments
                 for failed = (mir-lifting-environment-use-failure f candidates plan)
                 when failed
                 do (reject failed)))
         (unless rejected (return (values candidates layouts environments)))
         (dolist (id rejected) (setf excluded (logior excluded (ash 1 id)))))))))

(defun mir-lift-expanded-function (function candidates layouts masks known environments)
  (let* ((blocks (hir-buffer-view (mir-function-blocks function)))
         (instructions (mir-function-instructions function))
         (original (map 'simple-vector #'mir-block-parameters blocks))
         (own (mir-function-id function))
         (own-p (svref candidates own))
         (own-layout (svref layouts own))
         (own-functions (copy-seq (mir-function-capture-functions function)))
         (prefix (when own-p (make-array (length own-layout))))
         (prefix-instructions (make-hir-buffer))
         (phis (make-hash-table))
         (rebuilt (make-hir-buffer))
         (nil-value nil)
         (nil-instruction nil)
         (unbound-value nil)
         (unbound-instruction nil))
    (labels ((private (id)
               (and (integerp id) (svref candidates id)))
             (resolve (value)
               (if (integerp value)
                   value
                   (ecase (first value)
                     (:prefix (svref prefix (second value)))
                     (:phi
                      (let* ((parameter (second value))
                             (key (third value))
                             (index (position key (svref layouts (svref known parameter)) :test #'equal)))
                        (assert index)
                        (svref (gethash parameter phis) index))))))
             (fields (value)
               (let ((environment (svref environments value)))
                 (when environment (map 'simple-vector #'resolve environment)))))
      (loop for block across blocks
            do (let ((extra nil))
                 (loop for parameter across (mir-block-parameters block)
                       for target = (svref known parameter)
                       when (private target)
                       do (let ((values (make-array (length (svref layouts target)))))
                            (dotimes (slot (length values))
                              (let ((id
                                     (mir-add-value function
                                                    (if (logbitp slot (svref masks target))
                                                        :cell
                                                        :obj)
                                                    (mir-block-id block) -1)))
                                (setf (svref values slot) id)
                                (push id extra)))
                            (setf (gethash parameter phis) values)))
                 (setf (mir-block-parameters block)
                         (concatenate 'simple-vector (mir-block-parameters block) (nreverse extra)))))
      (when own-p
        (dotimes (slot (length prefix))
          (let ((id
                 (mir-add-value function
                                (if (logbitp slot (svref masks own))
                                    :cell
                                    :obj)
                                0 0)))
            (setf (svref prefix slot) id)
            (hir-push
             (make-mir-instruction :kind 1 :result id :data slot :policy (mir-function-policy function))
             prefix-instructions)))
        (setf (mir-function-internal-prefix function) (length own-layout)
              (mir-function-argument-cells function) (svref masks own))
        (incf (mir-function-required function) (length own-layout)))
      (when
          (loop for block across blocks
                for parameters across original
                thereis (> (length (mir-block-parameters block)) (length parameters)))
        (setf nil-value (mir-add-value function :obj 0 0)
              nil-instruction
                (make-mir-instruction :kind 0 :result nil-value :policy (mir-function-policy function))))
      (when
          (loop for parameter being the hash-keys of phis
                thereis (plusp (svref masks (svref known parameter))))
        (setf unbound-value (mir-add-value function :cell 0 0)
              unbound-instruction
                (make-mir-instruction :kind 25 :result unbound-value :policy
                                      (mir-function-policy function))))
      (loop for block across blocks
            for body = (make-hir-buffer)
            do (labels ((append-instruction (instruction)
                          (setf (mir-instruction-id instruction) (hir-buffer-count rebuilt))
                          (when (mir-instruction-result instruction)
                            (setf (mir-value-position
                                   (mir-at (mir-function-values function)
                                           (mir-instruction-result instruction)))
                                    (hir-buffer-count body)))
                          (hir-push (mir-instruction-id instruction) body)
                          (hir-push instruction rebuilt)))
                 (when (zerop (mir-block-id block))
                   (when nil-instruction (append-instruction nil-instruction))
                   (when unbound-instruction (append-instruction unbound-instruction)))
                 (loop for id across (hir-buffer-view (mir-block-instructions block))
                       for instruction = (mir-at instructions id)
                       for kind = (mir-instruction-kind instruction)
                       for args = (mir-instruction-operands instruction)
                       for data = (mir-instruction-data instruction)
                       unless (and (= kind 24) (private (car data)))
                       do (when own-p
                            (case kind
                              ((1 16 17) (incf (mir-instruction-data instruction) (length own-layout)))
                              (22
                               (let ((target (svref own-functions data)))
                                 (if (private target)
                                     (setf (mir-instruction-kind instruction) 5
                                           (mir-instruction-data instruction) target
                                           (mir-instruction-effects instruction)
                                             (svref *mir-instruction-effects* 5))
                                     (let ((index (position (cons own data) own-layout :test #'equal)))
                                       (assert index)
                                       (setf (mir-instruction-kind instruction) 1
                                             (mir-instruction-data instruction) index
                                             (mir-instruction-effects instruction)
                                               (svref *mir-instruction-effects* 1))))))
                              (13
                               (setf (mir-instruction-data instruction)
                                       (cons (mir-function-required function)
                                             (mir-function-maximum function)))))) (when
                                                                                      (and (= kind 23)
                                                                                           (private data))
                                                                                    (setf (mir-instruction-kind
                                                                                           instruction)
                                                                                            5
                                                                                          (mir-instruction-effects
                                                                                           instruction)
                                                                                            (svref
                                                                                             *mir-instruction-effects*
                                                                                             5))) (when
                                                                                                      (and
                                                                                                       (member
                                                                                                        kind
                                                                                                        '(7
                                                                                                          15))
                                                                                                       (private
                                                                                                        (svref
                                                                                                         known
                                                                                                         (svref
                                                                                                          args
                                                                                                          0))))
                                                                                                    (let ((values
                                                                                                           (fields
                                                                                                            (svref
                                                                                                             args
                                                                                                             0))))
                                                                                                      (assert
                                                                                                       values)
                                                                                                      (when
                                                                                                          (=
                                                                                                           kind
                                                                                                           15)
                                                                                                        (setf (mir-instruction-data
                                                                                                               instruction)
                                                                                                                (length
                                                                                                                 values)))
                                                                                                      (setf (mir-instruction-operands
                                                                                                             instruction)
                                                                                                              (concatenate
                                                                                                               'simple-vector
                                                                                                               (subseq
                                                                                                                args
                                                                                                                0
                                                                                                                1)
                                                                                                               values
                                                                                                               (subseq
                                                                                                                args
                                                                                                                1))))) (append-instruction
                                                                                                                        instruction) (when
                                                                                                                                         (and
                                                                                                                                          own-p
                                                                                                                                          (=
                                                                                                                                           kind
                                                                                                                                           13)
                                                                                                                                          (zerop
                                                                                                                                           (mir-block-id
                                                                                                                                            block)))
                                                                                                                                       (loop for prefix-instruction across (hir-vector
                                                                                                                                                                            prefix-instructions)
                                                                                                                                             do (append-instruction
                                                                                                                                                 prefix-instruction))))) (setf (mir-block-instructions
                                                                                                                                                                                block)
                                                                                                                                                                                 body) (loop for edge across (mir-terminator-edges
                                                                                                                                                                                                              (mir-block-terminator
                                                                                                                                                                                                               block))
                                                                                                                                                                                             do (let ((extra
                                                                                                                                                                                                       nil))
                                                                                                                                                                                                  (loop for parameter across (svref
                                                                                                                                                                                                                              original
                                                                                                                                                                                                                              (mir-edge-target
                                                                                                                                                                                                                               edge))
                                                                                                                                                                                                        for source across (mir-edge-arguments
                                                                                                                                                                                                                           edge)
                                                                                                                                                                                                        for target = (svref
                                                                                                                                                                                                                      known
                                                                                                                                                                                                                      parameter)
                                                                                                                                                                                                        when (private
                                                                                                                                                                                                              target)
                                                                                                                                                                                                        do (let ((values
                                                                                                                                                                                                                  (fields
                                                                                                                                                                                                                   source)))
                                                                                                                                                                                                             (unless
                                                                                                                                                                                                                 values
                                                                                                                                                                                                               (assert
                                                                                                                                                                                                                (not
                                                                                                                                                                                                                 (logbitp
                                                                                                                                                                                                                  (mir-block-id
                                                                                                                                                                                                                   block)
                                                                                                                                                                                                                  (mir-reachable-blocks
                                                                                                                                                                                                                   function)))))
                                                                                                                                                                                                             (dotimes
                                                                                                                                                                                                                 (slot
                                                                                                                                                                                                                  (length
                                                                                                                                                                                                                   (svref
                                                                                                                                                                                                                    layouts
                                                                                                                                                                                                                    target)))
                                                                                                                                                                                                               (push
                                                                                                                                                                                                                (if values
                                                                                                                                                                                                                    (svref
                                                                                                                                                                                                                     values
                                                                                                                                                                                                                     slot)
                                                                                                                                                                                                                    (if (logbitp
                                                                                                                                                                                                                         slot
                                                                                                                                                                                                                         (svref
                                                                                                                                                                                                                          masks
                                                                                                                                                                                                                          target))
                                                                                                                                                                                                                        unbound-value
                                                                                                                                                                                                                        nil-value))
                                                                                                                                                                                                                extra))))
                                                                                                                                                                                                  (setf (mir-edge-arguments
                                                                                                                                                                                                         edge)
                                                                                                                                                                                                          (concatenate
                                                                                                                                                                                                           'simple-vector
                                                                                                                                                                                                           (mir-edge-arguments
                                                                                                                                                                                                            edge)
                                                                                                                                                                                                           (nreverse
                                                                                                                                                                                                            extra))))))
      (when own-p
        (setf (mir-function-captures function) #()
              (mir-function-capture-cells function) 0
              (mir-function-capture-functions function) #()))
      (setf (mir-function-instructions function) rebuilt)))
  function)

(defun mir-lift-private-environments (unit &key (parameter-budget 4096))
  (let ((functions (hir-buffer-view (mir-unit-functions unit))))
    (unless (loop for function across functions
                  thereis (loop for target across (mir-function-capture-functions function)
                                thereis (and (integerp target) (plusp (length (mir-function-captures (svref functions target)))))))
      (return-from mir-lift-private-environments unit)))
  (multiple-value-bind (candidates layouts environments)
      (mir-plan-lifted-environments unit :parameter-budget parameter-budget)
    (unless candidates (return-from mir-lift-private-environments unit))
    (let* ((functions (hir-buffer-view (mir-unit-functions unit)))
           (known (map 'simple-vector #'mir-function-identities functions))
           (masks
            (map 'simple-vector
                 (lambda (layout)
                   (loop for key across (or layout #())
                         for slot from 0
                         when (logbitp (cdr key) (mir-function-capture-cells (svref functions (car key))))
                         sum (ash 1 slot)))
                 layouts)))
      (assert (every #'vectorp environments))
      (when (find-if #'identity candidates)
        (mir-run-unit-pass unit
                           (lambda (ignored)
                             (declare (ignore ignored))
                             (loop for f across functions
                                   for identities across known
                                   for fields across environments
                                   do (mir-lift-expanded-function f candidates layouts masks
                                       identities fields)))))
      unit)))


(defun mir-lift-local-functions (unit &key (parameter-budget 4096))
  (when (loop for function across (hir-buffer-view (mir-unit-functions unit))
              thereis (and (plusp (length (mir-function-captures function)))
                           (mir-lifting-policy-p function)))
    (mir-lift-private-environments unit :parameter-budget parameter-budget)
    (mir-lift-direct-environments unit :parameter-budget parameter-budget))
  unit)
