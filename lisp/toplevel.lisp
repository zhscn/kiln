(in-package #:kiln.compiler)

(defun toplevel-form-kind (input)
  "Classify syntax before choosing file compilation or image evaluation actions."
  (let ((form (hir-raw input)))
    (cond ((symbolp form) :symbol)
          ((atom form) :literal)
          (t
           (hir-parts input)
           (case (car form)
             (quote (hir-arity 'quote (cdr form) 1) :quote)
             (function (hir-arity 'function (cdr form) 1) :function)
             (progn :progn)
             (eval-when :eval-when)
             (in-package :in-package)
             (defpackage :defpackage)
             ((locally macrolet symbol-macrolet) :scope)
             (otherwise :ordinary))))))

(defun toplevel-eval-when (input mode &optional compile-time-too)
  "Return the phase action and CST body, preserving the caller's execution mode."
  (let* ((parts (rest (hir-parts input))))
    (hir-arity 'eval-when parts 1 nil)
    (let* ((situations (mapcar #'hir-raw (hir-parts (first parts))))
           (compilep (intersection situations '(:compile-toplevel compile)))
           (loadp (intersection situations '(:load-toplevel load)))
           (executep (intersection situations '(:execute eval))))
      (unless (every (lambda (value) (member value '(:compile-toplevel :load-toplevel :execute compile load eval))) situations)
        (hir-error "Invalid EVAL-WHEN situations ~S" situations))
      (values
       (ecase mode
         (:eval (if executep :execute :ignore))
         (:file
          (cond ((and loadp (or compilep (and executep compile-time-too))) :compile-and-emit)
                (loadp :emit)
                ((or compilep (and executep compile-time-too)) :compile)
                (t :ignore))))
       (rest parts)))))
