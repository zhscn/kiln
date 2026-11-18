(in-package #:kiln.kir)

;;;; Nested source expressions do not declare operand representations.
;;;; Exposing their inputs as typed variables lets the backend check each
;;;; operation before choosing layouts or instructions.

(defparameter *lir-operation-signatures*
  (let ((table (make-hash-table :test 'eq)))
    (dolist (operation +backend-lir-operations+ table)
      (setf (gethash (first operation) table) (rest operation)))))

(defparameter *lir-store-signatures*
  (let ((table (make-hash-table :test 'eq)))
    (dolist (operation +backend-lir-stores+ table)
      (setf (gethash (first operation) table) (second operation)))))

(defvar *lir-view-hint* nil)

(defvar *lir-name-test* 'equalp)

(defun make-lir-name-table ()
  (make-hash-table :test *lir-name-test*))

(defstruct (lir-variable (:constructor make-lir-variable (name representation)))
  name representation (constant-word nil))

(defstruct lir-function
  name data compatibility-variables
  (variables-by-id (make-array 8 :initial-element nil) :type simple-vector)
  (views (make-lir-name-table))
  (view-primaries (make-lir-name-table))
  (value-aliases (make-lir-name-table))
  (handler-regions (make-lir-name-table))
  (region-landings (make-lir-name-table))
  (region-kinds (make-lir-name-table))
  landing-view
  (region-tags (make-lir-name-table))
  (stack-root-objects (make-lir-name-table))
  (stack-shapes (make-lir-name-table))
  (closure-entries (make-lir-name-table))
  rest rest-slots rest-regions
  active-view active-count (block-constants nil)
  (variables '()) (temporaries '()) (statements '()) (blocks '())
  (receive 0) (received-p nil) (captures 0) (counter 0))

(defun lir-function-error (state control &rest arguments)
  (error "LIR function ~A: ~A" (lir-function-name state) (apply #'format nil control arguments)))

(defun lir-variable-index (name)
  (when (kvar-p name)
    (let ((id (svref name 1)))
      (when (typep id '(integer 0 #.(ash most-positive-fixnum -1)))
        (case (svref name 0)
          (#\v (* 2 id))
          (#\l (1+ (* 2 id))))))))

(defun lir-variable-entry (state name)
  (let ((compatibility (lir-function-compatibility-variables state)))
    (if compatibility
        (gethash name compatibility)
        (let ((index (lir-variable-index name))
              (kinds (lir-function-variables-by-id state)))
          (when (and index (< index (length kinds)))
            (let ((entry (svref kinds index)))
              (when (and entry (eq name (lir-variable-name entry)))
                entry)))))))

(defun lir-variable-kind (state name)
  (let ((entry (lir-variable-entry state name)))
    (when entry (lir-variable-representation entry))))

(defun lir-require-variable (state name)
  (or (lir-variable-entry state name)
      (lir-function-error state "undeclared variable ~S" name)))

(defun lir-register-variable (state name kind)
  (let ((compatibility (lir-function-compatibility-variables state)))
    (if compatibility
        (setf (gethash name compatibility) (make-lir-variable name kind))
        (let ((index (lir-variable-index name))
              (kinds (lir-function-variables-by-id state)))
          (unless index (lir-function-error state "invalid variable name ~S" name))
          (unless (< index (length kinds))
            (setf kinds (replace (make-array (max (1+ index) (* 2 (length kinds))) :initial-element nil)
                                 kinds)
                  (lir-function-variables-by-id state) kinds))
          (setf (svref kinds index) (make-lir-variable name kind))))))

(defun lir-new-temporary (state kind)
  (let ((name (vector #\l (incf (lir-function-counter state)) kind nil)))
    (lir-register-variable state name kind)
    (push (list name kind) (lir-function-temporaries state))
    name))

(defun lir-emit (state statement)
  (push statement (lir-function-statements state)))

(defun lir-class-name (class)
  (cond ((eql class +packet-class-fixnum+) :fixnum)
        ((eql class +packet-class-cons+) :cons)
        ((eql class +packet-class-character+) :character)
        ((eql class +packet-class-single-float+) :single-float)
        ((eql class +packet-class-symbol+) :symbol)
        ((eql class +packet-class-function+) :function)
        ((eql class +packet-class-simple-vector+) :simple-vector)
        ((eql class +packet-class-string+) :string)
        ((eql class +packet-class-bignum+) :bignum)
        ((eql class +packet-class-ratio+) :ratio)
        ((eql class +packet-class-double+) :double-float)
        ((eql class +packet-class-instance+) :standard-instance)
        ((eql class +packet-class-funcallable-instance+) :funcallable-instance)
        ((eql class +packet-class-complex+) :complex)
        ((eql class +packet-class-structure-instance+) :structure-instance)
        (t (error "Unknown representation class ~S" class))))

(defun lir-field-name (field)
  (cond ((eql field +packet-field-cons-car+) :cons.car)
        ((eql field +packet-field-cons-cdr+) :cons.cdr)
        ((eql field +packet-field-symbol-name+) :symbol.name)
        ((eql field +packet-field-symbol-package+) :symbol.package)
        ((eql field +packet-field-symbol-function+) :symbol.function)
        ((eql field +packet-field-symbol-value+) :symbol.value)
        ((eql field +packet-field-symbol-plist+) :symbol.plist)
        ((eql field +packet-field-symbol-setf-function+) :symbol.setf-function)
        ((eql field +packet-field-complex-real+) :complex.real)
        ((eql field +packet-field-complex-imag+) :complex.imag)
        (t (error "Field ~S is not an object reference field" field))))

(defun lir-expression-kind (state expression &optional (variable-kind (lir-variable-kind state expression)))
  (or variable-kind
      (cond ((integerp expression) nil)
            ((eq expression :self) :obj)
            ((consp expression)
             (let ((op (first expression)))
               (case op
                 ((:object-address :object-data :literal-ref :cell-ref :closure-ref
                   :unbound-value :unbound-slot-value :frame-pointer :secondary-value-ref :landing-value) :obj)
                 (:word :word) (:f64 :f64)
                 ((:fixnum :character :single-float) :obj)
                 (:field-load (if (eql (second expression) +packet-field-double-bits+) :f64 :obj))
                 ((:eq :ne :lt :le :gt :ge :test-class) :word)
                 (:select (or (lir-expression-kind state (third expression))
                              (lir-expression-kind state (fourth expression))))
                 ((:add :sub :mul :and :or :xor)
                  (or (lir-expression-kind state (second expression))
                      (lir-expression-kind state (third expression)) :word))
                 ((:shl :shr :sar :shlv :sarv :sdiv :srem) :word)
                 (t (second (gethash op *lir-operation-signatures*)))))))
      ;; Signatures contain the input list and the result type.
      (and (consp expression)
           (second (gethash (first expression) *lir-operation-signatures*)))))

(defun lir-operand (state expression kind)
  (let ((variable-kind (lir-variable-kind state expression)))
    (if (eq variable-kind kind)
        expression
        (let* ((value (lir-expression state expression kind variable-kind))
               ;; A fresh immediate temporary dominates subsequent uses in
               ;; this block only. Mutable cells and computed values cannot
               ;; share this cache.
               (cache (when (and (consp value)
                                 (member (first value) '(:nil :t :fixnum :word :f64 :character
                                                         :single-float :constant :literal :unbound
                                                         :unbound-slot)))
                        (or (lir-function-block-constants state)
                            (setf (lir-function-block-constants state) (make-hash-table :test 'equal))))))
          (or (and cache (gethash value cache))
              (let ((result (lir-new-temporary state kind)))
                (lir-emit state (list :set result value))
                (when cache (setf (gethash value cache) result))
                result))))))

(defun lir-pure-expression (state operation arguments)
  (let ((signature (gethash operation *lir-operation-signatures*)))
    (unless signature (lir-function-error state "unknown pure operation ~S" operation))
    (unless (= (length arguments) (length (first signature)))
      (lir-function-error state "wrong operand count for ~S" operation))
    (cons operation (mapcar (lambda (argument kind) (lir-operand state argument kind))
                           arguments (first signature)))))

(defun lir-comparison-kind (state left right)
  (let ((kind (or (lir-expression-kind state left) (lir-expression-kind state right) :word)))
    (if (eq kind :f64) :word kind)))

(defun lir-expression (state expression expected
                       &optional (variable-kind (lir-variable-kind state expression)))
  (let ((actual (lir-expression-kind state expression variable-kind)))
    (when (and actual (not (eq actual expected)))
      (return-from lir-expression
        (cond ((and (eq actual :f64) (eq expected :word))
               (lir-pure-expression state :f64-bits (list expression)))
              ((and (eq actual :word) (eq expected :f64))
               (lir-pure-expression state :f64-from-bits (list expression)))
              (t (lir-function-error state "expected ~S, got ~S from ~S" expected actual expression)))))
    (cond (variable-kind expression)
          ((integerp expression)
           (case expected
             (:word `(:word ,expression)) (:f64 `(:f64 ,expression))
             (:obj (lir-function-error state "object immediate needs a semantic descriptor: ~S" expression))
             (t (lir-function-error state "invalid constant representation ~S" expected))))
          ((eq expression :self) '(:self))
          ((not (consp expression)) (lir-function-error state "unknown operand ~S" expression))
          (t
           (let ((op (first expression)) (args (rest expression)))
             (case op
               ((:word :f64 :fixnum :character :single-float) expression)
               ((:object-address :object-data)
                (lir-object-reference (lir-function-data state) (first args)))
               (:literal-ref (cons :literal args))
               (:cell-ref
                (let ((index (lir-cell-index (lir-function-data state) (first args))))
                  (unless index (lir-function-error state "unknown cell ~S" (first args)))
                  `(:cell-ref ,index)))
               (:unbound-value '(:unbound)) (:unbound-slot-value '(:unbound-slot))
               (:frame-pointer '(:frame-pointer))
               (:select
                (let ((*lir-view-hint* (or (lir-condition-view state (first args)) *lir-view-hint*)))
                  `(:select ,(lir-operand state (first args) :word)
                            ,(lir-operand state (second args) expected)
                            ,(lir-operand state (third args) expected))))
               (:landing-value
                (unless (lir-function-landing-view state)
                  (lir-function-error state "value has no landing view"))
                `(:mv-ref ,(lir-function-landing-view state) 0))
               (:secondary-value-ref
                (let ((view (or *lir-view-hint* (lir-function-active-view state))))
                  (unless (and view (integerp (first args)))
                    (lir-function-error state "secondary value needs an active view and a fixed index"))
                  `(:mv-ref ,view ,(first args))))
               (:test-class `(:test ,(lir-class-name (first args)) ,(lir-operand state (second args) :obj)))
               (:field-load
                (if (eql (first args) +packet-field-double-bits+)
                    (lir-pure-expression state :unbox-double (rest args))
                    `(:field-ref ,(lir-field-name (first args)) ,(lir-operand state (second args) :obj))))
               (:closure-ref
                (unless (and (lir-primary-alias-p state (first args) :self)
                             (integerp (second args)) (<= 0 (second args)))
                  (lir-function-error state "capture read needs self and a fixed index"))
                (unless (< (second args) (lir-function-captures state))
                  (lir-function-error state "capture index is outside the declared shape"))
                `(:capture-ref ,(second args)))
               ((:eq :ne :lt :le :gt :ge)
                (let* ((kind (lir-comparison-kind state (first args) (second args)))
                       (operation (if (eq kind :obj)
                                      (ecase op (:eq :eq) (:ne :ne) (:lt :fixnum-lt) (:le :fixnum-le)
                                                (:gt :fixnum-gt) (:ge :fixnum-ge))
                                      (ecase op (:eq :word-eq) (:ne :word-ne) (:lt :word-lt) (:le :word-le)
                                                (:gt :word-gt) (:ge :word-ge)))))
                  (lir-pure-expression state operation args)))
               ((:add :sub :mul :and :or :xor)
                (if (eq expected :f64)
                    (lir-pure-expression state :f64-from-bits
                      (list (cons (ecase op (:add :word-add) (:sub :word-sub) (:mul :word-mul)
                                           (:and :word-and) (:or :word-or) (:xor :word-xor)) args)))
                    (lir-pure-expression state
                      (if (eq expected :obj)
                          (ecase op (:add :fixnum-add) (:sub :fixnum-sub) (:mul :fixnum-mul)
                                    (:and :fixnum-logand) (:or :fixnum-logior) (:xor :fixnum-logxor))
                          (ecase op (:add :word-add) (:sub :word-sub) (:mul :word-mul)
                                    (:and :word-and) (:or :word-or) (:xor :word-xor))) args)))
               ((:shl :shr :sar :shlv :sarv :sdiv :srem)
                (lir-pure-expression state
                  (ecase op ((:shl :shlv) :word-shift-left) (:shr :word-shift-right-logical)
                            ((:sar :sarv) :word-shift-right) (:sdiv :word-quotient) (:srem :word-remainder)) args))
               (t (lir-pure-expression state op args))))))))

(defun lir-check-handler (state handler)
  (unless (member handler '(nil :nil))
    (or (gethash handler (lir-function-handler-regions state))
        (lir-function-error state "unknown source handler ~S" handler))))

(defun lir-handler-options (state handler)
  (let ((region (lir-check-handler state handler)))
    (and region `((:region ,region)))))

(defun lir-return-count (state count)
  (if (integerp count) count
      (let* ((entry (lir-variable-entry state count))
             (value (and entry (lir-variable-constant-word entry))))
        (if (integerp value) value
            (lir-function-error state "return needs a multi-value view for count ~S" count)))))

(defun lir-statement (state statement)
  (let ((op (first statement)) (args (rest statement)))
    (let ((types (gethash op *lir-store-signatures*)))
      (when types
        (unless (= (length args) (length types))
          (lir-function-error state "wrong operand count for ~S" op))
        (lir-emit state `(,op ,@(mapcar (lambda (argument type) (lir-operand state argument type)) args types)))
        (return-from lir-statement)))
    (case op
      ((:invoke :invoke-known :invoke-list :numeric-op) (lir-call-statement state statement))
      ((:move-values :publish-values :save-values :values-list :push-values :list-values :restore-values)
       (lir-value-statement state statement))
      (:runtime-op
       (unless (= (length (third args)) (kiln.lir:runtime-signature (second args)))
         (lir-function-error state "wrong operand count for runtime operation ~S" (second args)))
       (lir-check-handler state (fourth args))
       (lir-emit state `(:runtime ,(first args) ,(second args)
                          ,(mapcar (lambda (argument) (lir-operand state argument :obj)) (third args))
                          ,@(lir-handler-options state (fourth args)) ,@(cddddr args))))
      (:tail-invoke
       (lir-emit state `(:tail-call ,(lir-operand state (first args) :obj)
                                   ,(mapcar (lambda (argument) (lir-operand state argument :obj)) (second args)))))
      ((:ensure-tls-index :dynamic-enter :special-bind-index :special-unbind :dynamic-leave
        :lir-landing :landed-values :unwind-values :continue-unwind :dynamic-relink :progv-restore)
       (lir-region-statement state statement))
      ((:alloc-closure :closure-set) (lir-closure-statement state statement))
      ((:stack-object-init :stack-roots-enter :stack-roots-leave :stack-cons :stack-closure :rest-list)
       (lir-stack-statement state statement))
      (:alloc-rack
       (lir-check-handler state (fourth args))
       (lir-emit state `(:alloc-rack ,(first args) ,(lir-operand state (second args) :obj)
                         ,(lir-operand state (third args) :word))))
      (:alloc-funcallable
       (lir-check-handler state (third args))
       (lir-emit state `(:alloc-funcallable ,(first args) ,(lir-operand state (second args) :obj))))
      (:alloc-symbol
       (lir-check-handler state (third args))
       (lir-emit state `(:alloc-symbol ,(first args) ,(lir-operand state (second args) :obj))))
      (:alloc-undefined-function
       (lir-check-handler state (fourth args))
       (lir-emit state `(:alloc-undefined-function ,(first args)
                         ,(lir-operand state (second args) :obj) ,(third args))))
      (:alloc-vector
       (lir-check-handler state (fifth args))
       (let* ((kind (lir-class-name (second args)))
              (initial (fourth args)))
         (unless (member kind '(:simple-vector :string))
           (lir-function-error state "unsupported sequence allocation class ~S" (second args)))
         (lir-emit state `(:alloc-sequence ,(first args) ,kind
                           ,(lir-operand state (third args) :word)
                           ,(lir-operand state (if (eq kind :string) `(:character-tag ,initial) initial) :obj)))))
      (:alloc-vector-elements
       (lir-check-handler state (third args))
       (lir-emit state `(:vector ,(first args)
                         ,(mapcar (lambda (value) (lir-operand state value :obj)) (second args)))))
      (:alloc-structure
       (lir-check-handler state (fourth args))
       (lir-emit state `(:alloc-structure ,(first args)
                         ,(lir-operand state (second args) :obj)
                         ,(lir-operand state (third args) :word)
                         ,(lir-operand state '(:fixnum 0) :obj))))
      (:alloc-fixed
       (lir-check-handler state (fourth args))
       (multiple-value-bind (kind types)
           (cond ((eql (second args) +packet-class-cons+) (values :cons '(:obj :obj)))
                 ((eql (second args) +packet-class-double+) (values :double-float '(:f64)))
                 ((eql (second args) +packet-class-complex+) (values :complex '(:obj :obj)))
                 ((eql (second args) +packet-class-instance+) (values :standard-instance '(:obj)))
                 (t (lir-function-error state "unsupported fixed allocation class ~S" (second args))))
         (unless (= (length types) (length (third args)))
           (lir-function-error state "wrong fixed allocation field count"))
         (lir-emit state `(:alloc ,(first args) ,kind :heap
                            ,(mapcar (lambda (argument type) (lir-operand state argument type)) (third args) types)))))
      (:lir-set
       (lir-emit state (list :set (first args) (second args))))
      (:set
       (let ((kind (lir-variable-kind state (first args))))
         (unless kind (lir-function-error state "assignment to undeclared variable ~S" (first args)))
         (lir-emit state `(:set ,(first args) ,(lir-expression state (second args) kind)))))
      (:receive-prefix
       (when (lir-function-received-p state) (lir-function-error state "duplicate incoming prefix"))
       (setf (lir-function-received-p state) t (lir-function-receive state) (length (first args)))
       (lir-emit state `(:set ,(second args) (:arg-count)))
       (loop for variable in (first args) for index from 0
             do (lir-emit state `(:set ,variable (:arg-ref ,index)))))
      (:poll
       (lir-check-handler state (second args))
       (ecase (first args) (:loop (lir-emit state '(:poll)))
                           ((:entry :entry-retry :entry-retry-image) nil)))
      (:heap-number-p
       (lir-emit state `(:set ,(first args) ,(lir-pure-expression state :heap-number-p (rest args)))))
      (:guarded-class-test
       (lir-emit state `(:set ,(first args) (:test ,(lir-class-name (second args))
                                                  ,(lir-operand state (third args) :obj)))))
      ((:fixnum-add-ovf :fixnum-sub-ovf :fixnum-mul-ovf)
       (lir-emit state `(,op ,(first args) ,(second args)
                            ,(lir-operand state (third args) :obj) ,(lir-operand state (fourth args) :obj))))
      (:special-ref
       (lir-emit state `(:set ,(first args) (:special-ref ,(lir-operand state (second args) :obj)))))
      (:special-set
       (lir-emit state `(:special-set ,(lir-operand state (first args) :obj)
                                     ,(lir-operand state (second args) :obj))))
      (:field-store
       (lir-emit state `(:field-set ,(lir-field-name (first args))
                                   ,(lir-operand state (second args) :obj)
                                   ,(lir-operand state (third args) :obj))))
      (:cell-set
       (let ((index (lir-cell-index (lir-function-data state) (first args))))
         (unless index (lir-function-error state "unknown cell ~S" (first args)))
         (lir-emit state `(:cell-set ,index ,(lir-operand state (second args) :obj)))))
      (:jump (lir-emit state statement))
      (:br (lir-emit state `(:branch ,(lir-operand state (first args) :word) ,@(rest args))))
      (:switch (lir-emit state `(:switch ,(lir-operand state (first args) :word) ,(second args) ,@(third args))))
      (:return
       (let ((view (gethash (second args) (lir-function-views state))))
         (cond (view
                (lir-view-for-values state (first args) (second args))
                (lir-emit state `(:return-mv ,view)))
               ((and (integerp (second args)) (> (second args) 1))
                (lir-emit state `(:return-mv ,(lir-view-for-values state (first args) (second args)))))
               (t (case (lir-return-count state (second args))
                    (0 (lir-emit state '(:return ())))
                    (1 (lir-emit state `(:return (,(lir-operand state (first args) :obj)))))
                    (t (lir-function-error state "multiple-value return needs a view")))))))
      (:signal-error
       (lir-check-handler state (third args))
       (lir-emit state `(:error ,(first args) ,(lir-operand state (second args) :obj) ,@(cdddr args))))
      (:fatal-error
       (lir-emit state `(:fatal-error ,(lir-operand state (first args) :word)
                                     ,(lir-operand state (second args) :obj) ,@(cddr args))))
      (:trap (lir-emit state statement))
      (t (lir-function-error state "unsupported statement ~S" statement)))))

(defun lir-static-vector (data word)
  (unless (and (consp word) (eq (first word) :object-data))
    (lir-data-error "debug metadata needs a vector reference"))
  (let ((object (lir-static-object data (second word))))
    (unless (and (consp object) (eq (first object) :static-vector))
      (lir-data-error "debug metadata needs vector data"))
    (rest object)))

(defun lir-debug-variable (state variable word)
  (let* ((data (lir-function-data state))
         (object (and (consp word) (eq (first word) :object-data)
                      (lir-static-object data (second word)))))
    (if (and (consp object) (eq (first object) :static-cons))
        (let* ((tag (lir-static-object data (second (second object))))
               (name (cond ((static-symbol-p tag) (static-symbol-name tag))
                           ((and (consp tag) (eq (first tag) :static-symbol))
                            (lir-data-string data (second tag)))))
               (tail (lir-static-object data (second (third object)))))
          (unless (and (consp tail) (eq (first tail) :static-cons)
                       (lir-nil-word-p (third tail)) (member name '("CELL" "DOUBLE-BITS") :test #'equal))
            (lir-function-error state "invalid debug variable descriptor ~S" word))
          `(,variable ,(lir-data-value data (second tail)) ,@(and (equal name "CELL") '(:cell))))
        `(,variable ,(lir-data-value data word)))))

(defun lir-image-debug-variable (state variable description)
  (let ((name description) (cell nil))
    (when (consp description)
      (unless (and (= (length description) 2) (member (first description) '(:cell :double-bits)))
        (lir-function-error state "invalid image variable description ~S" description))
      (setf name (second description) cell (eq (first description) :cell))
      (unless (eq (lir-variable-kind state variable) (if cell :obj :f64))
        (lir-function-error state "debug variable representation disagrees with ~S" description)))
    `(,variable ,(lir-image-value (lir-function-data state) name) ,@(and cell '(:cell)))))

(defun lir-image-debug (state form declarations)
  (let* ((data (lir-function-data state)) (source (lir-data-literal-source data)) (index (second form)))
    (unless (and source (integerp index) (<= 0 index) (< index (length source)))
      (lir-function-error state "image debug index needs valid literal bindings"))
    (let ((record (svref source index)))
      (unless (and (simple-vector-p record) (= (length record) 5))
        (lir-function-error state "image debug record needs five fields"))
      (let ((names (svref record 4)))
        (unless (or (null names) (simple-vector-p names))
          (lir-function-error state "image debug variable names need a vector"))
        `(:debug ,(lir-image-value data (svref record 0)) ,(lir-image-value data (svref record 1))
                 ,(or (svref record 2) 0) ,(or (svref record 3) 0)
                 ,(loop for declaration in declarations for label = (third declaration)
                        when label
                          collect (progn
                                    (unless (and names (integerp label) (<= 0 label) (< label (length names)))
                                      (lir-function-error state "image debug variable index is out of range"))
                                    (lir-image-debug-variable state (first declaration) (svref names label)))))))))

(defun lir-function-debug (state form declarations)
  (when form
    (when (eq (first form) :debug-literal)
      (return-from lir-function-debug (lir-image-debug state form declarations)))
    (unless (eq (first form) :debug)
      (lir-function-error state "unknown debug metadata ~S" form))
    (let* ((data (lir-function-data state)) (fields (lir-static-vector data (second form)))
           (names (unless (lir-nil-word-p (fifth fields)) (lir-static-vector data (fifth fields)))))
      (unless (= (length fields) 5) (lir-function-error state "debug vector needs five fields"))
      (flet ((position-value (word)
               (cond ((lir-nil-word-p word) 0) ((eq (first word) :fixnum) (second word))
                     (t (lir-function-error state "invalid source position ~S" word)))))
        `(:debug ,(lir-data-value data (first fields)) ,(lir-data-value data (second fields))
                 ,(position-value (third fields)) ,(position-value (fourth fields))
                 ,(loop for declaration in declarations
                        when (third declaration)
                          collect (lir-debug-variable state (first declaration) (nth (third declaration) names))))))))

(defun lir-record-word-write (state variable value)
  (let* ((entry (lir-require-variable state variable))
         (old (lir-variable-constant-word entry)))
    (setf (lir-variable-constant-word entry)
          (if (and (integerp value) (or (null old) (eql old value))) value :unknown))))

(defun normalize-lir-function (data function)
  "Lower a function builder or a compatibility function form to LIR."
  (if (kfunc-p function)
      (lower-lir-function data (kfunc-name function)
                          (kfunc-vars function)
                          (kfunc-slots function) (kfunc-debug function) (kfunc-blocks function)
                          :direct-regions (kfunc-direct-regions-p function)
                          :region-entries (kfunc-region-entries function)
                          :region-landings (kfunc-region-landings function))
      (let ((parts (cddr function)) (blocks nil))
        (dolist (part parts)
          (case (first part)
            (:block (push (make-kblock :name (second part) :stmts (cddr part)) blocks))
            ((:vars :slots :debug :debug-literal) nil)
            (t (error "LIR function ~A: unknown function declaration ~S" (second function) part))))
        (lower-lir-function data (second function) (rest (assoc :vars parts))
                            (rest (assoc :slots parts)) (source-function-debug function)
                            (nreverse blocks) :compatibility t))))

(defun lir-scan-function-statement (state statement)
  (lir-scan-value-statement state statement)
  (case (first statement)
    ((:alloc-closure :stack-closure) (lir-scan-closure-statement state statement))
    ((:set :lir-set) (lir-record-word-write state (second statement) (third statement)))
    (:receive-prefix
     (dolist (variable (second statement))
       (lir-record-word-write state variable :unknown))
     (lir-record-word-write state (third statement) :unknown))
    ((:fixnum-add-ovf :fixnum-sub-ovf :fixnum-mul-ovf)
     (lir-record-word-write state (second statement) :unknown)
     (lir-record-word-write state (third statement) :unknown))
    ((:heap-number-p :guarded-class-test :special-ref)
     (lir-record-word-write state (second statement) :unknown))))

(defun lower-lir-function (data name source-variables source-slots source-debug source-blocks
                           &key compatibility direct-regions region-entries region-landings)
  (let* ((*lir-name-test* (if compatibility 'equalp 'eq))
         (state (make-lir-function :name name :data data
                  :compatibility-variables (when compatibility (make-lir-name-table)))))
    (multiple-value-bind (blocks slots live)
        (lir-reachable-blocks state
          (if (or compatibility source-slots)
              (lir-prepare-landings state source-blocks direct-regions region-landings)
              source-blocks)
          source-slots)
      (let ((prepare-storage (or compatibility slots)))
        (setf (lir-function-captures state)
              (or (gethash name (lir-data-function-captures data)) 0))
        (dolist (variable source-variables)
          (let* ((name (if compatibility (first variable) variable))
                 (source-kind (if compatibility (second variable) (svref variable 2)))
                 (kind (ecase source-kind (:obj :obj) (:raw :word) (:f64 :f64))))
            (lir-register-variable state name kind)
            (push (list name kind) (lir-function-variables state))))
        (let ((storage (cond (prepare-storage
                             (append (lir-prepare-stack state blocks slots)
                                     (if direct-regions
                                         (lir-declare-emitted-regions state region-entries slots live)
                                         (lir-prepare-regions state blocks slots))))
                            (t (dolist (block blocks)
                                 (dolist (statement (kblock-stmts block))
                                   (lir-scan-function-statement state statement)
                                   (when (eq (first statement) :rest-list)
                                     (lir-record-rest state statement))))
                               nil))))
          (dolist (block blocks)
            (setf (lir-function-statements state) '()
                  (lir-function-active-view state) nil (lir-function-active-count state) nil
                  (lir-function-landing-view state) nil
                  (lir-function-block-constants state) nil)
            (dolist (statement (kblock-stmts block)) (lir-statement state statement))
            (push (list* :block (kblock-name block) (nreverse (lir-function-statements state)))
                  (lir-function-blocks state)))
          (let* ((debug-variables
                   (if compatibility source-variables
                       (loop for variable in source-variables
                             when (svref variable 3) collect (var-declaration variable))))
                 (debug (lir-function-debug state source-debug debug-variables)))
            `(:function ,(lir-function-name state) (:receive ,(lir-function-receive state))
              (:captures ,(lir-function-captures state))
              ,@(and (lir-function-rest state) (list (lir-function-rest state)))
              (:vars ,@(nreverse (lir-function-variables state)) ,@(nreverse (lir-function-temporaries state)))
              ,@storage
              ,@(and debug (list debug))
              ,@(nreverse (lir-function-blocks state)))))))))

(defun normalize-lir-module (module &optional literals)
  "Returns an independent LIR program and its literal bindings."
  (let* ((data (collect-lir-data module literals))
         (functions (mapcar (lambda (function) (normalize-lir-function data function))
                            (reverse (kmodule-functions module)))))
    (values `(:lir-module ,(kmodule-name module) ,@(lir-data-declarations data) ,@functions)
            (lir-literal-bindings data))))
