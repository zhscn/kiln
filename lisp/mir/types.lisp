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
        (loop for instruction across (hir-buffer-view (mir-function-instructions function))
              for result = (mir-instruction-result instruction)
              when result do (setf (svref definitions result) instruction))
        definitions))))

(defun mir-primary-origin (id definitions)
  "Follow operations that preserve a value's primary identity."
  (loop for instruction = (svref definitions id)
        while (and instruction (member (mir-instruction-kind instruction) '(9 10 11 39)))
        do (setf id (svref (mir-instruction-operands instruction) 0))
        finally (return id)))

(defun mir-specialized-vector-constructor-type (args dimension-type definitions)
  "Use literal MAKE-ARRAY options to prove simple specialized storage."
  (unless (and (>= (length args) 3) (oddp (length args))
               (hir-integer-type-p dimension-type))
    (return-from mir-specialized-vector-constructor-type nil))
  (flet ((literal (index)
           (let ((definition (svref definitions (mir-primary-origin (svref args index) definitions))))
             (when (and definition (= (mir-instruction-kind definition) 0))
               (mir-instruction-data definition)))))
    (let ((element nil))
      (loop for index from 1 below (length args) by 2
            do (case (literal index)
                 (:element-type
                  (when element (return-from mir-specialized-vector-constructor-type nil))
                  (setf element (hir-upgraded-literal-element-type (literal (1+ index))))
                  (unless element
                    (return-from mir-specialized-vector-constructor-type nil)))
                 ((:initial-element :initial-contents))
                 (otherwise (return-from mir-specialized-vector-constructor-type nil))))
      (when element (list :simple-specialized-array element '(*))))))

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

(defun mir-compute-value-use-blocks (function)
  "Index blocks whose instructions or outgoing edges read each SSA value."
  (let* ((users (make-array (hir-buffer-count (mir-function-values function)) :initial-element nil))
         (seen (make-array (length users) :initial-element -1))
         (reachable (mir-reachable-blocks function)))
    (loop for block across (hir-buffer-view (mir-function-blocks function))
          for block-id = (mir-block-id block)
          when (logbitp block-id reachable) do
      (flet ((note-value (id)
               (unless (= (svref seen id) block-id)
                 (setf (svref seen id) block-id)
                 (push block-id (svref users id)))))
        (loop for id across (hir-buffer-view (mir-block-instructions block)) do
          (map nil #'note-value (mir-instruction-operands (mir-at (mir-function-instructions function) id))))
        (loop for edge across (mir-terminator-edges (mir-block-terminator block)) do
          (map nil #'note-value (mir-edge-arguments edge)))))
    users))

(defun mir-value-use-blocks (function)
  ;; Verification must see raw edits even when no pass advanced the revision.
  (if *mir-verification-identities*
      (mir-compute-value-use-blocks function)
      (mir-analysis function :value-use-blocks #'mir-compute-value-use-blocks)))

(defun mir-type-use-blocks (function)
  "Add implicit comparison reads to the ordinary SSA transfer dependencies."
  (mir-analysis function :type-use-blocks
    (lambda (function)
      (let ((users (map 'simple-vector #'copy-list (mir-value-use-blocks function)))
            (definitions (mir-value-definitions function))
            (reachable (mir-reachable-blocks function)))
        (loop for block across (hir-buffer-view (mir-function-blocks function))
              for block-id = (mir-block-id block) for term = (mir-block-terminator block)
              when (and (logbitp block-id reachable) (= (mir-terminator-kind term) 1)) do
          ;; The Boolean type can stay unchanged while comparison operands widen.
          (let ((predicate (svref definitions
                                  (mir-primary-origin (svref (mir-terminator-operands term) 0) definitions))))
            (when predicate
              (loop for id across (mir-instruction-operands predicate) do
                (pushnew block-id (svref users id))))))
        users))))

(defun mir-induction-limit-type (id definitions)
  (let ((definition (svref definitions id)))
    (when definition
      (case (mir-instruction-kind definition)
        (0 (hir-constant-type (mir-instruction-data definition)))
        (11 (hir-declaration-type (mir-instruction-data definition)))
        ((9 10) (mir-induction-limit-type (svref (mir-instruction-operands definition) 0) definitions))
        (6 (let ((args (mir-instruction-operands definition)))
             (when (and (eq (mir-instruction-data definition) 'length)
                        (not (mir-instruction-notinline definition))
                        (= (length args) 1))
               (let ((type (mir-induction-limit-type (svref args 0) definitions)))
                 (when (or (member type '(simple-vector :native-string))
                           (hir-simple-specialized-vector-p type)
                           (and (hir-simple-specialized-array-p type) (eq (third type) '*)))
                   (inferred-call-type 'length (vector type)))))))))))

(defun mir-induction-integer-constant-p (id integer definitions)
  (let ((definition (svref definitions (mir-primary-origin id definitions))))
    (and definition (= (mir-instruction-kind definition) 0)
         (eql (mir-instruction-data definition) integer))))

(defun mir-induction-add-one-p (value parameter definitions)
  (let* ((origin (mir-primary-origin value definitions))
         (instruction (svref definitions origin)))
    (when (and instruction (= (mir-instruction-kind instruction) 6))
      (let ((name (mir-instruction-data instruction))
            (operands (mir-instruction-operands instruction)))
        (flet ((argument (index) (mir-primary-origin (svref operands index) definitions)))
          (or (and (eq name '1+) (= (length operands) 1) (= (argument 0) parameter))
              (and (eq name '+) (= (length operands) 2)
                   (or (and (= (argument 0) parameter)
                            (mir-induction-integer-constant-p (argument 1) 1 definitions))
                       (and (= (argument 1) parameter)
                            (mir-induction-integer-constant-p (argument 0) 1 definitions))))))))))

(defun mir-induction-bound-candidates (function blocks definitions reachable)
  (let ((values (hir-buffer-view (mir-function-values function)))
        (candidates nil))
    (loop for header across blocks
          for id = (mir-block-id header)
          for parameters = (mir-block-parameters header)
          for term = (mir-block-terminator header)
          when (and (plusp (length parameters)) (= (mir-terminator-kind term) 1)
                    (logbitp id reachable))
            do (let* ((test (mir-primary-origin (svref (mir-terminator-operands term) 0) definitions))
                      (comparison (svref definitions test)))
                 (when (and comparison (= (mir-instruction-kind comparison) 6)
                            (eq (mir-instruction-data comparison) '>=)
                            (= (length (mir-instruction-operands comparison)) 2)
                            (= (mir-value-block (svref values test)) id))
                   (let* ((args (mir-instruction-operands comparison))
                          (index (mir-primary-origin (svref args 0) definitions))
                          (position (position index parameters :test #'eql))
                          (limit (svref args 1)))
                     (when position
                       (let ((range (hir-type-range (mir-induction-limit-type limit definitions))))
                         (when (and range (hir-fixnum-type-p range))
                           (push (list id index position
                                       (mir-edge-target (svref (mir-terminator-edges term) 1))
                                       (hir-integer-range 0 (max 0 (third range)))
                                       (mir-primary-origin limit definitions))
                                 candidates))))))))
    candidates))

(defun mir-checked-vector-dimension (instruction definitions)
  (let ((operands (mir-instruction-operands instruction)))
    (when (and (= (mir-instruction-kind instruction) 6)
               (eq (mir-instruction-data instruction) 'make-array)
               (plusp (length operands))
               (mir-specialized-vector-constructor-type
                operands (mir-induction-limit-type (svref operands 0) definitions) definitions))
      (mir-primary-origin (svref operands 0) definitions))))

(defun mir-induction-array-limits (candidates values definitions reachable)
  (let ((witnesses (make-hash-table :test #'eql)))
    (dolist (candidate candidates)
      (destructuring-bind (header index position body range limit) candidate
        (declare (ignore header index position body))
        (when (and (> (third range) +hir-vector-max-length+)
                   (zerop (mir-value-block (svref values limit))))
          (setf (gethash limit witnesses) nil))))
    (when (plusp (hash-table-count witnesses))
      (loop for instruction across definitions
            for origin = (and instruction (mir-checked-vector-dimension instruction definitions))
            when (and origin (nth-value 1 (gethash origin witnesses)))
              do (let ((block (mir-value-block (svref values (mir-instruction-result instruction)))))
                   (when (logbitp block reachable)
                     (pushnew block (gethash origin witnesses))))))
    witnesses))

(defun mir-compute-induction-bounds (function blocks definitions reachable)
  (let ((candidates (mir-induction-bound-candidates function blocks definitions reachable)))
    (when candidates
      (let ((incoming (make-array (length blocks) :initial-element nil))
            (bounds nil)
            (array-limits (mir-induction-array-limits
                           candidates (hir-buffer-view (mir-function-values function))
                           definitions reachable))
            (dominators (nth-value 1 (mir-cached-control-flow function))))
        (loop for block across blocks
              for id = (mir-block-id block)
              when (logbitp id reachable)
                do (loop for edge across (mir-terminator-edges (mir-block-terminator block))
                         do (push (cons id edge) (svref incoming (mir-edge-target edge)))))
        (dolist (candidate candidates)
          (destructuring-bind (header index position body range limit) candidate
            (let ((body-entries (svref incoming body))
                  (initial nil) (increment nil))
              ;; The continuation block must have no entry besides the
              ;; guard edge. Every increment then starts below the limit.
              (when (and (consp body-entries) (null (cdr body-entries))
                         (= (caar body-entries) header) (/= body header)
                         (loop for (source . edge) in (svref incoming header)
                               for argument = (svref (mir-edge-arguments edge) position)
                               always
                               (if (mir-block-dominates-p dominators body source)
                                   (when (mir-induction-add-one-p argument index definitions)
                                     (setf increment t))
                                   (when (mir-induction-integer-constant-p argument 0 definitions)
                                     (setf initial t))))
                         initial increment)
                (unless bounds
                  (setf bounds (make-array (length definitions) :initial-element nil)))
                (setf (svref bounds index)
                      (if (and (> (third range) +hir-vector-max-length+)
                               (some (lambda (block)
                                       (and (/= block header)
                                            (mir-block-dominates-p dominators block header)))
                                     (gethash limit array-limits)))
                          (hir-integer-range 0 +hir-vector-max-length+)
                          range))))))
        bounds))))

(defun mir-induction-bounds (function blocks definitions reachable)
  (mir-analysis function :induction-bounds
    (lambda (function)
      (mir-compute-induction-bounds function blocks definitions reachable))))

(defun mir-shift-guard-relation (term definitions &optional allow-decrement)
  (let* ((test (mir-primary-origin (svref (mir-terminator-operands term) 0) definitions))
         (comparison (svref definitions test)))
    (when (and comparison (= (mir-instruction-kind comparison) 6)
               (member (mir-instruction-data comparison) (if allow-decrement '(< <=) '(<=)))
               (not (mir-instruction-notinline comparison))
               (= (length (mir-instruction-operands comparison)) 2))
      (let* ((args (mir-instruction-operands comparison))
             (limit (svref definitions (mir-primary-origin (svref args 1) definitions))))
        (when (and limit (= (mir-instruction-kind limit) 6)
                   (eq (mir-instruction-data limit) 'ash)
                   (not (mir-instruction-notinline limit))
                   (= (length (mir-instruction-operands limit)) 2)
                   (mir-induction-integer-constant-p
                    (svref (mir-instruction-operands limit) 1) -1 definitions))
          (let* ((source (mir-primary-origin (svref (mir-instruction-operands limit) 0) definitions))
                 (decrement (and allow-decrement (svref definitions source))))
            (when (and decrement (= (mir-instruction-kind decrement) 6)
                       (eq (mir-instruction-data decrement) '1-)
                       (not (mir-instruction-notinline decrement))
                       (= (length (mir-instruction-operands decrement)) 1))
              ;; An index bounded by (Z - 1) >> 1 also lies below Z.
              (setf source (mir-primary-origin
                             (svref (mir-instruction-operands decrement) 0) definitions)))
            (cons (mir-primary-origin (svref args 0) definitions) source)))))))

(defun mir-shift-guarded-indices (function blocks definitions reachable)
  "Map guarded zero-based index parameters to the value they traverse toward."
  (mir-analysis function :shift-guarded-indices
    (lambda (function)
      (let ((guards nil))
        (loop for block across blocks
              for term = (mir-block-terminator block)
              when (and (logbitp (mir-block-id block) reachable)
                        (= (mir-terminator-kind term) 1))
                do (let ((relation (mir-shift-guard-relation term definitions t)))
                     (when relation
                       (push (cons (svref (mir-terminator-edges term) 0) relation) guards))))
        (when guards
          (let ((incoming (make-array (length blocks) :initial-element nil))
                (guarded (make-hash-table :test #'eq))
                (result (make-hash-table :test #'eql))
                (values (hir-buffer-view (mir-function-values function))))
            (loop for block across blocks
                  when (logbitp (mir-block-id block) reachable)
                    do (loop for edge across (mir-terminator-edges (mir-block-terminator block))
                             do (push edge (svref incoming (mir-edge-target edge)))))
            (dolist (guard guards)
              (destructuring-bind (edge index . source) guard
                ;; LOOP may put empty control-flow connectors on the taken
                ;; edge. Stop before a merge or a block that can rebind an
                ;; SSA value used by the proof.
                (loop for target = (mir-edge-target edge)
                      for block = (svref blocks target)
                      for term = (mir-block-terminator block)
                      while (and (null (cdr (svref incoming target)))
                                 (zerop (length (mir-block-parameters block)))
                                 (/= target (mir-value-block (svref values index)))
                                 (/= target (mir-value-block (svref values source)))
                                 (zerop (mir-terminator-kind term)))
                      do (setf edge (svref (mir-terminator-edges term) 0)))
                (setf (gethash edge guarded) (cons index source))))
            ;; Every entry supplies zero or advances a previously established
            ;; index, and the taken comparison bounds either value by Z >> 1.
            (loop for block across blocks
                  for edges = (svref incoming (mir-block-id block))
                  when (and edges (every (lambda (edge) (gethash edge guarded)) edges))
                    do (loop for parameter across (mir-block-parameters block)
                             for position from 0
                             for source = (cdr (gethash (first edges) guarded))
                             when (and (/= (mir-block-id block)
                                           (mir-value-block (svref values source)))
                                       (some (lambda (edge)
                                               (mir-induction-integer-constant-p
                                                (svref (mir-edge-arguments edge) position) 0 definitions))
                                             edges)
                                       (every (lambda (edge)
                                                (let* ((argument (svref (mir-edge-arguments edge) position))
                                                       (guard (gethash edge guarded)))
                                                  (and (= source (cdr guard))
                                                       (= (car guard) (mir-primary-origin argument definitions))
                                                       (or (mir-induction-integer-constant-p argument 0 definitions)
                                                           (mir-induction-add-one-p argument parameter definitions)))))
                                              edges))
                               do (setf (gethash parameter result) source)))
            result))))))

(defun mir-shift-guarded-increments (function guards definitions values)
  "Index increments that depend on a shift guard's upper operand for their range."
  (when (and guards (plusp (hash-table-count guards)))
    (mir-analysis function :shift-guarded-increments
      (lambda (function)
        (let ((sources (make-hash-table :test #'eql))
              (users (make-hash-table :test #'eql)))
          (loop for instruction across (hir-buffer-view (mir-function-instructions function))
                for result = (mir-instruction-result instruction)
                when (and result (= (mir-instruction-kind instruction) 6)
                          (member (mir-instruction-data instruction) '(1+ +)))
                  do (loop for input across (mir-instruction-operands instruction)
                           for index = (mir-primary-origin input definitions)
                           for source = (gethash index guards)
                           when (and source (mir-induction-add-one-p result index definitions))
                             do (setf (gethash result sources) source)
                                (pushnew (mir-value-block (svref values result)) (gethash source users))
                                (return)))
          (cons sources users))))))

(defun mir-compute-types (function &key summaries value-summaries functions inputs captures cell-types cell-points (finalize t))
  "Infer primary-value types. :UNSEEN is solver bottom; T is unknown."
  (let* ((types (make-array (hir-buffer-count (mir-function-values function))
                            :initial-element :unseen))
         (packets (make-array (length types) :initial-element :unseen))
         (packet-changes (make-array (length types) :initial-element nil))
         (blocks (hir-buffer-view (mir-function-blocks function)))
         (values (hir-buffer-view (mir-function-values function)))
         (reachable (mir-reachable-blocks function))
         (definitions (mir-value-definitions function))
         (induction (mir-induction-bounds function blocks definitions reachable))
         (shift-guards (mir-shift-guarded-indices function blocks definitions reachable))
         (shift-increments (mir-shift-guarded-increments function shift-guards definitions values))
         (changes (make-array (length types) :initial-element 0))
         (users (mir-type-use-blocks function))
         (queued (make-array (length blocks) :initial-element nil))
         (work (make-hir-buffer)))
    ;; A loop can keep expanding an integer interval. After two expansions,
    ;; generalize it to a representation boundary. Later inputs may exceed
    ;; that boundary, so continue joining them with the widened fact.
    (labels ((enqueue (block)
               (unless (svref queued block)
                 (setf (svref queued block) t)
                 (hir-push block work)))
             (enqueue-users (id)
               (dolist (block (svref users id)) (enqueue block))
               ;; An increment may depend on the guard's bound without reading it.
               (when shift-increments
                 (dolist (block (gethash id (cdr shift-increments))) (enqueue block))))
             (merge-type (id type)
               (let ((joined (mir-type-join (svref types id) type)))
                 (when (and (hir-range-p (svref types id)) (hir-range-p joined)
                            (not (equal joined (svref types id))))
                   (incf (svref changes id))
                   (when (>= (svref changes id) 2) (setf joined (hir-widen-integer-type joined))))
                 (unless (equal joined (svref types id))
                   (setf (svref types id) joined) (enqueue-users id))))
             (merge-packet (id packet)
               (unless (svref packet-changes id)
                 (setf (svref packet-changes id) (make-array +mir-values-prefix-limit+ :initial-element 0)))
               (let ((joined (mir-join-values (svref packets id) packet (svref packet-changes id))))
                 (unless (equalp joined (svref packets id))
                   (setf (svref packets id) joined) (enqueue-users id))))
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
                                  (or (and (eq name 'make-array)
                                           (mir-specialized-vector-constructor-type args (svref inputs 0) definitions))
                                      (when (and shift-guards (eq name '-) (= (length args) 2)
                                                 (hir-fixnum-type-p (svref inputs 0)))
                                        (let ((index (mir-primary-origin (svref args 1) definitions)))
                                          ;; Use the relation in the receiving block,
                                          ;; where neither input can have been rebound.
                                          (when (and
                                                 (= (mir-value-block (svref values (mir-instruction-result instruction)))
                                                    (mir-value-block (svref values index)))
                                                 (eql (mir-primary-origin (svref args 0) definitions)
                                                      (gethash index shift-guards)))
                                            (hir-integer-range 0 +hir-fixnum-max+))))
                                      (when shift-increments
                                        (let ((source (gethash (mir-instruction-result instruction)
                                                               (car shift-increments))))
                                          (when source
                                            (let ((source-type (svref types source)))
                                              (cond ((eq source-type :unseen) :unseen)
                                                    ;; The guard proves index <= floor(source / 2).
                                                    ((hir-fixnum-type-p source-type)
                                                     (hir-integer-range 1 (1+ (ash +hir-fixnum-max+ -1)))))))))
                                      (inferred-call-type name inputs))))
                            t)))
                   ((7 15) (let ((target (and functions (svref functions (svref args 0)))))
                        (cond ((eq target :unseen) :unseen)
                              ((and summaries (integerp target)) (svref summaries target))
                              (t t))))
                   (14 (if (zerop (mir-instruction-data instruction)) (svref types (svref args 0))
                           (mir-values-ref-type (svref packets (svref args 0))
                                                (mir-instruction-data instruction))))
                   (otherwise t)))))
      (loop for block across blocks when (logbitp (mir-block-id block) reachable)
            do (enqueue (mir-block-id block)))
      (loop for cursor from 0 while (< cursor (hir-buffer-count work))
            for block-id = (mir-at work cursor)
            for block = (svref blocks block-id)
            do (setf (svref queued block-id) nil)
               (loop for id across (hir-buffer-view (mir-block-instructions block))
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
                            (or (and induction (svref induction parameter))
                                (if (eq input :unseen) :unseen
                                    (mir-edge-type (mir-block-terminator block) (zerop index)
                                                   argument input definitions types))))
                          (when (eq (mir-value-representation (mir-at (mir-function-values function) parameter)) :bundle)
                            (merge-packet parameter (svref packets argument)))))))
    ;; Unreachable definitions and cyclic facts with no seed prove nothing.
    (when finalize
      (dotimes (id (length types))
        (when (eq (svref types id) :unseen) (setf (svref types id) t))))
    (values types packets)))

(defun mir-local-type-facts (function)
  "Share the two results of one local type and multiple-value fixed point."
  (mir-analysis function :type-facts
    (lambda (function)
      (multiple-value-bind (types packets) (mir-compute-types function)
        (cons types packets)))))

(defun mir-unit-local-types-p (unit)
  (mir-unit-analysis unit :local-types
    (lambda (unit)
      ;; Each function can derive its own types when there are only
      ;; named calls and there is no captured state or cell aliasing.
      (loop for function across (hir-buffer-view (mir-unit-functions unit))
            always
            (and (zerop (length (mir-function-captures function)))
                 (zerop (mir-function-internal-prefix function))
                 (notany (lambda (instruction)
                           (member (mir-instruction-kind instruction) '(7 15 19 20 21)))
                         (hir-buffer-view (mir-function-instructions function))))))))

(defun mir-local-analysis-only-p (unit function)
  (and unit
       (if (= (hir-buffer-count (mir-unit-functions unit)) 1)
           (notany (lambda (instruction) (member (mir-instruction-kind instruction) '(5 23)))
                   (hir-buffer-view (mir-function-instructions function)))
           (mir-unit-local-types-p unit))))

(defun mir-infer-types (function &optional unit)
  "Return SSA types, using local call summaries when UNIT is supplied."
  (if unit
      (svref (mir-call-analysis-types (mir-infer-calls unit)) (mir-function-id function))
      (car (mir-local-type-facts function))))

(defun mir-infer-value-facts (function &optional unit)
  "Return bundle facts indexed by SSA value ID."
  (if unit
      (svref (mir-call-analysis-packets (mir-infer-calls unit)) (mir-function-id function))
      (cdr (mir-local-type-facts function))))

(defun mir-check-proven-p (instruction types)
  (and (= (mir-instruction-kind instruction) 11)
       (hir-declaration-proven-p
        (svref types (svref (mir-instruction-operands instruction) 0))
        (mir-instruction-data instruction))))
