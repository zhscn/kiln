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
  ;; Arrays (docs/10 §14): simple vectors and strings are native objects;
  ;; the other arrays are instances of Regalia's standard classes, which
  ;; are subclasses of these.
  (array t)
  (simple-array array)
  (vector array sequence)
  (simple-vector vector simple-array)
  (string vector)
  (simple-string string simple-array)
  (bit-vector vector)
  (simple-bit-vector bit-vector simple-array)
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
  (double-float float)
  ;; Classes without instances yet: complex numbers, pathnames, random
  ;; states, readtables.
  (complex number)
  (pathname t)
  (logical-pathname pathname)
  (random-state t)
  (readtable t))
