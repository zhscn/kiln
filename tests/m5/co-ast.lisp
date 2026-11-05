;;; Common-boot on kiln (docs/11 §3, M5.2): CST-TO-AST of forms, in a
;;; Clostrum environment that has kiln's macros. Each AST is shown as
;;; (CLASS (CHILD-NAME VALUE)...); an AST seen before is shown as (:AST N),
;;; N being the order in which ASTs are first seen.
;;;
;;; The output is the same in SBCL (with the kiln system loaded, and
;;; COMMON-MACRO-DEFINITIONS:*CLIENT* a KILN.MACROS:MACRO-CLIENT), where
;;; the environment gets Common-macros' macros, which are kiln's run-time
;;; macros too.

(defpackage #:co-ast
  (:use #:common-lisp)
  (:local-nicknames (#:cb #:common-boot) (#:ico #:iconoclast)
                    (#:clo #:clostrum) (#:cst #:concrete-syntax-tree)))

(in-package #:co-ast)

(defclass client (cb:client) ())

(defmethod cb:convert-with-parser-p ((client client) operator)
  (special-operator-p operator))

(defmethod cb:convert-with-ordinary-macro-p ((client client) operator)
  (declare (ignore operator))
  nil)

(defparameter *client* (make-instance 'client))

(defparameter *environment*
  (let* ((environment (cb:create-environment))
         (global (trucler:global-environment *client* environment)))
    (do-external-symbols (s '#:common-lisp)
      (let ((expander #+kiln (and (not (special-operator-p s)) (macro-function s))
                      #-kiln (common-macro-definitions:macro-function s)))
        (when expander
          (setf (clo:macro-function *client* global s) expander))))
    (dolist (s '(car cdr cons list + - * < = eq))
      (setf (clo:fdefinition *client* global s) (fdefinition s)))
    environment))

(defun show (ast)
  (let ((seen (make-hash-table :test 'eq)) (count 0))
    (labels ((walk (x)
               (cond ((typep x 'ico:ast)
                      (let ((n (gethash x seen)))
                        (if n
                            (list :ast n)
                            (progn
                              (setf (gethash x seen) (incf count))
                              (cons (class-name (class-of x))
                                    (loop for (name . child) in (ico:children x)
                                          collect (list name (walk child))))))))
                     ((consp x) (mapcar #'walk x))
                     ((typep x 'cst:cst) (list :cst (cst:raw x)))
                     ((and (symbolp x) (null (symbol-package x))) '(:gensym))
                     ((typep x 'standard-object) (list :object (class-name (class-of x))))
                     (t x))))
      (walk ast))))

;;; Common-boot warns about calls of functions that the environment does
;;; not have (G, FUNCALL).
(defun convert (form)
  (handler-bind ((warning #'muffle-warning))
    (show (cb:cst-to-ast *client* (cst:cst-from-expression form) *environment*))))

(dolist (form '(1
                (quote (a b))
                (if (car '(1)) 1 2)
                (let ((x 1) (y 2)) (+ x y))
                (flet ((f (a &optional (b 2)) (cons a b))) (f 1))
                (lambda (x &rest r) (list x r))
                (block b (return-from b 3))
                (tagbody a (go a))
                (let ((x 1)) (when (eq x 1) (list x)))
                (defun g (n) (if (< n 2) n (+ (g (- n 1)) 1)))))
  (let ((ast (convert form))
        (*print-pretty* nil)
        (*package* (find-package '#:common-lisp-user)))
    (format t "~S~%=> ~S~%" form ast)))
