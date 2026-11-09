;;;; Types for the built-in classes: TYPEP, TYPE-OF, COERCE, EQUALP.
;;;;
;;;; TYPEP knows the built-in atomic types and the common compound
;;;; specifiers itself; DEFTYPE names are expanded, class names go to CLOS
;;;; and other compound specifiers to ctype, once those are loaded.
;;;; The compiler open-codes TYPEP for constant atomic types.

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
      (let ((head (car type)))
        (if (or (eq head 'or) (eq head 'and) (eq head 'not))
            ;; These can depend on the class alone: CLOS caches them.
            (%cached-typep object type)
            (compound-typep object head (cdr type))))
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
        (base-char (and (characterp object) (< (char-code object) 128)))
        (standard-char (and (characterp object) (standard-char-p object)))
        (extended-char (and (characterp object) (>= (char-code object) 128)))
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
        (complex (complexp object))
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

(defun complex-component-type (type)
  (case type
    ((single-float short-float) 'single-float)
    ((double-float long-float) 'double-float)
    ((integer rational ratio fixnum bignum bit signed-byte unsigned-byte) 'rational)
    ((float real) type)
    ((nil) nil)
    (t (if (fboundp 'upgraded-complex-part-type)
           (upgraded-complex-part-type type)
           type))))

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
    (complex (and (complexp object)
                  (or (null args) (eq (car args) '*)
                      (let ((type (complex-component-type (car args))))
                        (and (typep (realpart object) type)
                             (typep (imagpart object) type))))))

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
                  (or (eq (car args) t)
                      (eq (upgraded-array-element-type (car args)) t))))
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
;;;
;;; Everything cached from type facts (the answers of TYPEP, the parsed
;;; specifiers and SUBTYPEP answers of ctype) holds until a type or a class
;;; changes: the version of the type assumption (assumptions.lisp) guards
;;; the call-site caches, and INVALIDATE-TYPE-CACHES empties the tables.

;;; The results of TYPEP that depend only on the object's class, which
;;; CLOS keeps (clos/conditions.lisp, %CACHED-TYPEP): pairs of a key (the
;;; stamp of the object's class, doubled, plus 1 if the result is true)
;;; and the type specifier, direct mapped by the stamp and the
;;; specifier's identity hash. *UNCACHEABLE-TYPES* holds specifiers known
;;; not to depend on the class alone, by their identity hash.
(defvar *typep-cache* (make-simple-vector (* 2 4096) nil))
(defvar *uncacheable-types* (make-simple-vector 512 nil))

(defun clear-simple-vector (vector)
  (dotimes (i (length vector) vector)
    (setf (svref vector i) nil)))

(defun invalidate-type-caches ()
  "A type or a class changed: the answers in the TYPEP tables may not hold
any longer."
  (clear-simple-vector *typep-cache*)
  (clear-simple-vector *uncacheable-types*))

(defun type-assumption-changed (names)
  "The watcher of the type assumptions: NAMES changed."
  (declare (ignore names))
  (invalidate-type-caches))

(register-assumption-watcher :type #'type-assumption-changed)

(defun kiln.sys::%deftype (name expander)
  (check-type-name name)
  (setf (get name 'type-expander) expander)
  ;; A DEFTYPE of the same name changes what every use of it means.
  (change-assumption :type name)
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
  (if (symbolp type)
      (%cached-typep object type)
      (uncached-other-typep object type)))

;;; (TYPEP OBJECT TYPE) for a symbol TYPE that is not a standard type name
;;; and for (OR ...), (AND ...) and (NOT ...): CLOS replaces this with a
;;; version that caches the results that depend only on the class.
(defun %cached-typep (object type)
  (uncached-typep object type))

(defun uncached-typep (object type)
  (if (consp type)
      (compound-typep object (car type) (cdr type))
      (uncached-other-typep object type)))

(defun uncached-other-typep (object type)
  (multiple-value-bind (expansion expandedp) (typexpand-1 type)
    (cond (expandedp (typep object expansion))
          ((not (consp type)) (class-typep object type))
          (*ctype-typep* (funcall *ctype-typep* object type))
          (t (unknown-type type)))))

(defun unknown-type (type)
  (%primop :type-error-type type))

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
        ((complexp object)
         (list 'complex (let ((r (realpart object)))
                          (cond ((single-float-p r) 'single-float)
                                ((double-float-p r) 'double-float)
                                (t 'rational)))))
        ((double-float-p object) 'double-float)
        ((characterp object) 'character)
        ((stringp object) (list 'simple-array 'character (list (length object))))
        ((simple-vector-p object) (list 'simple-vector (length object)))
        ((functionp object) 'compiled-function)
        ;; Standard instances: the name of the class, once CLOS sets this.
        (*instance-type-of* (funcall *instance-type-of* object))
        (t t)))

(defun coercion-error (object type)
  (error 'simple-type-error :datum object :expected-type type
         :format-control "~S cannot be converted to ~S."
         :format-arguments (list object type)))

(defun coerce-complex (object type output-type)
  (unless (numberp object) (coercion-error object output-type))
  (let* ((part (if (and (consp type) (cdr type)) (second type) '*))
         (part (if (eq part '*) part (complex-component-type (typexpand part))))
         (head (if (consp part) (car part) part))
         (result
           (cond ((member head '(single-float short-float float))
                  (complex (float (realpart object) 1.0) (float (imagpart object) 1.0)))
                 ((member head '(double-float long-float))
                  (complex (float (realpart object) 1.0d0) (float (imagpart object) 1.0d0)))
                 ((and part (realp object)) (complex object))
                 (t (coercion-error object output-type)))))
    ;; Rational complexes with zero imaginary part have real canonical form.
    (unless (or (typep result output-type) (rationalp result))
      (coercion-error object output-type))
    result))

(defun coerce (object output-type)
  (when (typep object output-type) (return-from coerce object))
  (let* ((type (typexpand (if (or (symbolp output-type) (consp output-type))
                            output-type (class-name output-type))))
         (head (if (consp type) (car type) type)))
    (cond ((eq type 'function)
           (cond ((symbolp object)
                  (when (or (macro-function object) (special-operator-p object))
                    (%runtime-error 6 object))
                  (symbol-function object))
                 ((setf-function-name-p object) (fdefinition object))
                 ((and (consp object) (eq (car object) 'lambda))
                  (progv (list '*compile-function*) (list nil)
                    (values (compile nil object))))
                 (t (coercion-error object output-type))))
          ((eq type 'character) (character object))
          ((member head '(float single-float short-float double-float long-float))
           (unless (realp object) (coercion-error object output-type))
           (let ((result (float object (if (member head '(double-float long-float))
                                          1.0d0 1.0))))
             (unless (typep result output-type) (coercion-error object output-type))
             result))
          ((eq head 'complex) (coerce-complex object type output-type))
          ((eq type 'list)
           (unless (typep object 'sequence) (coercion-error object output-type))
           (coerce-to-list object))
          ((member head '(cons null vector simple-vector array simple-array string simple-string
                          base-string simple-base-string bit-vector simple-bit-vector))
           (unless (typep object 'sequence) (coercion-error object output-type))
           (let* ((list (coerce-to-list object))
                  (result (make-sequence type (length list))) (index 0))
             (dolist (element list result)
               (setf (elt result index) element)
               (incf index))))
          (t (coercion-error object output-type)))))

(defun equalp (a b)
  (cond ((eq a b) t)
        ((characterp a) (and (characterp b) (char-equal a b)))
        ((numberp a) (and (numberp b) (= a b)))
        ((consp a) (and (consp b) (equalp (car a) (car b)) (equalp (cdr a) (cdr b))))
        ((vectorp a)
         (and (vectorp b) (= (length a) (length b))
              (dotimes (i (length a) t)
                (unless (equalp (aref a i) (aref b i)) (return nil)))))
        ((arrayp a)
         (and (arrayp b) (equal (array-dimensions a) (array-dimensions b))
              (dotimes (i (array-total-size a) t)
                (unless (equalp (row-major-aref a i) (row-major-aref b i))
                  (return nil)))))
        ((%primop :structure-instance-p a)
         (and (%primop :structure-instance-p b)
              (eq (%primop :structure-layout a) (%primop :structure-layout b))
              (let ((size (svref (%primop :structure-layout a) 5)))
                (dotimes (i size t)
                  (unless (equalp (%primop :structure-slot a i)
                                  (%primop :structure-slot b i))
                    (return nil))))))
        ((and *instance-equalp* (%primop :standard-instance-p a))
         (funcall *instance-equalp* a b))
        (t nil)))
