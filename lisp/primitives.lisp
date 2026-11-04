(in-package #:kiln.compiler)

;;;; Primitives: global functions that the compiler open-codes, and
;;;; primops. Calls to primitives are inlined (CL functions cannot be
;;;; redefined, CLHS 11.1.2.1.2). The kernel (lisp/target/) defines each of
;;;; them as an ordinary function too, written as a call to itself, so that
;;;; #'CAR and (APPLY 'CAR ...) find a real function in the symbol's cell.
;;;;
;;;; Primops are the operations reachable only through
;;;; (KILN.SYS:%PRIMOP :NAME ARGS...), for kernel code (docs/09 §4).

(defvar *primops* (make-hash-table :test 'eq)
  "Keyword -> function of the list of argument operands.")

(defmacro define-primitive (name lambda-list &body body)
  "Defines a primitive with a fixed number of arguments."
  (let ((vals (gensym "VALS")))
    `(setf (gethash ',name *primitives*)
           (lambda (,vals)
             (unless (= (length ,vals) ,(length lambda-list))
               (fail "~S called with ~D arguments, takes ~D"
                     ',name (length ,vals) ,(length lambda-list)))
             (destructuring-bind ,lambda-list ,vals ,@body)))))

(defmacro define-nary-primitive (name (vals) &body body)
  `(setf (gethash ',name *primitives*) (lambda (,vals) ,@body)))

(defmacro define-primop (name lambda-list &body body)
  (let ((vals (gensym "VALS")))
    `(setf (gethash ,name *primops*)
           (lambda (,vals)
             (unless (= (length ,vals) ,(length lambda-list))
               (fail "primop ~S called with ~D arguments, takes ~D"
                     ,name (length ,vals) ,(length lambda-list)))
             (destructuring-bind ,lambda-list ,vals ,@body)))))

(defun boolean-value (condition)
  (copy-to-var `(:select ,condition ,(t-value) ,(nil-value))))

;;; Arithmetic. Fixnums are open-coded; other numbers, and fixnum
;;; overflow, take the slow path: a call to the kernel's two-argument
;;; function (docs/09 §8), which dispatches on the number types.

(defun emit-check-fixnums (a b)
  "For operations defined on fixnums only."
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:and (:or ,a ,b) 1) bad ok)
    (start-block bad)
    (emit-error +err-not-fixnum+ `(:select (:and ,a 1) ,a ,b))
    (start-block ok)))

(defun emit-slow-call (name &rest vals)
  "Primary value of a call to the kernel function NAME."
  (values (emit-lisp-call (function-cell-value name) vals)))

(defun emit-arith (op a b)
  (let ((r (new-var)) (ovf (new-var :raw))
        (fast (new-block)) (slow (new-block)) (done (new-block)))
    (br `(:and (:or ,a ,b) 1) slow fast)
    (start-block fast)
    (ecase op
      (+ (emit `(:add-ovf ,r ,ovf ,a ,b)))
      (- (emit `(:sub-ovf ,r ,ovf ,a ,b)))
      (* (emit `(:mul-ovf ,r ,ovf (:sar ,a ,+fixnum-shift+) ,b))))
    (br ovf slow done)
    (start-block slow)
    (emit `(:set ,r ,(emit-slow-call (ecase op
                                        (+ 'kiln.kernel::two-arg-+)
                                        (- 'kiln.kernel::two-arg--)
                                        (* 'kiln.kernel::two-arg-*))
                                      a b)))
    (jump done)
    (start-block done)
    r))

(defun emit-check-number (a)
  "Signals an error unless A is a number (via the slow path)."
  (let ((slow (new-block)) (ok (new-block)))
    (br `(:and ,a 1) slow ok)
    (start-block slow)
    (emit-slow-call 'kiln.kernel::check-number a)
    (jump ok)
    (start-block ok)))

(defun fold-arith (op identity vals)
  (cond ((null vals) identity)
        ((null (rest vals))
         (emit-check-number (first vals))
         (first vals))
        (t (reduce (lambda (a b) (emit-arith op a b)) vals))))

(define-nary-primitive + (vals) (fold-arith '+ 0 vals))
(define-nary-primitive * (vals) (fold-arith '* (ash 1 +fixnum-shift+) vals))
(define-nary-primitive - (vals)
  (cond ((null vals) (fail "- needs at least one argument"))
        ((null (rest vals)) (emit-arith '- 0 (first vals)))
        (t (reduce (lambda (a b) (emit-arith '- a b)) vals))))
(define-primitive 1+ (a) (emit-arith '+ a (ash 1 +fixnum-shift+)))
(define-primitive 1- (a) (emit-arith '- a (ash 1 +fixnum-shift+)))

(defun emit-compare-pair (op a b)
  "Raw 0/1 variable: does OP hold between the numbers A and B?"
  (let ((r (new-var :raw)) (fast (new-block)) (slow (new-block)) (done (new-block)))
    (br `(:and (:or ,a ,b) 1) slow fast)
    (start-block fast)
    (emit `(:set ,r (,op ,a ,b)))
    (jump done)
    (start-block slow)
    (emit `(:set ,r (:ne ,(emit-slow-call (ecase op
                                             (:lt 'kiln.kernel::two-arg-<)
                                             (:gt 'kiln.kernel::two-arg->)
                                             (:le 'kiln.kernel::two-arg-<=)
                                             (:ge 'kiln.kernel::two-arg->=)
                                             (:eq 'kiln.kernel::two-arg-=))
                                           a b)
                         ,(nil-value))))
    (jump done)
    (start-block done)
    r))

(defun emit-compare (op vals)
  "Chained comparison: true if OP holds for each adjacent pair. All pairs
are compared (no short circuit), which also checks every argument."
  (when (null vals) (fail "comparison needs at least one argument"))
  (if (null (rest vals))
      (progn (emit-check-number (first vals)) (t-value))
      (let ((all nil))
        (loop for (a b) on vals
              while b
              do (let ((p (emit-compare-pair op a b)))
                   (setf all (if all `(:and ,all ,p) p))))
        (boolean-value all))))

(macrolet ((compare (name op)
             `(define-nary-primitive ,name (vals) (emit-compare ,op vals))))
  (compare < :lt) (compare > :gt) (compare <= :le) (compare >= :ge) (compare = :eq))

;;; Objects

(define-primitive eq (a b) (boolean-value `(:eq ,a ,b)))
;;; Only fixnums, symbols and conses exist so far, so EQL is EQ.
(define-primitive eql (a b)
  ;; Identical objects are EQL; otherwise only numbers that are heap
  ;; objects (bignums) can be, which the kernel decides.
  (let ((r (copy-to-var (t-value)))
        (no (new-block)) (slow (new-block)) (false (new-block)) (done (new-block)))
    (br `(:eq ,a ,b) done no)
    (start-block no)
    (br `(:eq (:and ,a ,+tag-mask+) ,+tag-general+) slow false)
    (start-block slow)
    (emit `(:set ,r ,(emit-slow-call 'kiln.kernel::eql-slow a b)))
    (jump done)
    (start-block false)
    (emit `(:set ,r ,(nil-value)))
    (jump done)
    (start-block done)
    r))
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
(defun emit-integer-test (a)
  "Raw 0/1: is A a fixnum or a bignum?"
  `(:or (:eq (:and ,a 1) 0) ,(emit-kind-test a +kind-bignum+)))
(define-primitive integerp (a) (boolean-value (emit-integer-test a)))
;;; Only integers so far (M3.4 adds ratios and floats).
(define-primitive numberp (a) (boolean-value (emit-integer-test a)))
(define-primitive zerop (a) (boolean-value (emit-compare-pair :eq a 0)))
(define-primitive plusp (a) (boolean-value (emit-compare-pair :gt a 0)))
(define-primitive minusp (a) (boolean-value (emit-compare-pair :lt a 0)))

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

(defun emit-nthcdr (n list)
  (emit-check-fixnums n n)
  (let ((i (copy-to-var n)) (cur (copy-to-var list))
        (head (new-block)) (body (new-block)) (done (new-block)))
    (jump head)
    (start-block head)
    (br `(:gt ,i 0) body done)
    (start-block body)
    (emit `(:set ,cur ,(emit-car-cdr cur +cons-cdr+)))
    (emit `(:set ,i (:sub ,i ,(ash 1 +fixnum-shift+))))
    (jump head)
    (start-block done)
    cur))

(define-primitive nthcdr (n list) (emit-nthcdr n list))
(define-primitive nth (n list) (emit-car-cdr (emit-nthcdr n list) +cons-car+))

(defun emit-check-cons (x)
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:eq (:and ,x ,+tag-mask+) ,+tag-cons+) ok bad)
    (start-block bad)
    (emit-error +err-not-list+ x)
    (start-block ok)))

;;; No write barrier yet: only non-generational GC plans (docs/07 §2).
(define-primitive (setf car) (v x) (emit-check-cons x) (emit `(:store ,x ,+cons-car+ ,v)) v)
(define-primitive (setf cdr) (v x) (emit-check-cons x) (emit `(:store ,x ,+cons-cdr+ ,v)) v)
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

;;; Primitives may return a second value, the number of values (docs/08
;;; §5.3); those that return one value omit it.

(define-nary-primitive values (vals)
  (when (> (length vals) (1+ +values-max+))
    (fail "VALUES with more than ~D arguments" (1+ +values-max+)))
  ;; All arguments are evaluated: store the values after the first.
  (loop for v in (rest vals)
        for i from 0
        do (emit `(:store :ctx ,(+ +ctx-values+ (* 8 i)) ,v)))
  (values (if vals (first vals) (nil-value)) (length vals)))

(define-primitive values-list (list)
  (emit-check-proper-list list)
  (emit-list-to-values list))

(define-nary-primitive apply (vals)
  (when (< (length vals) 2) (fail "APPLY needs a function and a list"))
  (let ((f (emit-function-designator (first vals)))
        (list (emit-list (butlast (rest vals)) (car (last vals)))))
    (emit-check-proper-list list)
    (emit-apply f list)))

(define-primitive print (a)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-print) (,r) (:ctx ,a) :nil))
    r))

;;; Functions and symbols

(defun emit-check-proper-list (list)
  "Signals an error unless LIST is a proper list (no cycle check yet)."
  (let ((cur (copy-to-var list))
        (head (new-block)) (cons-b (new-block)) (other (new-block))
        (bad (new-block)) (done (new-block)))
    (jump head)
    (start-block head)
    (br `(:eq (:and ,cur ,+tag-mask+) ,+tag-cons+) cons-b other)
    (start-block cons-b)
    (emit `(:set ,cur (:load ,cur ,+cons-cdr+)))
    (jump head)
    (start-block other)
    (br `(:eq ,cur ,(nil-value)) done bad)
    (start-block bad)
    (emit-error +err-not-list+ list)
    (start-block done)))

(define-nary-primitive funcall (vals)
  (when (null vals) (fail "FUNCALL needs a function"))
  (emit-lisp-call (emit-function-designator (first vals)) (rest vals)))

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
  (let ((v (emit-symbol-value name)))
    (emit-check-bound v name)
    v))

(define-primitive (setf symbol-value) (value name)
  (emit-check-symbol name)
  (emit-set-symbol-value name value)
  value)

(define-primitive boundp (name)
  (emit-check-symbol name)
  (boolean-value `(:ne ,(emit-symbol-value name) ,+unbound+)))

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
;;; Primops (docs/09 §4). Type checks are the kernel's job; primops that
;;; index check their index.

(defun emit-kind-test (x kind)
  "Raw 0/1: is X a general object of KIND? Safe for any value."
  (let ((r (new-var :raw)) (general (new-block)) (no (new-block)) (join (new-block)))
    (br `(:eq (:and ,x ,+tag-mask+) ,+tag-general+) general no)
    (start-block general)
    (emit `(:set ,r (:eq (:and (:load ,x ,(- +tag-general+)) ,+kind-mask+) ,kind)))
    (jump join)
    (start-block no)
    (emit `(:set ,r 0))
    (jump join)
    (start-block join)
    r))

(defun vector-length (v)
  "Fixnum length of the vector or string V."
  `(:shl (:shr (:load ,v ,(- +tag-general+)) ,+length-shift+) ,+fixnum-shift+))

(defun emit-check-index (v i)
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:or (:and ,i 1) (:or (:lt ,i 0) (:ge ,i ,(vector-length v)))) bad ok)
    (start-block bad)
    (emit-error +err-index+ i)
    (start-block ok)))

(defun emit-fill-loop (n store)
  "Calls STORE with a raw index variable for each index below the raw
operand N."
  (let ((i (copy-to-var 0 :raw)) (head (new-block)) (body (new-block)) (done (new-block)))
    (jump head)
    (start-block head)
    (br `(:lt ,i ,n) body done)
    (start-block body)
    (funcall store i)
    (emit `(:set ,i (:add ,i 1)))
    (jump head)
    (start-block done)))

(defun emit-check-length (n)
  "N must be a non-negative fixnum that fits the header's length field."
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:or (:and ,n 1) (:or (:lt ,n 0) (:gt ,n ,(ash (1- (ash 1 48)) +fixnum-shift+)))) bad ok)
    (start-block bad)
    (emit-error +err-index+ n)
    (start-block ok)))

(define-primop :fixnump (x) (boolean-value `(:eq (:and ,x 1) 0)))
(define-primop :characterp (x)
  (boolean-value `(:eq (:and ,x ,+immediate-mask+) ,+character-tag+)))
(define-primop :stringp (x) (boolean-value (emit-kind-test x +kind-string+)))
(define-primop :simple-vector-p (x) (boolean-value (emit-kind-test x +kind-simple-vector+)))
(define-primop :symbolp (x)
  (boolean-value `(:or (:eq ,x ,(nil-value)) ,(emit-kind-test x +kind-symbol+))))
(define-primop :functionp (x) (boolean-value (emit-kind-test x +kind-function+)))

(define-primop :char-code (c)
  (copy-to-var `(:shl (:shr ,c ,+character-shift+) ,+fixnum-shift+)))
(define-primop :code-char (n)
  (copy-to-var `(:or (:shl (:sar ,n ,+fixnum-shift+) ,+character-shift+) ,+character-tag+)))

(define-primop :length (v) (copy-to-var (vector-length v)))

(define-primop :schar (s i)
  (emit-check-index s i)
  (copy-to-var `(:or (:shl (:load32 (:add ,s (:shl ,i 1)) ,+vector-data+) ,+character-shift+)
                     ,+character-tag+)))
(define-primop :set-schar (s i c)
  (emit-check-index s i)
  (emit `(:store32 (:add ,s (:shl ,i 1)) ,+vector-data+ (:shr ,c ,+character-shift+)))
  c)

(define-primop :make-string (n c)
  (emit-check-length n)
  (let* ((len (copy-to-var `(:sar ,n ,+fixnum-shift+) :raw))
         (code (copy-to-var `(:shr ,c ,+character-shift+) :raw))
         (p (emit-alloc `(:add 8 (:and (:add (:shl ,len 2) 7) -8))
                        `(:or (:shl ,len ,+length-shift+) ,+kind-string+))))
    (emit-fill-loop len (lambda (i) (emit `(:store32 (:add ,p (:shl ,i 2)) 8 ,code))))
    (copy-to-var `(:add ,p ,+tag-general+))))

(define-primop :svref (v i)
  (emit-check-index v i)
  (copy-to-var `(:load (:add ,v (:shl ,i 2)) ,+vector-data+)))
(define-primop :set-svref (v i x)
  (emit-check-index v i)
  (emit `(:store (:add ,v (:shl ,i 2)) ,+vector-data+ ,x))
  x)

(define-primop :make-simple-vector (n x)
  (emit-check-length n)
  (let* ((len (copy-to-var `(:sar ,n ,+fixnum-shift+) :raw))
         (x (copy-to-var x))
         (p (emit-alloc `(:add 8 (:shl ,len 3))
                        `(:or (:shl ,len ,+length-shift+) ,+kind-simple-vector+))))
    (emit-fill-loop len (lambda (i) (emit `(:store (:add ,p (:shl ,i 3)) 8 ,x))))
    (copy-to-var `(:add ,p ,+tag-general+))))

(define-primop :symbol-name (s) (copy-to-var `(:load ,s ,+symbol-name+)))
(define-primop :symbol-package (s) (copy-to-var `(:load ,s ,+symbol-package+)))
(define-primop :symbol-plist (s) (copy-to-var `(:load ,s ,+symbol-plist+)))
(define-primop :set-symbol-plist (s v) (emit `(:store ,s ,+symbol-plist+ ,v)) v)

(define-primop :evenp (n)
  (emit-check-fixnums n n)
  (boolean-value `(:eq (:and ,n 2) 0)))
(define-primop :half (n)
  (emit-check-fixnums n n)
  (copy-to-var `(:and (:sar ,n 1) -2)))

(macrolet ((define-type-error (name code)
             `(define-primop ,name (x)
                (emit-error ,code x)
                (nil-value))))
  (define-type-error :type-error-character +err-not-character+)
  (define-type-error :type-error-string +err-not-string+)
  (define-type-error :type-error-vector +err-not-vector+)
  (define-type-error :type-error-sequence +err-not-sequence+)
  (define-type-error :type-error-symbol +err-not-symbol+))

(define-primop :bignump (x) (boolean-value (emit-kind-test x +kind-bignum+)))

(defun rt-integer-op () (module-import-func "kiln_rt_integer_op" 4 1 :unwinds))

(defun emit-integer-op (code a b)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-integer-op) (,r) (:ctx ,code ,a ,b) ,(handler)))
    r))

;;; Operation codes: rust/kiln-rt/src/bignum.rs.
(macrolet ((define-integer-ops (&rest specs)
             `(progn
                ,@(mapcar (lambda (spec)
                            (destructuring-bind (name code &optional two-values) spec
                              `(define-primop ,name (a b)
                                 ,(if two-values
                                      ;; The remainder is in ctx.values[0].
                                      `(values (emit-integer-op ,code a b) 2)
                                      `(emit-integer-op ,code a b)))))
                          specs))))
  (define-integer-ops
    (:integer-add 0) (:integer-sub 1) (:integer-mul 2)
    (:integer-truncate 3 t) (:integer-floor 4 t) (:integer-ceiling 5 t) (:integer-round 6 t)
    (:integer-compare 7) (:integer-logand 8) (:integer-logior 9) (:integer-logxor 10)
    (:integer-ash 11) (:integer-gcd 12) (:integer-expt 13) (:integer-length 14)))

;;; Fixnum-only bit operations, for the kernel's fast paths: on tagged
;;; fixnums (n << 1), AND, OR and XOR give the tagged result.
(define-primop :fixnum-logand (a b) (copy-to-var `(:and ,a ,b)))
(define-primop :fixnum-logior (a b) (copy-to-var `(:or ,a ,b)))
(define-primop :fixnum-logxor (a b) (copy-to-var `(:xor ,a ,b)))
(define-primop :type-error-integer (x) (emit-error +err-not-integer+ x) (nil-value))
