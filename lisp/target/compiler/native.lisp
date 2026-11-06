;;;; COMPILE to native code (M5.5, docs/11 §11): the lambda expression is
;;;; compiled by the image's front end and lower.lisp into a KIR module
;;;; whose literals are the image's objects, which kiln-cg, linked into the
;;;; runtime, compiles into memory (kiln_rt_jit). The compiler module's
;;;; last file: from here on the kernel's COMPILE uses it, not Maclina.

(in-package #:kiln.compiler)

(defvar *native-compile-count* 0)

(defvar *compiled-function*)

(defun native-compile (definition)
  "The function of the lambda expression DEFINITION, compiled into the
running image, in the null lexical environment."
  (let* ((session (make-session))
         (name (kiln.kir::kir-name "compile-" (incf *native-compile-count*))))
    (multiple-value-bind (module literals)
        (handler-bind ((undefined-function-warning #'muffle-warning))
          (compile-module (front-end-forms `((setq *compiled-function* (function ,definition)))
                                           session)
                          name :session session :image t))
      (let ((init (kiln.sys:%primop :jit (kiln.kir::module-string module) literals)))
        (unless init
          (error "kiln-cg could not compile ~S." definition))
        (let ((*compiled-function* nil))
          (funcall init)
          *compiled-function*)))))

(setf kiln.kernel::*compile-function* 'native-compile)
