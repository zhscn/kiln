(in-package #:kiln.compiler)

;;;; Primitives: global functions that the compiler open-codes. Calls to
;;;; them are inlined (CL functions cannot be redefined, CLHS 11.1.2.1.2).
;;;; When one is used as a value (#'CAR), a wrapper function with the
;;;; primitive's natural arity is generated.
;;;;
;;;; This is interim: once the kernel library is cross-compiled (M3), most
;;;; of these become ordinary functions written with %PRIMOP, and only the
;;;; inlining remains here.


(defmacro define-primitive (name lambda-list &body body)
  "Defines a primitive with a fixed number of arguments."
  (let ((vals (gensym "VALS")))
    `(setf (gethash ',name *primitive-arity*) ,(length lambda-list)
           (gethash ',name *primitives*)
           (lambda (,vals)
             (unless (= (length ,vals) ,(length lambda-list))
               (fail "~S called with ~D arguments, takes ~D"
                     ',name (length ,vals) ,(length lambda-list)))
             (destructuring-bind ,lambda-list ,vals ,@body)))))

(defmacro define-nary-primitive (name (vals &optional arity) &body body)
  `(progn
     ,@(when arity `((setf (gethash ',name *primitive-arity*) ,arity)))
     (setf (gethash ',name *primitives*) (lambda (,vals) ,@body))))

(defun primitive-function-object (name)
  (or (gethash name *primitive-functions*)
      (let ((arity (or (gethash name *primitive-arity*)
                       (fail "~S cannot be used as a function object yet" name)))
            (label (fresh-label (format nil "kiln_prim_~A_" (mangle (princ-to-string name))))))
        (let ((*regions* '()))
          (with-function (label)
            (let ((*self* (copy-to-var :self)))
              (declare (ignorable *self*))
              (let ((bad (new-block)) (ok (new-block)))
                (br `(:ne :nargs ,arity) bad ok)
                (start-block bad)
                (emit-error +err-wrong-nargs+ `(:shl :nargs ,+fixnum-shift+))
                (start-block ok))
              (let ((vals (loop for reg in '(:a0 :a1 :a2)
                                repeat arity
                                collect (copy-to-var reg))))
                (emit `(:return ,(funcall (gethash name *primitives*) vals) 1))))))
        (let ((data (format nil "~A_fobj" label)))
          (module-data data `(:words ,+kind-function+ (:func ,label)))
          (setf (gethash name *primitive-functions*) `(:addr ,data ,+tag-general+))))))

(defun boolean-value (condition)
  (copy-to-var `(:select ,condition ,(t-value) ,(nil-value))))

;;; Fixnum arithmetic

(defun emit-check-fixnums (a b)
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:and (:or ,a ,b) 1) bad ok)
    (start-block bad)
    (emit-error +err-not-fixnum+ `(:select (:and ,a 1) ,a ,b))
    (start-block ok)))

