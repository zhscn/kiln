;;; Dependency tracking: definitions evaluated in the image are
;;; compiled again when a macro, inline function, SETF expander or
;;; constant they were compiled with changes.

(defmacro report-warnings (&body body)
  `(handler-bind ((warning (lambda (w)
                             (format t "~&warning: ~A~%" w)
                             (muffle-warning w))))
     ,@body))

;; a macro redefined: its users follow
(eval '(defmacro twice (x) `(* 2 ,x)))
(eval '(defun use-twice (y) (twice y)))
(print (use-twice 5))
(eval '(defmacro twice (x) `(+ ,x ,x 1)))
(print (use-twice 5))
(print (kiln.sys:dependents :macro 'twice))
(print (kiln.sys:dependencies 'use-twice))

;; a name used before it is defined as a macro
(eval '(defun use-later () (later 3)))
(eval '(defmacro later (x) `(list :later ,x)))
(print (use-later))

;; a macro whose expander uses another macro: both follow
(eval '(defmacro scale () 10))
(eval '(defmacro scaled (x) (list '* (scale) x)))
(eval '(defun use-scaled (x) (scaled x)))
(print (use-scaled 2))
(eval '(defmacro scale () 100))
(print (use-scaled 2))

;; inline functions: expanded in the code of later EVALs, which follows
;; their redefinition
(eval '(declaim (inline sq)))
(eval '(defun sq (x) (* x x)))
(eval '(defun use-sq (x) (+ (sq x) 1)))
(print (use-sq 3))
(setf (fdefinition 'sq) (lambda (x) (- x)))  ; not seen: SQ is open-coded
(print (use-sq 3))
(eval '(defun sq (x) (* x x x)))
(print (use-sq 3))

;; a SETF expander defined after its place is used
(defvar *store* (list 0))
(defun store-ref (i) (nth i *store*))
(defun (setf store-ref) (v i) (declare (ignore i)) (setf (first *store*) (list :function v)))
(eval '(defun set-store (v) (setf (store-ref 0) v)))
(set-store 1)
(print *store*)
(defun set-store-ref (i v) (setf (nth i *store*) (list :expander v)))
(eval '(defsetf store-ref set-store-ref))
(set-store 2)
(print *store*)

;; a constant whose value changes
(eval '(defconstant +limit+ 10))
(eval '(defun limit () +limit+))
(print (limit))
(report-warnings (eval '(defconstant +limit+ 20)))
(print (limit))

;; definitions that are not evaluated again are reported, and so are
;; those that no longer compile; the old code stays
(eval '(defmacro base () 1))
(eval '(defparameter *base* (base)))
(eval '(defun use-base () (base)))
(report-warnings (eval '(defmacro base () 2)))
(print (list (symbol-value '*base*) (use-base)))
(eval '(defmacro strict (x) (if (integerp x) x (error "not an integer: ~S" x))))
(eval '(defun use-strict () (strict 7)))
(report-warnings (eval '(defmacro strict (x) (if (stringp x) x (error "not a string: ~S" x)))))
(print (use-strict))

;; macros whose expanders use each other: each is compiled again once
;; for each change
(eval '(defmacro pong () 1))
(eval '(defmacro ping () (pong)))
(eval '(defun call-both () (list (ping) (pong))))
(print (call-both))
(let ((kiln.sys:*recompile-verbose* t)
      (*error-output* *standard-output*))
  (eval '(defmacro pong () (+ (ping) 1))))
(print (call-both))

;; ordering: a definition is compiled again after those it waits for,
;; once (USE-K depends on K and on M1, which depends on K)
(eval '(defmacro k () 1))
(eval '(defmacro m1 () `(+ ,(k) 0)))
(eval '(defun use-k () (list (k) (m1))))
(let ((kiln.sys:*recompile-verbose* t)
      (*error-output* *standard-output*))
  (eval '(defmacro k () 3)))
(print (use-k))

;; cutoff: a macro compiled again to the same code does not affect the
;; definitions that use it
(eval '(defmacro two () 2))
(eval '(defmacro add-two (x) `(+ ,x ,(two))))
(eval '(defun use-add-two (y) (add-two y)))
(let ((kiln.sys:*recompile-verbose* t)
      (*error-output* *standard-output*))
  (eval '(defmacro two () (+ 1 1))))
(print (use-add-two 5))

(eval '(defmacro order-left () :left))
(eval '(defmacro order-right () :right))
(eval '(defun order-one () (order-left)))
(eval '(defun order-two () (order-left)))
(eval '(defun order-three () (order-right)))
(eval '(defun order-one () (list (order-right) (order-left))))
(print (kiln.sys:dependents :macro 'order-left))
(print (kiln.sys:dependents :macro 'order-right))

(eval '(defun order-three () (order-left)))
(eval '(defun order-four () (order-right)))
(print (kiln.sys:dependents :macro 'order-left))
(print (kiln.sys:dependents :macro 'order-right))

(defvar *replay-offset* 7)
(defvar *replay-expansions* 0)
(defun replay-expander (form environment)
  (declare (ignore environment))
  (incf *replay-expansions*)
  (let ((variable (gensym "REPLAY")))
    `(let ((,variable ,(second form))) (+ ,variable ,*replay-offset*))))

(let ((compiler (symbol-function 'kiln.compiler::compile-module))
      (lowerings 0))
  (unwind-protect
       (progn
         (setf (symbol-function 'kiln.compiler::compile-module)
               (lambda (&rest arguments)
                 (when (eq (first kiln.compiler::*updating-definitions*) 'replay-generated)
                   (incf lowerings))
                 (apply compiler arguments)))
         (setf (macro-function 'replay-macro) #'replay-expander)
         (eval '(defun replay-generated (argument) (replay-macro argument)))
         (let ((expansions *replay-expansions*))
           (dotimes (i 2) (setf (macro-function 'replay-macro) #'replay-expander))
           (assert (= *replay-expansions* (+ expansions 2)))
           (assert (= lowerings 1)))
         (assert (= (funcall 'replay-generated 3) 10))
         (setf (symbol-function 'kiln.compiler::source-variable-name)
               (symbol-function 'kiln.compiler::source-variable-name))
         (setf (macro-function 'replay-macro) #'replay-expander)
         (assert (= lowerings 2))
         (incf *replay-offset*)
         (setf (macro-function 'replay-macro) #'replay-expander)
         (assert (> lowerings 2))
         (assert (= (funcall 'replay-generated 3) 11)))
    (setf (symbol-function 'kiln.compiler::compile-module) compiler)))

(defvar *replay-literal* (list :value))
(defun replay-literal-expander (form environment)
  (declare (ignore form environment))
  (list 'quote *replay-literal*))
(setf (macro-function 'replay-literal-macro) #'replay-literal-expander)
(eval '(defun replay-literal () (replay-literal-macro)))
(assert (eq (funcall 'replay-literal) *replay-literal*))
(setf *replay-literal* (list :value))
(setf (macro-function 'replay-literal-macro) #'replay-literal-expander)
(assert (eq (funcall 'replay-literal) *replay-literal*))
