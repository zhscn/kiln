;;;; Types for the built-in classes: TYPEP, TYPE-OF, COERCE, EQUALP.
;;;;
;;;; TYPEP knows the built-in atomic types and the common compound
;;;; specifiers itself; DEFTYPE names are expanded, class names go to CLOS
;;;; and other compound specifiers to ctype, once those are loaded.
;;;; The compiler open-codes TYPEP for constant atomic types (docs/09 §10).

(in-package #:kiln.kernel)

(defun bignump (x) (%primop :bignump x))
(defun fixnump (x) (%primop :fixnump x))
(defun single-float-p (x) (%primop :single-float-p x))
(defun double-float-p (x) (%primop :double-float-p x))
(defun ratiop (x) (%primop :ratiop x))

(defun in-range-p (x low high)
  ;; LOW and HIGH are bounds as in (INTEGER LOW HIGH): *, a number, or a
  ;; list of one number for an exclusive bound.
  (and (cond ((or (null low) (eq low '*)) t)
             ((consp low) (> x (car low)))
             (t (>= x low)))
       (cond ((or (null high) (eq high '*)) t)
             ((consp high) (< x (car high)))
             (t (<= x high)))))

(defun typep (object type &optional environment)
  (declare (ignore environment))
  (if (consp type)
      (compound-typep object (car type) (cdr type))
      (case type
        ((t) t)
        ((nil) nil)
        (null (null object))
        (symbol (symbolp object))
        (keyword (keywordp object))
        (boolean (or (eq object t) (eq object nil)))
        (cons (consp object))
        (list (listp object))
        (atom (atom object))
        ((function compiled-function) (functionp object))
        (character (characterp object))
        ((base-char standard-char) (and (characterp object) (< (char-code object) 128)))
        ((string base-string) (stringp object))
        ((simple-string simple-base-string) (simple-string-p object))
        (simple-vector (simple-vector-p object))
        (vector (vectorp object))
        (simple-array (simple-array-p object))
        ;; BIT-VECTOR is Regalia's class; it has no subclass for the simple ones.
        (simple-bit-vector (and (typep object 'bit-vector) (simple-array-p object)))
        (array (arrayp object))
        (sequence (or (listp object) (vectorp object)))
        (number (numberp object))
        (real (realp object))
        (rational (rationalp object))
        (integer (integerp object))
        (fixnum (fixnump object))
        (bignum (bignump object))
        (ratio (ratiop object))
        (float (floatp object))
        ((single-float short-float) (single-float-p object))
        ((double-float long-float) (double-float-p object))
        (bit (or (eql object 0) (eql object 1)))
        (unsigned-byte (and (integerp object) (>= object 0)))
        (signed-byte (integerp object))
        (t (other-typep object type)))))

;;; Class names (and classes) as types, once CLOS is loaded: it sets
;;; *CLASS-TYPEP* to a function of the object and the type that returns
;;; whether the object is of the type, or signals an error for types that
;;; are not classes.
(defvar *class-typep* nil)

(defun class-typep (object type)
  (if *class-typep*
      (funcall *class-typep* object type)
      (unknown-type type)))

(defun compound-typep (object head args)
  (case head
    (or (dolist (type args nil) (when (typep object type) (return t))))
    (and (dolist (type args t) (unless (typep object type) (return nil))))
    (not (not (typep object (car args))))
    (member (if (member object args) t nil))
    (eql (eql object (car args)))
    (satisfies (if (funcall (car args) object) t nil))
    (integer (and (integerp object) (in-range-p object (car args) (cadr args))))
    (rational (and (rationalp object) (in-range-p object (car args) (cadr args))))
    (real (and (realp object) (in-range-p object (car args) (cadr args))))
    (float (and (floatp object) (in-range-p object (car args) (cadr args))))
    ((single-float short-float)
     (and (single-float-p object) (in-range-p object (car args) (cadr args))))
    ((double-float long-float)
     (and (double-float-p object) (in-range-p object (car args) (cadr args))))
    (mod (and (integerp object) (>= object 0) (< object (car args))))
    (unsigned-byte (and (integerp object) (>= object 0)
                        (or (null args) (eq (car args) '*)
                            (< (integer-length object) (+ (car args) 1)))))
    (signed-byte (and (integerp object)
                      (or (null args) (eq (car args) '*)
                          (< (integer-length object) (car args)))))
    (cons (and (consp object)
               (or (null args) (eq (car args) '*) (typep (car object) (car args)))
               (or (null (cdr args)) (eq (cadr args) '*) (typep (cdr object) (cadr args)))))
    ((string base-string)
     (and (stringp object) (or (null args) (eq (car args) '*) (= (length object) (car args)))))
    ((simple-string simple-base-string)
     (and (simple-string-p object) (or (null args) (eq (car args) '*) (= (length object) (car args)))))
    (simple-vector
     (and (simple-vector-p object) (or (null args) (eq (car args) '*) (= (length object) (car args)))))
    ((vector simple-array array)
     ;; Here for simple vectors and strings; ctype for the other arrays.
     (if (complex-array-kind object)
         (other-typep object (cons head args))
     (and (native-vector-p object)
          (or (null args) (eq (car args) '*)
              (if (stringp object)
                  (if (member (car args) '(character base-char standard-char)) t nil)
                  (eq (car args) t)))
          (let ((dims (if (eq head 'vector)
                          (if (or (null (cdr args)) (eq (cadr args) '*)) '* (cdr args))
                          (if (null (cdr args)) '* (cadr args)))))
            (cond ((eq dims '*) t)
                  ((eql dims 1) t)
                  ((integerp dims) nil)
                  ((and (consp dims) (null (cdr dims)))
                   (or (eq (car dims) '*) (eql (car dims) (length object))))
                  (t nil))))))
    (t (other-typep object (cons head args)))))

;;; DEFTYPE (Common-macros' expansion calls %DEFTYPE at compile time, in
;;; the compile-time environment, and at load time): the expander, a
;;; function of the type specifier and an environment, is kept on the
;;; plist of the name.
;;; Caches of results that depend on the type definitions (ctype-interface
;;; keeps its parsed specifiers and SUBTYPEP answers here); a new type or
;;; class empties them.
(defvar *type-caches-valid* nil)
(defvar *type-cache-epoch* 0)
(defun invalidate-type-caches ()
  (setf *type-caches-valid* nil
        *type-cache-epoch* (+ *type-cache-epoch* 1)))

(defun kiln.sys::%deftype (name expander)
  (setf (get name 'type-expander) expander)
  (invalidate-type-caches)
  name)

(defun typexpand-1 (type &optional environment)
  (let ((expander (and (or (symbolp type) (and (consp type) (symbolp (car type))))
                       (get (if (consp type) (car type) type) 'type-expander))))
    (if expander
        (values (funcall expander type environment) t)
        (values type nil))))

(defun typexpand (type &optional environment)
  (let ((expanded nil))
    (do () (nil)
      (multiple-value-bind (expansion expandedp) (typexpand-1 type environment)
        (unless expandedp (return (values type expanded)))
        (setq type expansion expanded t)))))

;;; Specifiers TYPEP does not know itself: DEFTYPE names, then classes
;;; (symbols) or ctype (compound specifiers; *CTYPE-TYPEP* is set once
;;; ctype is loaded).
(defvar *ctype-typep* nil)

;;; (TYPEP OBJECT 'TYPE) for a symbol TYPE that is not a standard type
;;; name: the compiler calls this with a cache of the call site, a cons
;;; (lower.lisp, LOWER-CACHED-TYPEP). Here plain TYPEP; CLOS replaces it
;;; with a version that remembers the result for the class of the last
;;; object (clos/conditions.lisp).
(defun %typep-cached (object type cache)
  (declare (ignore cache))
  (typep object type))

(defun other-typep (object type)
  (multiple-value-bind (expansion expandedp) (typexpand-1 type)
    (cond (expandedp (typep object expansion))
          ((symbolp type) (class-typep object type))
          (*ctype-typep* (funcall *ctype-typep* object type))
          (t (unknown-type type)))))

(defun unknown-type (type)
  (%primop :type-error-type type))

;;; There are no complex numbers yet.
(defun complexp (object) (declare (ignore object)) nil)

(defvar *instance-type-of* nil)

(defun type-of (object)
  (cond ((null object) 'null)
        ((eq object t) 'boolean)
        ((keywordp object) 'keyword)
        ((symbolp object) 'symbol)
        ((consp object) 'cons)
        ((fixnump object) 'fixnum)
        ((bignump object) 'bignum)
        ((ratiop object) 'ratio)
        ((single-float-p object) 'single-float)
        ((double-float-p object) 'double-float)
        ((characterp object) 'character)
        ((stringp object) (list 'simple-array 'character (list (length object))))
        ((simple-vector-p object) (list 'simple-vector (length object)))
        ((functionp object) 'compiled-function)
        ;; Standard instances: the name of the class, once CLOS sets this.
        (*instance-type-of* (funcall *instance-type-of* object))
        (t t)))

(defun coerce (object type)
  (cond ((typep object type) object)
        ((member type '(list))
         (coerce-to-list object))
        ((member type '(vector simple-vector))
         ;; Not APPLY: the list can be longer than CALL-ARGUMENTS-LIMIT.
         (let* ((l (coerce-to-list object)) (v (make-simple-vector (length l))) (i 0))
           (dolist (x l v) (setf (svref v i) x) (setq i (+ i 1)))))
        ((member type '(string simple-string))
         (let* ((l (coerce-to-list object)) (s (make-string (length l))) (i 0))
           (dolist (c l s) (setf (schar s i) c) (setq i (+ i 1)))))
        ((eq type 'character)
         (if (and (stringp object) (= (length object) 1))
             (schar object 0)
             (char (symbol-name object) 0)))
        ((member type '(float single-float short-float)) (float object))
        ((member type '(double-float long-float)) (float object 1.0d0))
        ((member (if (consp type) (car type) type)
                 '(vector simple-vector array simple-array string simple-string
                   base-string simple-base-string bit-vector simple-bit-vector))
         ;; Other vector types: MAKE-SEQUENCE knows them.
         (let* ((l (coerce-to-list object)) (s (make-sequence type (length l))) (i 0))
           (dolist (x l s) (setf (elt s i) x) (setq i (+ i 1)))))
        (t (%primop :type-error-type type))))

(defun equalp (a b)
  (cond ((eq a b) t)
        ((characterp a) (and (characterp b) (char-equal a b)))
        ((numberp a) (and (numberp b) (= a b)))
        ((consp a) (and (consp b) (equalp (car a) (car b)) (equalp (cdr a) (cdr b))))
        ((vectorp a)
         (and (vectorp b) (= (length a) (length b))
              (dotimes (i (length a) t)
                (unless (equalp (aref a i) (aref b i)) (return nil)))))
        ((and *instance-equal* (%primop :standard-instance-p a))
         (funcall *instance-equal* a b))
        (t nil)))
