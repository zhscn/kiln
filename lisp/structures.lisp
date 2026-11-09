(in-package #:kiln.compiler)

;;;; DEFSTRUCT. Anatomicl runs in the host, at macroexpansion
;;;; time: it parses the DEFSTRUCT form and generates ordinary target code.
;;;; Its default methods look at the class of an included structure
;;;; (through closer-mop) when expanding; there are no target classes at
;;;; compile time, so kiln's client keeps the slot layouts of the
;;;; structures defined so far in the compilation session instead.
;;;;
(defclass anatomicl-client () ())

(defvar *anatomicl-client* (make-instance 'anatomicl-client))

(defvar *structures*)                   ; (kind . name) -> layout or description

(defmethod anatomicl:structure-description ((client anatomicl-client) name environment)
  (declare (ignore environment))
  (values (gethash (cons :typed name) *structures*)))

(defmethod (setf anatomicl:structure-description)
    (new-value (client anatomicl-client) name environment)
  (declare (ignore environment))
  (setf (gethash (cons :typed name) *structures*) new-value))

(defmethod anatomicl:structure-class-name ((client anatomicl-client))
  'structure-class)

(defmethod anatomicl:structure-object-name ((client anatomicl-client))
  'structure-object)

(defmethod anatomicl:client-form ((client anatomicl-client))
  nil)

;;; The layout of a structure-object structure: the included structure's
;;; slots (with this structure's accessor names, and initforms overridden
;;; by :INCLUDE), then the direct slots.
(defmethod anatomicl::compute-slot-layout
    ((client anatomicl-client) (description anatomicl::defstruct-object-description) environment)
  (declare (ignore environment))
  (let ((parent-name (anatomicl::defstruct-included-structure-name description)))
    (append
     (when parent-name
       (let ((parent (multiple-value-bind (layout presentp)
                         (gethash (cons :object parent-name) *structures*)
                       ;; A structure without slots has the layout NIL.
                       (if presentp
                           layout
                           (error "DEFSTRUCT ~S: no structure named ~S to include"
                                  (anatomicl::defstruct-name description) parent-name))))
             (included (anatomicl::defstruct-included-slots description)))
         (dolist (slot included)
           (unless (find (anatomicl::slot-name slot) parent :key #'anatomicl::slot-name)
             (error "DEFSTRUCT ~S: ~S has no slot ~S"
                    (anatomicl::defstruct-name description) parent-name
                    (anatomicl::slot-name slot))))
         (loop for slot in parent
               for name = (anatomicl::slot-name slot)
               collect (or (find name included :key #'anatomicl::slot-name)
                           (make-instance 'anatomicl::slot-description
                                          :name name
                                          :accessor-name (anatomicl::compute-accessor-name
                                                          description name)
                                          :initform (anatomicl::slot-initform slot)
                                          :initform-p (anatomicl::slot-initform-p slot)
                                          :type (anatomicl::slot-type slot)
                                          :read-only (anatomicl::slot-read-only slot))))))
     (anatomicl::defstruct-direct-slots description))))

(defun keyword-of (symbol)
  (intern (symbol-name symbol) '#:keyword))

(defmethod anatomicl::generate-defstruct-bits
    ((client anatomicl-client) (description anatomicl::defstruct-object-description) layout environment)
  (declare (ignore environment))
  (let ((name (anatomicl::defstruct-name description)))
    (setf (gethash (cons :object name) *structures*) layout)
    `(progn
       (defclass ,name (,(or (anatomicl::defstruct-included-structure-name description)
                             'structure-object))
         ,(loop for slot in layout
                collect `(,(anatomicl::slot-name slot)
                          :initarg ,(keyword-of (anatomicl::slot-name slot))))
         (:metaclass structure-class))
       ,@(structure-accessor-definitions name layout description)
       ,@(let ((print-object (anatomicl::defstruct-print-object description)))
           (when print-object
             `((defmethod print-object ((object ,name) stream)
                 (funcall (function ,print-object) object stream))))))))

;;; Accessors inline the layout ancestry check and direct slot access.
(defun structure-class-variable (name)
  (intern (format nil "~A::~A"
                  (if (symbol-package name) (package-name (symbol-package name)) "#")
                  (symbol-name name))
          '#:kiln.structures))

(defun structure-accessor-definitions (name layout description)
  (let* ((variable (structure-class-variable name))
         (layout-form `(kiln.sys:%primop :symbol-global-value ',variable))
         (accessors '()))
    (loop for slot in layout
          for location from 0
          for accessor = (anatomicl::slot-accessor-name slot)
          when accessor
            do (push `(defun ,accessor (object)
                        (kiln.sys::%structure-ref object ,layout-form ',name ,location))
                     accessors)
               (unless (anatomicl::slot-read-only slot)
                 (push `(defun (setf ,accessor) (value object)
                          (kiln.sys::%structure-set value object ,layout-form ',name ,location))
                       accessors)))
    `((defparameter ,variable (kiln.sys::%ensure-structure-layout (find-class ',name)))
      (declaim (inline ,@(anatomicl::defstruct-predicates description)
                       ,@(when (<= (length layout) 8)
                           (mapcar #'first (anatomicl::defstruct-constructors description)))
                       ,@(mapcar #'second accessors)))
      ,@(reverse accessors))))

;;; Constructors allocate one object and initialize its slots by position.
(defmethod anatomicl::generate-allocation-form
    ((client anatomicl-client) (description anatomicl::defstruct-object-description) layout)
  `(kiln.sys:%primop :allocate-structure
                     (kiln.sys:%primop :symbol-global-value
                                       ',(structure-class-variable
                                          (anatomicl::defstruct-name description)))
                     ,(length layout)))

(defmethod anatomicl::generate-slot-initialization-form
    ((client anatomicl-client) (description anatomicl::defstruct-object-description)
     layout object slot value)
  `(kiln.sys:%primop :set-structure-slot ,object
                     ,(position (anatomicl::slot-name slot) layout :key #'anatomicl::slot-name)
                     ,value))

(defmethod anatomicl::generate-standard-constructor
    ((client anatomicl-client) (description anatomicl::defstruct-object-description)
     layout constructor-name)
  (let ((vars (loop repeat (length layout) collect (gensym "SLOT")))
        (object (gensym "OBJECT")))
    `(defun ,constructor-name
         (&key ,@(loop for slot in layout
                       for var in vars
                       collect `((,(keyword-of (anatomicl::slot-name slot)) ,var)
                                 ,(anatomicl::slot-initform slot))))
       (let ((,object ,(anatomicl::generate-allocation-form client description layout)))
         ,@(loop for slot in layout
                 for var in vars
                 collect (anatomicl::generate-slot-initialization-form
                          client description layout object slot var))
         ,object))))

(defmethod anatomicl::generate-predicate
    ((client anatomicl-client) (description anatomicl::defstruct-object-description)
     layout predicate-name)
  (declare (ignore layout))
  `(defun ,predicate-name (object)
     (kiln.sys::%structure-typep
      object (kiln.sys:%primop :symbol-global-value
                               ',(structure-class-variable
                                  (anatomicl::defstruct-name description))))))

(defmethod anatomicl::generate-copier
    ((client anatomicl-client) (description anatomicl::defstruct-object-description) layout copier-name)
  (declare (ignore layout))
  `(defun ,copier-name (object)
     (check-type object ,(anatomicl::defstruct-name description))
     (copy-structure object)))

;;; Typed structures (:TYPE LIST or VECTOR) have no class: the description
;;; is kept for :INCLUDE, and only accessors are generated.
(defmethod anatomicl::generate-defstruct-bits
    ((client anatomicl-client) (description anatomicl::defstruct-typed-description) layout environment)
  (setf (anatomicl:structure-description client (anatomicl::defstruct-name description) environment)
        description)
  `(progn ,@(anatomicl::generate-typed-slot-accessors description layout)))

(defun expand-defstruct (form environment)
  (destructuring-bind (name-and-options &rest slots) (rest form)
    (anatomicl:expand-defstruct *anatomicl-client*
                                (anatomicl:parse-defstruct name-and-options slots)
                                environment)))
