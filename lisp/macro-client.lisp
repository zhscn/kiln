;;;; The expansions of Common-macros' macros that kiln customizes.
;;;; Portable: the host loads this file into the
;;;; compiler, and the target's eval module compiles it, so that
;;;; macros expand alike at compile time and at run time.

(in-package #:kiln.macros)

;;; The target reads this file in KILN.MACROS-TARGET, where CMD is the
;;; target's Common-macros package (KILN.CMD).

(defclass macro-client () ()
  (:documentation "Common-macros client: the expansions shared by the
compiler's client and the run-time macros."))

;;; DEFCLASS, DEFGENERIC and DEFMETHOD expand into calls to kiln's
;;; functions in lisp/target/clos/early.lisp, which create the metaobjects
;;; with the early functions during the bootstrap and with the MOP after it.
;;; Specializers are passed as designators (a class name or
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

;;; Method functions. The method function takes the list of
;;; arguments and the next methods (AMOP). A method whose lambda list has
;;; only required parameters (at most +MAX-FAST-ARITY+) also gets a fast
;;; function, of the next methods and the arguments themselves, which the
;;; discriminating function calls without making a list. The local
;;; functions CALL-NEXT-METHOD and NEXT-METHOD-P are only made when the
;;; body mentions them. When the body only calls them (no
;;; #'CALL-NEXT-METHOD), they are local macros instead: local functions
;;; would be closures, allocated at each call of the method, and
;;; (CALL-NEXT-METHOD) calls the next method's fast function in place.

(defconstant +max-fast-arity+ 6)

(defun mentions-p (symbols tree)
  (let ((seen nil))
    (labels ((walk (x depth)
               (cond ((symbolp x) (member x symbols))
                     ((or (not (consp x)) (zerop depth)) nil)
                     ((and (< depth 99900)
                           (let ((s (or seen (setf seen (make-hash-table :test 'eq)))))
                             (or (gethash x s) (progn (setf (gethash x s) t) nil))))
                      nil)
                     (t (or (walk (car x) (1- depth)) (walk (cdr x) (1- depth)))))))
      (walk tree 100000))))

;;; A method with keyword parameters accepts any keyword arguments (the
;;; generic function checks them, CLHS 7.6.5): its lambda list gets
;;; &ALLOW-OTHER-KEYS. (Clostrophilia appends :ALLOW-OTHER-KEYS T to the
;;; arguments instead, which a &REST parameter would then see.)
(defun only-called-p (symbols tree)
  "True if SYMBOLS occur in TREE only as the first element of a list (the
operator of a form), as far as a walk of the tree without macroexpansion
can tell."
  (let ((seen nil))
    (labels ((walk (x depth)
               (or (not (consp x))
                   (zerop depth)
                   (and (< depth 99900)
                        (let ((s (or seen (setf seen (make-hash-table :test 'eq)))))
                          (or (gethash x s) (progn (setf (gethash x s) t) nil))))
                   (and (walk (car x) (1- depth))
                        (loop for tail = (cdr x) then (cdr tail)
                              while (consp tail)
                              always (let ((e (car tail)))
                                       (if (consp e)
                                           (walk e (1- depth))
                                           (not (member e symbols)))))))))
      (walk tree 100000))))

(defun only-no-arg-next-p (symbols tree)
  "True if SYMBOLS occur in TREE only as (SYMBOL) with no arguments."
  (let ((seen nil))
    (labels ((walk (x depth)
               (cond ((symbolp x) (not (member x symbols)))
                     ((or (not (consp x)) (zerop depth)) t)
                     ((and (< depth 99900)
                           (let ((s (or seen (setf seen (make-hash-table :test 'eq)))))
                             (or (gethash x s) (progn (setf (gethash x s) t) nil))))
                      t)
                     ((member (car x) symbols)
                      (null (cdr x)))
                     (t
                      (and (walk (car x) (1- depth))
                           (loop for tail = (cdr x) then (cdr tail)
                                 while (consp tail)
                                 always (walk (car tail) (1- depth)))
                           (walk (cdr (last x)) (1- depth)))))))
      (walk tree 100000))))

(defun allow-other-keys-lambda-list (lambda-list)
  (if (and (member '&key lambda-list) (not (member '&allow-other-keys lambda-list)))
      (let ((aux (position '&aux lambda-list)))
        (append (subseq lambda-list 0 aux)
                '(&allow-other-keys)
                (and aux (subseq lambda-list aux))))
      lambda-list))

(defun method-lambda-forms (lambda-expression)
  "The slow and the fast method lambdas (the latter NIL) for the method
LAMBDA-EXPRESSION."
  (setf lambda-expression
        (list* (first lambda-expression)
               (allow-other-keys-lambda-list (second lambda-expression))
               (cddr lambda-expression)))
  (let* ((arguments (gensym "ARGUMENTS"))
         (next-methods (gensym "NEXT-METHODS"))
         (lambda-list (second lambda-expression))
         (nextp (mentions-p '(call-next-method next-method-p) (cddr lambda-expression)))
         (fastp (and (consp lambda-list)
                     (<= (length lambda-list) +max-fast-arity+)
                     (every #'symbolp lambda-list)
                     (notany (lambda (p) (member p lambda-list-keywords)) lambda-list)))
         (parameters (and fastp (loop repeat (length lambda-list) collect (gensym "ARG"))))
         ;; One string in every expansion: SBCL coalesces equal literals of a
         ;; file, kiln does not, and the KIR must be the same.
         (message "no next method"))
    (flet ((with-next (call-next-method-body no-arguments-body form)
             ;; CALL-NEXT-METHOD-BODY calls the next method with ARGUMENTS
             ;; (NIL: the method's own); NO-ARGUMENTS-BODY with the
             ;; method's own.
             (cond ((not nextp) form)
                   ((only-called-p '(call-next-method next-method-p) (cddr lambda-expression))
                    (let* ((with-arguments `(if (null ,next-methods)
                                                (error ,message)
                                                ,call-next-method-body))
                           (without-arguments `(if (null ,next-methods)
                                                   (error ,message)
                                                   ,no-arguments-body)))
                      `(macrolet ((next-method-p ()
                                    '(not (null ,next-methods)))
                                  (call-next-method (&rest arguments)
                                    (if arguments
                                        (list 'let (list (list 'arguments (cons 'list arguments)))
                                              ',with-arguments)
                                        ',without-arguments)))
                         ,form)))
                   (t
                    `(flet ((next-method-p ()
                              (not (null ,next-methods)))
                            (call-next-method (&rest arguments)
                              (if (null ,next-methods)
                                  (error ,message)
                                  ,call-next-method-body)))
                       (declare (ignorable #'next-method-p #'call-next-method))
                       ,form)))))
      (cond ((and fastp (not nextp))
             (values nil lambda-expression))
            ((and fastp (only-no-arg-next-p '(call-next-method next-method-p)
                                            (cddr lambda-expression)))
             (values
              nil
              `(cons :next-function
                     (lambda (,next-methods ,@parameters)
                       (declare (ignorable ,next-methods))
                       (macrolet ((next-method-p ()
                                    '(not (null ,next-methods)))
                                  (call-next-method ()
                                    '(if ,next-methods
                                         (funcall ,next-methods ,@parameters)
                                         (error ,message))))
                         (,lambda-expression ,@parameters))))))
            (fastp
             (values
              nil
              `(cons (lambda (,next-methods ,@parameters)
                       (declare (ignorable ,next-methods))
                       ,(let ((own `(let ((fast (kiln.sys:%method-fast-function
                                                 (first ,next-methods))))
                                      (cond ((functionp fast)
                                             (funcall fast ,@parameters))
                                            ((and (consp fast) (null (cdr fast)))
                                             (funcall (car fast) (rest ,next-methods) ,@parameters))
                                            (t
                                             (funcall (kiln.sys:%method-function
                                                       (first ,next-methods))
                                                      (list ,@parameters)
                                                      (rest ,next-methods)))))))
                          (with-next `(if arguments
                                          (funcall (kiln.sys:%method-function (first ,next-methods))
                                                   arguments (rest ,next-methods))
                                          ,own)
                                     own
                                     `(,lambda-expression ,@parameters))))
                     nil)))
            (t
             (values
              `(lambda (,arguments ,next-methods)
                 (declare (ignorable ,next-methods))
                 ,(with-next `(funcall (kiln.sys:%method-function (first ,next-methods))
                                       (or arguments ,arguments)
                                       (rest ,next-methods))
                             `(funcall (kiln.sys:%method-function (first ,next-methods))
                                       ,arguments
                                       (rest ,next-methods))
                             `(apply ,lambda-expression ,arguments)))
              nil))))))

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
        ,@(when function `(:function ,function))
        ,@(when fast-function `(:fast-function ,fast-function))))))

;;; Places. DEFINE-SETF-EXPANDER registers the expander in the
;;; compile-time environment and, at load time, on the symbol (the kernel's
;;; %DEFINE-SETF-EXPANDER, used by the run-time GET-SETF-EXPANSION).

(defmethod cmd:wrap-in-setf-setf-expander ((client macro-client) name function environment)
  (declare (ignore environment))
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (kiln.sys::%define-setf-expander ',name ,function)))

;;; WITH-OUTPUT-TO-STRING with a string: an output stream that appends to
;;; it (Cyclosis' string output stream).
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

