(in-package #:kiln.kir)

;;;; Static labels can refer forward or form cycles, so references cannot
;;;; recursively emit their targets. Assign indices first, then translate
;;;; fields into the independent backend's constant graph.

(defstruct lir-data
  name init
  ;; Constants use nonnegative IDs. Cells use -1 minus their ID so
  ;; both namespaces can share the builder's declaration table.
  declarations-by-name
  (mutable (make-hash-table :test 'equal))
  (function-captures (make-hash-table :test 'equal))
  (constants '()) (cells '()) (builtins '()) (literals 0)
  literal-source
  (literal-extra '())
  (literal-indices (make-hash-table :test 'eq)))

(defun lir-data-error (control &rest arguments)
  (error "LIR module data: ~A" (apply #'format nil control arguments)))

(defun lir-nil-word-p (word)
  (equal word '(:object-data "kiln_nil" :general)))

(defun lir-static-object (data label)
  (let ((entry (gethash label (lir-data-declarations-by-name data))))
    (when (module-data-entry-p entry)
      (let ((id (module-data-entry-index entry)))
        (unless (and id (minusp id))
          (module-data-entry-contents entry))))))

(defun lir-data-string (data reference)
  (unless (and (consp reference) (eq (first reference) :object-data))
    (lir-data-error "expected a string reference, got ~S" reference))
  (let ((object (lir-static-object data (second reference))))
    (cond ((stringp object) object)
          ((and (consp object) (eq (first object) :static-string))
           (coerce (mapcar #'code-char (rest object)) 'string))
          (t (lir-data-error "expected string data for ~S" reference)))))

(defun lir-constant-index (data label)
  (let ((id (module-data-index (lir-data-declarations-by-name data) label)))
    (when (and (integerp id) (>= id 0)) id)))

(defun lir-cell-index (data label)
  (let ((id (module-data-index (lir-data-declarations-by-name data) label)))
    (when (and (integerp id) (< id 0)) (- -1 id))))

(defun lir-object-reference (data label)
  (cond ((equal label "kiln_nil") '(:nil))
        ((equal label "kiln_t") '(:t))
        (t (let ((id (lir-constant-index data label)))
             (unless id (lir-data-error "unknown object reference ~S" label))
             (list :constant id)))))

(defun lir-data-value (data word)
  "Translates an object initializer to an immediate, literal or graph reference."
  (cond ((not (consp word)) (lir-data-error "invalid object initializer ~S" word))
        ((member (first word) '(:fixnum :character :single-float :literal :unbound)) word)
        ((eq (first word) :object-data)
         (lir-object-reference data (second word)))
        (t (lir-data-error "unsupported object initializer ~S" word))))

(defun lir-data-symbol (data label fields)
  (destructuring-bind (name package function value plist setf-function) fields
    (flet ((placeholder-p (reference role)
             (and (consp reference) (eq (first reference) :object-data)
                  (equal (lir-static-object data (second reference))
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
          `(:uninterned ,name ,(lir-constant-index data label))))))

(defun lir-string-constant (string)
  ;; The packet string pool accepts Unicode scalar values. The code-point
  ;; form also preserves characters outside that range on supporting hosts.
  (if (loop for character across string for code = (char-code character)
            never (or (<= #xd800 code #xdfff) (> code #x10ffff)))
      (list :string string)
      (cons :string (map 'list #'char-code string))))

(defun lir-data-object (data label object)
  (cond ((stringp object)
         (return-from lir-data-object (lir-string-constant object)))
        ((static-symbol-p object)
         (let ((name (static-symbol-name object)) (package (static-symbol-package object)))
           (return-from lir-data-object
             (if package `(:symbol ,package ,name)
                 `(:uninterned ,name ,(lir-constant-index data label)))))))
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

(defun lir-register-capture-shape (data entry count)
  (unless (and (stringp entry) (integerp count) (<= 0 count))
    (lir-data-error "invalid closure shape ~S ~S" entry count))
  (multiple-value-bind (old found) (gethash entry (lir-data-function-captures data))
    (when (and found (/= old count))
      (lir-data-error "conflicting capture counts for ~S" entry)))
  (setf (gethash entry (lir-data-function-captures data)) count))

(defun lir-collect-capture-shapes (data module)
  (maphash (lambda (entry count) (lir-register-capture-shape data entry count))
           (kmodule-function-captures module))
  (when (kmodule-capture-shapes-complete-p module)
    (return-from lir-collect-capture-shapes))
  (dolist (entry (kmodule-functions module))
    (let* ((function (kfunc-form entry))
           (slots (rest (assoc :slots (cddr function)))))
      (dolist (part (cddr function))
        (when (eq (first part) :block)
          (dolist (statement (cddr part))
            (case (first statement)
              (:alloc-closure
               (lir-register-capture-shape data (third statement) (fourth statement)))
              (:stack-closure
               (let ((shape (second (assoc (third statement) slots :test #'equalp))))
                 (unless (and (eq (first shape) :stack-object) (eql (second shape) +packet-class-function+))
                   (lir-data-error "closure storage has no function shape"))
                 (lir-register-capture-shape data (fourth statement) (third shape)))))))))))

(defun collect-lir-data (module &optional literals)
  "Builds indexed semantic data, retaining cycles and mutable cache identities."
  (when (kmodule-imports module)
    (lir-data-error "runtime imports must be selected by the backend"))
  (dolist (form (kmodule-import-data module))
    (unless (member (second form) '("kiln_nil" "kiln_t") :test #'equal)
      (lir-data-error "unsupported external object ~S" form)))
  (let ((data (make-lir-data :name (kmodule-name module)
                             :declarations-by-name (kmodule-defined module)))
        (objects '()) (cells '()) (literal-table nil))
    (dolist (root (kmodule-roots module))
      (unless (member (first root) '(:root :field-root :symbol-roots))
        (lir-data-error "unsupported root declaration ~S" root))
      (setf (gethash (second root) (lir-data-mutable data)) t))
    ;; Builder declarations are newest first. Push each kind independently
    ;; to produce packet order, which matches the IDs assigned at registration.
    (dolist (entry (kmodule-data module))
      (if (module-data-entry-p entry)
          (let ((id (module-data-entry-index entry))
                (object (module-data-entry-contents entry)))
            (when id
              (if (minusp id)
                  (push (lir-data-value data object) cells)
                  (progn
                    (when (and (consp object) (eq (first object) :static-function))
                      (lir-register-capture-shape data (second object) 0))
                    (push (lir-data-object data (module-data-entry-name entry) object) objects)))))
          (case (first entry)
            (:literal-table
             (when literal-table (lir-data-error "duplicate literal table"))
             (setf literal-table t (lir-data-literals data) (second entry)))
            (:builtin (push entry (lir-data-builtins data)))
            (t (lir-data-error "unsupported module declaration ~S" entry)))))
    (lir-collect-capture-shapes data module)
    (when literals
      (unless (and (simple-vector-p literals) (= (length literals) (lir-data-literals data)))
        (lir-data-error "literal bindings disagree with the module declaration"))
      (setf (lir-data-literal-source data) literals)
      (loop for object across literals for index from 0
            unless (nth-value 1 (gethash object (lir-data-literal-indices data)))
              do (setf (gethash object (lir-data-literal-indices data)) index)))
    (let ((init (lir-static-object data (kmodule-init module))))
      (unless (and (consp init) (eq (first init) :static-function) (= (length init) 2))
        (lir-data-error "module init must name a zero-capture function object"))
      (setf (lir-data-init data) (second init)))
    (maphash (lambda (name mutable)
               (declare (ignore mutable))
               (unless (or (lir-static-object data name)
                           (lir-cell-index data name))
                 (lir-data-error "root names unknown data ~S" name)))
             (lir-data-mutable data))
    (setf (lir-data-constants data) objects
          (lir-data-cells data) cells)
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
