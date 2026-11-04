;;;; The expansions of Common-macros' macros that kiln customizes (docs/08
;;;; §2, docs/10 §7, §26). Portable: the host loads this file into the
;;;; compiler, and the target's eval module (docs/11) compiles it, so that
;;;; macros expand alike at compile time and at run time.

(in-package #:kiln.macros)

;;; The target reads this file in KILN.MACROS-TARGET, where CMD is the
;;; target's Common-macros package (KILN.CMD).

(defclass macro-client () ()
  (:documentation "Common-macros client: the expansions shared by the
compiler's client and the run-time macros."))

;;; DEFCLASS, DEFGENERIC and DEFMETHOD expand into calls to kiln's
;;; functions in lisp/target/clos/early.lisp, which create the metaobjects
;;; with the early functions during the bootstrap and with the MOP after it
;;; (docs/10 §7). Specializers are passed as designators (a class name or
;;; (EQL object)) so that a DEFMETHOD can be evaluated before the classes
;;; exist.

(defmethod cmd:defclass-compile-time-action
    ((client macro-client) name superclass-names metaclass-name environment)
  (declare (ignore name superclass-names metaclass-name environment))
  nil)

(defmethod cmd:defgeneric-compile-time-action
    ((client macro-client) name lambda-list argument-precedence-order
     generic-function-class-name method-class-name method-combination-name
     method-combination-arguments documentation-option environment)
  (declare (ignore name lambda-list argument-precedence-order
                   generic-function-class-name method-class-name method-combination-name
                   method-combination-arguments documentation-option environment))
  nil)

(defmethod cmd:ensure-class-name ((client macro-client))
  'kiln.sys:%defclass)

(defmethod cmd:ensure-generic-function
    ((client macro-client) name lambda-list argument-precedence-order
     generic-function-class-name method-class-name method-combination-name
     method-combination-arguments documentation-option environment)
  (declare (ignore environment))
  `(kiln.sys:%defgeneric
    ',name
    :lambda-list ',lambda-list
    ,@(when argument-precedence-order
        `(:argument-precedence-order ',(rest argument-precedence-order)))
    :generic-function-class ',generic-function-class-name
    :method-class ',method-class-name
    :method-combination-name ',method-combination-name
    :method-combination-arguments ',method-combination-arguments
    ,@(when documentation-option
        `(:documentation ',(second documentation-option)))))

;;; Method functions (docs/10 §26). The method function takes the list of
;;; arguments and the next methods (AMOP). A method whose lambda list has
;;; only required parameters (at most +MAX-FAST-ARITY+) also gets a fast
;;; function, of the next methods and the arguments themselves, which the
;;; discriminating function calls without making a list. The local
;;; functions CALL-NEXT-METHOD and NEXT-METHOD-P are only made when the
;;; body mentions them: they are closures, allocated at each call.

(defconstant +max-fast-arity+ 6)

(defun mentions-p (symbols tree)
  (let ((seen (make-hash-table :test 'eq)))
    (labels ((walk (x)
               (cond ((symbolp x) (member x symbols))
                     ((atom x) nil)
                     ((gethash x seen) nil)
                     (t (setf (gethash x seen) t)
                        (or (walk (car x)) (walk (cdr x)))))))
      (walk tree))))

(defun method-lambda-forms (lambda-expression)
  "The slow and the fast method lambdas (the latter NIL) for the method
LAMBDA-EXPRESSION."
  (let* ((arguments (gensym "ARGUMENTS"))
         (next-methods (gensym "NEXT-METHODS"))
         (lambda-list (second lambda-expression))
         (nextp (mentions-p '(call-next-method next-method-p) (cddr lambda-expression)))
         (fastp (and (consp lambda-list)
                     (<= (length lambda-list) +max-fast-arity+)
                     (every #'symbolp lambda-list)
                     (notany (lambda (p) (member p lambda-list-keywords)) lambda-list)))
         (parameters (and fastp (loop repeat (length lambda-list) collect (gensym "ARG")))))
    (flet ((with-next (call-next-method-body form)
             (if nextp
                 `(flet ((next-method-p ()
                           (not (null ,next-methods)))
                         (call-next-method (&rest arguments)
                           (if (null ,next-methods)
                               (error "no next method")
                               ,call-next-method-body)))
                    (declare (ignorable #'next-method-p #'call-next-method))
                    ,form)
                 form)))
      (values
       `(lambda (,arguments ,next-methods)
          (declare (ignorable ,next-methods))
          ,(with-next `(funcall (kiln.sys:%method-function (first ,next-methods))
                                (or arguments ,arguments)
                                (rest ,next-methods))
                      `(apply ,lambda-expression ,arguments)))
       (and fastp
            `(lambda (,next-methods ,@parameters)
               (declare (ignorable ,next-methods))
               ,(with-next `(if arguments
                                (funcall (kiln.sys:%method-function (first ,next-methods))
                                         arguments (rest ,next-methods))
                                (let ((fast (kiln.sys:%method-fast-function
                                             (first ,next-methods))))
                                  (if fast
                                      (funcall fast (rest ,next-methods) ,@parameters)
                                      (funcall (kiln.sys:%method-function
                                                (first ,next-methods))
                                               (list ,@parameters)
                                               (rest ,next-methods)))))
                           `(,lambda-expression ,@parameters))))))))

(defmethod cmd:make-method-lambda-wrapper ((client macro-client))
  (lambda (lambda-expression)
    (multiple-value-bind (slow fast) (method-lambda-forms lambda-expression)
      ;; Taken apart by ENSURE-METHOD-WRAPPER.
      (list :kiln-method-lambdas slow fast))))

(defmethod cmd:ensure-method-wrapper ((client macro-client))
  (lambda (function-name lambda-list qualifiers specializer-designators
           documentation method-lambda)
    (destructuring-bind (function fast-function)
        (if (and (consp method-lambda) (eq (first method-lambda) :kiln-method-lambdas))
            (rest method-lambda)
            (list method-lambda nil))
      `(kiln.sys:%defmethod
        ',function-name
        :lambda-list ',lambda-list
        :qualifiers ',qualifiers
        :specializers (list ,@(loop for s in specializer-designators
                                    collect (if (consp s)
                                                `(list 'eql ,(second s))
                                                `',s)))
        :documentation ',documentation
        :function ,function
        ,@(when fast-function `(:fast-function ,fast-function))))))

;;; Places. DEFINE-SETF-EXPANDER registers the expander in the
;;; compile-time environment and, at load time, on the symbol (the kernel's
;;; %DEFINE-SETF-EXPANDER, used by the run-time GET-SETF-EXPANSION).

(defmethod cmd:wrap-in-setf-setf-expander ((client macro-client) name function environment)
  (declare (ignore environment))
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (kiln.sys::%define-setf-expander ',name ,function)))

;;; WITH-OUTPUT-TO-STRING with a string: an output stream that appends to
;;; it (Cyclosis' string output stream, docs/10 §16).
(defmethod cmd::output-stream-from-string-function-name ((client macro-client))
  ;; CYCLOSIS is created when the CLOS module's sources are read.
  `(lambda (string)
     (make-instance ',(intern "STRING-OUTPUT-STREAM" "CYCLOSIS") :string string)))

(defmethod cmd:setf-type-function-wrapper ((client macro-client))
  ;; Common-macros' DEFTYPE puts this in an EVAL-WHEN with all three
  ;; situations: the compile-time environment's %DEFTYPE records the
  ;; expander in Clostrum, the kernel's on the symbol.
  (lambda (name function environment)
    (declare (ignore environment))
    `(kiln.sys::%deftype ',name ,function)))

