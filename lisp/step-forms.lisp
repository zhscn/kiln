;;;; Shared source expansion for compiler-inserted stepping boundaries.

(in-package #:kiln.compiler)

(defun step-call-form (form)
  (let* ((function (gensym "STEP-FUNCTION"))
         (arguments (mapcar (lambda (argument) (declare (ignore argument))
                             (gensym "STEP-ARGUMENT"))
                           (cdr form)))
         (mode (gensym "STEP-MODE")))
    `(let* ((,function (kiln.sys::%step-body (function ,(car form))))
            ,@(mapcar (lambda (name argument) `(,name (kiln.sys::%step-body ,argument)))
                      arguments (cdr form)))
       (let ((,mode (kiln.kernel::step-before
                     ',form
                     (when (and kiln.kernel::*step-enabled*
                                (not kiln.kernel::*step-continued*))
                       (list ,@arguments)))))
         (let ((kiln.kernel::*step-depth* (1+ kiln.kernel::*step-depth*))
               (kiln.kernel::*step-enabled*
                 (and kiln.kernel::*step-enabled*
                      (not kiln.kernel::*step-continued*)
                      (not (eq ,mode :next)))))
           (kiln.sys::%step-original (funcall ,function ,@arguments)))))))