(defun emit-arith (op a b)
  (let ((r (new-var)) (ovf (new-var :raw))
        (bad (new-block)) (ok (new-block)))
    (emit-check-fixnums a b)
    (ecase op
      (+ (emit `(:add-ovf ,r ,ovf ,a ,b)))
      (- (emit `(:sub-ovf ,r ,ovf ,a ,b)))
      (* (emit `(:mul-ovf ,r ,ovf (:sar ,a ,+fixnum-shift+) ,b))))
    (br ovf bad ok)
    (start-block bad)
    (emit-error +err-overflow+ a)
    (start-block ok)
    r))

(defun fold-arith (op identity vals)
  (cond ((null vals) identity)
        ((null (rest vals))
         (emit-check-fixnums (first vals) (first vals))
         (first vals))
        (t (reduce (lambda (a b) (emit-arith op a b)) vals))))

(define-nary-primitive + (vals 2) (fold-arith '+ 0 vals))
(define-nary-primitive * (vals 2) (fold-arith '* (ash 1 +fixnum-shift+) vals))
(define-nary-primitive - (vals 2)
  (cond ((null vals) (fail "- needs at least one argument"))
        ((null (rest vals)) (emit-arith '- 0 (first vals)))
        (t (reduce (lambda (a b) (emit-arith '- a b)) vals))))
(define-primitive 1+ (a) (emit-arith '+ a (ash 1 +fixnum-shift+)))
(define-primitive 1- (a) (emit-arith '- a (ash 1 +fixnum-shift+)))

(macrolet ((compare (name op)
             `(define-primitive ,name (a b)
                (emit-check-fixnums a b)
                (boolean-value (list ,op a b)))))
  (compare < :lt) (compare > :gt) (compare <= :le) (compare >= :ge) (compare = :eq))

;;; Objects

(define-primitive eq (a b) (boolean-value `(:eq ,a ,b)))
;;; Only fixnums, symbols and conses exist so far, so EQL is EQ.
(define-primitive eql (a b) (boolean-value `(:eq ,a ,b)))
(define-primitive null (a) (boolean-value `(:eq ,a ,(nil-value))))
(define-primitive not (a) (boolean-value `(:eq ,a ,(nil-value))))
(define-primitive consp (a) (boolean-value `(:eq (:and ,a ,+tag-mask+) ,+tag-cons+)))
(define-primitive atom (a) (boolean-value `(:ne (:and ,a ,+tag-mask+) ,+tag-cons+)))

(define-primitive listp (a)
  (boolean-value `(:or (:eq (:and ,a ,+tag-mask+) ,+tag-cons+) (:eq ,a ,(nil-value)))))

(defun emit-kind-p (a kind)
  "Is A a general object of KIND?"
  (let ((r (new-var)) (general (new-block)) (no (new-block)) (join (new-block)))
    (br `(:eq (:and ,a ,+tag-mask+) ,+tag-general+) general no)
    (start-block general)
    (emit `(:set ,r (:select (:eq (:and (:load ,a ,(- +tag-general+)) ,+kind-mask+) ,kind)
                             ,(t-value) ,(nil-value))))
    (jump join)
    (start-block no)
    (emit `(:set ,r ,(nil-value)))
    (jump join)
    (start-block join)
    r))

(define-primitive symbolp (a) (emit-kind-p a +kind-symbol+))
(define-primitive functionp (a) (emit-kind-p a +kind-function+))
;;; Only fixnums exist so far.
(define-primitive integerp (a) (boolean-value `(:eq (:and ,a 1) 0)))
(define-primitive numberp (a) (boolean-value `(:eq (:and ,a 1) 0)))
(define-primitive zerop (a) (emit-check-fixnums a a) (boolean-value `(:eq ,a 0)))
(define-primitive plusp (a) (emit-check-fixnums a a) (boolean-value `(:gt ,a 0)))
(define-primitive minusp (a) (emit-check-fixnums a a) (boolean-value `(:lt ,a 0)))

(define-primitive cons (a b) (emit-cons a b))

(defun emit-car-cdr (x offset)
  (let ((r (new-var))
        (is-cons (new-block)) (other (new-block)) (is-nil (new-block))
        (bad (new-block)) (join (new-block)))
    (br `(:eq (:and ,x ,+tag-mask+) ,+tag-cons+) is-cons other)
    (start-block is-cons)
    (emit `(:set ,r (:load ,x ,offset)))
    (jump join)
    (start-block other)
    (br `(:eq ,x ,(nil-value)) is-nil bad)
    (start-block is-nil)
    (emit `(:set ,r ,(nil-value)))
    (jump join)
    (start-block bad)
    (emit-error +err-not-list+ x)
    (start-block join)
    r))

(define-primitive car (x) (emit-car-cdr x +cons-car+))
(define-primitive cdr (x) (emit-car-cdr x +cons-cdr+))

(define-primitive first (x) (emit-car-cdr x +cons-car+))
(define-primitive rest (x) (emit-car-cdr x +cons-cdr+))
(define-primitive cadr (x) (emit-car-cdr (emit-car-cdr x +cons-cdr+) +cons-car+))
(define-primitive second (x) (emit-car-cdr (emit-car-cdr x +cons-cdr+) +cons-car+))
(define-primitive cddr (x) (emit-car-cdr (emit-car-cdr x +cons-cdr+) +cons-cdr+))

(define-primitive endp (x)
  (let ((r (new-var))
        (is-cons (new-block)) (other (new-block)) (is-nil (new-block))
        (bad (new-block)) (join (new-block)))
    (br `(:eq (:and ,x ,+tag-mask+) ,+tag-cons+) is-cons other)
    (start-block is-cons)
    (emit `(:set ,r ,(nil-value)))
    (jump join)
    (start-block other)
    (br `(:eq ,x ,(nil-value)) is-nil bad)
    (start-block is-nil)
    (emit `(:set ,r ,(t-value)))
    (jump join)
    (start-block bad)
    (emit-error +err-not-list+ x)
    (start-block join)
    r))

(defun emit-check-cons (x)
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:eq (:and ,x ,+tag-mask+) ,+tag-cons+) ok bad)
    (start-block bad)
    (emit-error +err-not-list+ x)
    (start-block ok)))

;;; No write barrier yet: only non-generational GC plans (docs/07 §2).
(define-primitive rplaca (x v) (emit-check-cons x) (emit `(:store ,x ,+cons-car+ ,v)) x)
(define-primitive rplacd (x v) (emit-check-cons x) (emit `(:store ,x ,+cons-cdr+ ,v)) x)

(defun emit-list (vals tail)
  (let ((r tail))
    (dolist (v (reverse vals) r)
      (setf r (emit-cons v r)))))

(define-nary-primitive list (vals) (emit-list vals (nil-value)))
(define-nary-primitive list* (vals)
  (when (null vals) (fail "LIST* needs at least one argument"))
  (emit-list (butlast vals) (car (last vals))))

(define-nary-primitive values (vals)
  ;; Multiple values are not implemented yet: only the primary value.
  (if vals (first vals) (nil-value)))

(define-primitive print (a)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-print) (,r) (:ctx ,a) :nil))
    r))

;;; Functions and symbols

(define-nary-primitive funcall (vals)
  (when (null vals) (fail "FUNCALL needs a function"))
  (let ((f (first vals)))
    (emit-check-function f)
    (emit-lisp-call f (rest vals))))

(define-primitive fdefinition (name)
  (emit-check-symbol name)
  (copy-to-var `(:load ,name ,+symbol-function+)))

(define-primitive (setf fdefinition) (function name)
  (emit-check-function function)
  (emit-check-symbol name)
  (emit `(:store ,name ,+symbol-function+ ,function))
  function)

(define-primitive symbol-value (name)
  (emit-check-symbol name)
  (let ((v (copy-to-var `(:load ,name ,+symbol-value+)))
        (bad (new-block)) (ok (new-block)))
    (br `(:eq ,v ,+unbound+) bad ok)
    (start-block bad)
    (emit-error +err-unbound-variable+ name)
    (start-block ok)
    v))

(define-primitive (setf symbol-value) (value name)
  (emit-check-symbol name)
  (emit `(:store ,name ,+symbol-value+ ,value))
  value)

(define-primitive boundp (name)
  (emit-check-symbol name)
  (boolean-value `(:ne (:load ,name ,+symbol-value+) ,+unbound+)))

;;; Macro definitions and proclamations take effect at compile time (front
;;; end); the run-time image has no macro environment yet.
(define-nary-primitive (setf macro-function) (vals)
  (if vals (first vals) (nil-value)))
(define-nary-primitive proclaim (vals)
  (declare (ignore vals))
  (nil-value))

;;; kiln.sys

(define-primitive kiln.sys:%gc ()
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-gc) (,r) (:ctx) ,(handler)))
    r))

(define-primitive kiln.sys:%gc-count ()
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-gc-count) (,r) (:ctx) :nil))
    r))

(define-primitive kiln.sys:%call-on-new-stack (f arg)
  (let ((r (new-var)))
    (emit-check-function f)
    (emit `(:call-rt ,(rt-call-on-new-stack) (,r) (:ctx ,f ,arg) ,(handler)))
    r))
