;;;; Deferred compiler references shared by native and bytecode compilation.

(in-package #:kiln.kernel)

(defvar *compilation-unit* nil)
(defvar *flushing-compilation-unit* nil)

(define-condition deferred-function-warning (style-warning)
  ((name :initarg :name :reader deferred-function-name))
  (:report (lambda (condition stream)
             (format stream "Undefined function: ~S" (deferred-function-name condition)))))

(defun note-compilation-unit-functions (names)
  (when (and *compilation-unit* (not *flushing-compilation-unit*))
    (dolist (name names)
      (pushnew name (svref *compilation-unit* 0) :test #'equal))
    t))

(defun defer-compilation-reference (condition)
  (when (and *compilation-unit* (not *flushing-compilation-unit*))
    (if (typep condition 'maclina.compile:unknown-function)
        (note-compilation-unit-functions (list (maclina.compile:name condition)))
        (pushnew condition (svref *compilation-unit* 1)
                 :test (lambda (a b)
                         (and (eq (class-of a) (class-of b))
                              (equal (maclina.compile:name a) (maclina.compile:name b))))))
    (let ((restart (or (find-restart 'continue condition)
                       (find-restart 'muffle-warning condition))))
      (when restart (invoke-restart restart)))))

(defun finish-compilation-unit (unit)
  (let ((*flushing-compilation-unit* t))
    (dolist (name (reverse (svref unit 0)))
      (unless (fboundp name)
        (warn 'deferred-function-warning :name name)))
    (dolist (condition (reverse (svref unit 1)))
      (unless (and (typep condition 'maclina.compile:unknown-type)
                   (type-specifier-p (maclina.compile:name condition)))
        (warn condition)))))


(defun call-with-compilation-unit (thunk &key override)
  (if (and *compilation-unit* (not override))
      (funcall thunk)
      (let ((*compilation-unit* (vector nil nil))
            (maclina.compile::*in-compilation-unit* t))
        (unwind-protect
             (handler-bind ((maclina.compile:unknown-reference #'defer-compilation-reference))
               (funcall thunk))
          (finish-compilation-unit *compilation-unit*)))))

(defmacro with-compilation-unit ((&rest options &key override) &body body)
  (declare (ignore override))
  `(call-with-compilation-unit (lambda () ,@body) ,@options))
