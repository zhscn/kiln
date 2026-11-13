(in-package #:kiln.kir)

;;;; Static labels can refer forward or form cycles, so references cannot
;;;; recursively emit their targets. Assign indices first, then translate
;;;; fields into the independent backend's constant graph.

(defstruct lir-data
  name init
  (objects (make-hash-table :test 'equal))
  (indices (make-hash-table :test 'equal))
  (cell-indices (make-hash-table :test 'equal))
  (mutable (make-hash-table :test 'equal))
  (constants '()) (cells '()) (builtins '()) (literals 0)
  literal-source
  (literal-extra '())
  (literal-indices (make-hash-table :test 'eq)))

(defun lir-data-error (control &rest arguments)
  (error "LIR module data: ~A" (apply #'format nil control arguments)))

(defun lir-nil-word-p (word)
  (equal word '(:object-data "kiln_nil" :general)))

(defun lir-data-string (data reference)
  (unless (and (consp reference) (eq (first reference) :object-data))
    (lir-data-error "expected a string reference, got ~S" reference))
  (let ((object (gethash (second reference) (lir-data-objects data))))
    (unless (eq (first object) :static-string)
      (lir-data-error "expected string data for ~S" reference))
    (coerce (mapcar #'code-char (rest object)) 'string)))

(defun lir-data-value (data word)
  "Translates an object initializer to an immediate, literal or graph reference."
  (cond ((not (consp word)) (lir-data-error "invalid object initializer ~S" word))
        ((member (first word) '(:fixnum :character :single-float :literal :unbound)) word)
        ((eq (first word) :object-data)
         (cond ((lir-nil-word-p word) '(:nil))
               ((equal word '(:object-data "kiln_t" :general)) '(:t))
               (t (multiple-value-bind (index found) (gethash (second word) (lir-data-indices data))
                    (unless found (lir-data-error "unknown object reference ~S" word))
                    `(:constant ,index)))))
        (t (lir-data-error "unsupported object initializer ~S" word))))

(defun lir-data-symbol (data label fields)
  (destructuring-bind (name package function value plist setf-function) fields
    (flet ((placeholder-p (reference role)
             (and (consp reference) (eq (first reference) :object-data)
                  (equal (gethash (second reference) (lir-data-objects data))
                         `(:static-builtin ,role (:object-data ,label :general))))))
      (unless (and (placeholder-p function :undefined-function)
                   (placeholder-p setf-function :undefined-setf-function)
                   (lir-nil-word-p plist))
        (lir-data-error "symbol ~S has noncanonical initial function or property cells" label)))
    (let* ((name (lir-data-string data name))
           (package (unless (lir-nil-word-p package) (lir-data-string data package))))
      (unless (equal value (if (equal package "KEYWORD")
                              `(:object-data ,label :general) '(:unbound)))
        (lir-data-error "symbol ~S has a noncanonical initial value" label))
      (if package `(:symbol ,package ,name)
          `(:uninterned ,name ,(gethash label (lir-data-indices data)))))))

(defun lir-data-object (data label object)
  (let ((kind (first object)) (fields (rest object)))
    (case kind
      (:static-string (cons :string fields))
      (:static-integer (cons :bignum fields))
      (:static-double (cons :double-bits fields))
      (:static-function
       (unless (= (length fields) 1)
         (lir-data-error "static function ~S has captures" label))
       (cons :function fields))
      (:static-symbol (lir-data-symbol data label fields))
      ((:static-cons :static-mutable-cons :static-ratio :static-complex :static-vector)
       (cons (case kind
               (:static-cons (if (gethash label (lir-data-mutable data)) :mutable-cons :cons))
               (:static-mutable-cons :mutable-cons)
               (:static-ratio :ratio) (:static-complex :complex) (:static-vector :vector))
             (mapcar (lambda (word) (lir-data-value data word)) fields)))
      (t (lir-data-error "unsupported static object ~S" object)))))

(defun collect-lir-data (module &optional literals)
  "Builds indexed semantic data, retaining cycles and mutable cache identities."
  (when (kmodule-imports module)
    (lir-data-error "runtime imports must be selected by the backend"))
  (dolist (form (kmodule-import-data module))
    (unless (member (second form) '("kiln_nil" "kiln_t") :test #'equal)
      (lir-data-error "unsupported external object ~S" form)))
  (let ((data (make-lir-data :name (kmodule-name module)))
        (objects '()) (cells '()) (index 0) (cell-index 0) (literal-table nil))
    (dolist (root (kmodule-roots module))
      (unless (member (first root) '(:root :field-root :symbol-roots))
        (lir-data-error "unsupported root declaration ~S" root))
      (setf (gethash (second root) (lir-data-mutable data)) t))
    (dolist (form (reverse (kmodule-data module)))
      (case (first form)
        (:data
         (let ((name (second form)) (object (third form)))
           (when (gethash name (lir-data-objects data))
             (lir-data-error "duplicate data label ~S" name))
           (setf (gethash name (lir-data-objects data)) object)
           ;; Symbol constants construct their own placeholders in Rust.
           (unless (eq (first object) :static-builtin)
             (setf (gethash name (lir-data-indices data)) index)
             (incf index)
             (push (cons name object) objects))))
        (:object-cell
         (let ((name (second form)))
           (when (nth-value 1 (gethash name (lir-data-cell-indices data)))
             (lir-data-error "duplicate cell ~S" name))
           (setf (gethash name (lir-data-cell-indices data)) cell-index)
           (incf cell-index)
           (push (third form) cells)))
        (:literal-table
         (when literal-table (lir-data-error "duplicate literal table"))
         (setf literal-table t (lir-data-literals data) (second form)))
        (:builtin (push form (lir-data-builtins data)))
        (t (lir-data-error "unsupported module declaration ~S" form))))
    (when literals
      (unless (and (simple-vector-p literals) (= (length literals) (lir-data-literals data)))
        (lir-data-error "literal bindings disagree with the module declaration"))
      (setf (lir-data-literal-source data) literals)
      (loop for object across literals for index from 0
            unless (nth-value 1 (gethash object (lir-data-literal-indices data)))
              do (setf (gethash object (lir-data-literal-indices data)) index)))
    (let ((init (gethash (kmodule-init module) (lir-data-objects data))))
      (unless (and (eq (first init) :static-function) (= (length init) 2))
        (lir-data-error "module init must name a zero-capture function object"))
      (setf (lir-data-init data) (second init)))
    (maphash (lambda (name mutable)
               (declare (ignore mutable))
               (unless (or (gethash name (lir-data-objects data))
                           (nth-value 1 (gethash name (lir-data-cell-indices data))))
                 (lir-data-error "root names unknown data ~S" name)))
             (lir-data-mutable data))
    (setf (lir-data-constants data)
          (mapcar (lambda (entry) (lir-data-object data (car entry) (cdr entry))) (nreverse objects))
          (lir-data-cells data) (mapcar (lambda (word) (lir-data-value data word)) (nreverse cells))
          (lir-data-builtins data) (nreverse (lir-data-builtins data)))
    data))

(defun lir-image-value (data object)
  "References an image object, extending literal bindings without changing old indices."
  (cond ((null object) '(:nil)) ((eq object t) '(:t))
        (t
         (unless (lir-data-literal-source data)
           (lir-data-error "image object needs the original literal bindings"))
         (multiple-value-bind (index found) (gethash object (lir-data-literal-indices data))
           (unless found
             (setf index (lir-data-literals data)
                   (gethash object (lir-data-literal-indices data)) index)
             (incf (lir-data-literals data))
             (push object (lir-data-literal-extra data)))
           `(:literal ,index)))))

(defun lir-literal-bindings (data)
  (let ((source (lir-data-literal-source data)))
    (when (and (plusp (lir-data-literals data)) (not source))
      (lir-data-error "module normalization needs the literal bindings"))
    (concatenate 'simple-vector (or source #()) (reverse (lir-data-literal-extra data)))))

(defun lir-data-declarations (data)
  "Module declarations accepted by the independent LIR parser."
  (append (list `(:init ,(lir-data-init data)))
          (when (plusp (lir-data-literals data)) (list `(:literals ,(lir-data-literals data))))
          (lir-data-builtins data)
          (when (lir-data-constants data) (list (cons :constants (lir-data-constants data))))
          (when (lir-data-cells data) (list (cons :cells (lir-data-cells data))))))
