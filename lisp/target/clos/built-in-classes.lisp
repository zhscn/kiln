;;;; Built-in classes of the objects that are not standard objects
;;;; (docs/10 §7). CLASS-OF maps an object to one of these by its tag and
;;;; kind (BUILT-IN-CLASS-NAME-OF). T and FUNCTION are Clostrophilia's.

(in-package #:clostrophilia)

(defmacro define-built-in-classes (&rest specs)
  `(progn
     ,@(mapcar (lambda (spec)
                 `(defclass ,(first spec) ,(rest spec) () (:metaclass built-in-class)))
               specs)))

(define-built-in-classes
  (sequence t)
  (list sequence)
  (symbol t)
  (null symbol list)
  (cons list)
  (array t)
  (vector array sequence)
  (simple-vector vector)
  (string vector)
  (character t)
  (number t)
  (real number)
  (rational real)
  (integer rational)
  (fixnum integer)
  (bignum integer)
  (ratio rational)
  (float real)
  (single-float float)
  (double-float float))
