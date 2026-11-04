;;;; The conditions defined before the condition system (with the early
;;;; DEFINE-CONDITION of lisp/target/early.lisp: Ecclesia, Clostrophilia)
;;;; become condition classes, in definition order (docs/10 §10).

(in-package #:clostrophilia)

(defun define-early-condition-types ()
  (loop for (name supers slots options) in (reverse kiln.kernel::*early-condition-types*)
        do (let ((report (getf (loop for option in options
                                     when (eq (first option) :report)
                                       append option)
                               :report))
                 (default-initargs
                   (loop for option in options
                         when (eq (first option) :default-initargs)
                           append (second option))))
             (unless (find-class name nil)
               (mop-ensure-class
                name
                :metaclass 'condition-class
                :direct-superclasses (or supers '(condition))
                :direct-slots slots
                :direct-default-initargs
                (append (if report
                            (list (list :report nil
                                        (let ((report report))
                                          (lambda () report))))
                            '())
                        default-initargs)))))
  (setf kiln.kernel::*early-condition-types* '()))

(define-early-condition-types)
