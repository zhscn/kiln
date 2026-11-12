(in-package #:kiln.compiler)

;;;; Primitives: global functions that the compiler open-codes, and
;;;; primops. Calls to primitives are inlined (CL functions cannot be
;;;; redefined, CLHS 11.1.2.1.2). The kernel (lisp/target/) defines each of
;;;; them as an ordinary function too, written as a call to itself, so that
;;;; #'CAR and (APPLY 'CAR ...) find a real function in the symbol's cell.
;;;;
;;;; Primops are the operations reachable only through
;;;; (KILN.SYS:%PRIMOP :NAME ARGS...), for kernel code.

(defmacro define-primitive (name lambda-list &body body)
  "Defines a primitive with a fixed number of arguments."
  (let ((vals (gensym "VALS")))
    `(setf (gethash ',name *primitives*)
           (lambda (,vals)
             (unless (= (length ,vals) ,(length lambda-list))
               (hir-error "~S called with ~D arguments, takes ~D"
                     ',name (length ,vals) ,(length lambda-list)))
             (destructuring-bind ,lambda-list ,vals ,@body)))))

(defmacro define-nary-primitive (name (vals) &body body)
  `(setf (gethash ',name *primitives*) (lambda (,vals) ,@body)))

(defmacro define-primop (name lambda-list &body body)
  (let ((vals (gensym "VALS")))
    `(setf (gethash ,name *primops*)
           (lambda (,vals)
             (unless (= (length ,vals) ,(length lambda-list))
               (hir-error "primop ~S called with ~D arguments, takes ~D"
                     ,name (length ,vals) ,(length lambda-list)))
             (destructuring-bind ,lambda-list ,vals ,@body)))))

;;; Arithmetic. Fixnums are open-coded; other numbers, and fixnum
;;; overflow, take the slow path: a call to the kernel's two-argument
;;; function, which dispatches on the number types.

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
      (* (emit `(:mul-ovf ,r ,ovf (:fixnum-untag ,a) ,b))))
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

(defun emit-check-number (a &optional (checker 'kiln.kernel::check-number))
  "Signals an error unless A is a number (via the slow path)."
  (let ((slow (new-block)) (ok (new-block)))
    (br `(:and ,a 1) slow ok)
    (start-block slow)
    (emit-slow-call checker a)
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
(defun emit-negate (n)
  (let ((r (new-var)) (overflow (new-var :raw))
        (fast (new-block)) (slow (new-block)) (done (new-block)))
    (br `(:and ,n 1) slow fast)
    (start-block fast)
    (emit `(:sub-ovf ,r ,overflow 0 ,n))
    (br overflow slow done)
    (start-block slow)
    (emit `(:set ,r ,(emit-slow-call 'kiln.kernel::negate-number n)))
    (jump done)
    (start-block done)
    r))

(define-nary-primitive - (vals)
  (cond ((null vals) (hir-error "- needs at least one argument"))
        ((null (rest vals)) (emit-negate (first vals)))
        (t (reduce (lambda (a b) (emit-arith '- a b)) vals))))
;;; LOGAND, LOGIOR, LOGXOR: fixnums open-coded (tagged fixnums combine
;;; bitwise as they are); other integers, and errors, by the kernel's
;;; two-argument functions. Fewer than two arguments: the function.
(defun emit-logop (op a b)
  (let ((r (new-var)) (fast (new-block)) (slow (new-block)) (done (new-block)))
    (br `(:and (:or ,a ,b) 1) slow fast)
    (start-block fast)
    (emit `(:set ,r (,op ,a ,b)))
    (jump done)
    (start-block slow)
    (emit `(:set ,r ,(emit-slow-call (ecase op
                                        (:and 'kiln.kernel::two-arg-logand)
                                        (:or 'kiln.kernel::two-arg-logior)
                                        (:xor 'kiln.kernel::two-arg-logxor))
                                      a b)))
    (jump done)
    (start-block done)
    r))

(macrolet ((define-logop (name op)
             `(define-nary-primitive ,name (vals)
                (if (rest vals)
                    (reduce (lambda (a b) (emit-logop ,op a b)) vals)
                    (apply #'emit-slow-call ',name vals)))))
  (define-logop logand :and)
  (define-logop logior :or)
  (define-logop logxor :xor))

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
  (when (null vals) (hir-error "comparison needs at least one argument"))
  (if (null (rest vals))
      (progn (emit-check-number (first vals)
                               (if (eq op :eq) 'kiln.kernel::check-number
                                   'kiln.kernel::check-real)) (t-value))
      (let ((all nil))
        (loop for (a b) on vals
              while b
              do (let ((p (emit-compare-pair op a b)))
                   (setf all (if all `(:and ,all ,p) p))))
        (boolean-value all))))

(macrolet ((compare (name op)
             `(define-nary-primitive ,name (vals) (emit-compare ,op vals))))
  (compare < :lt) (compare > :gt) (compare <= :le) (compare >= :ge) (compare = :eq))

(define-nary-primitive /= (vals)
  (when (null vals) (hir-error "/= needs at least one argument"))
  (if (null (rest vals))
      (progn (emit-check-number (first vals)) (t-value))
      (let ((all nil))
        (loop for (a . rest) on vals
              do (dolist (b rest)
                   (let ((p `(:eq ,(emit-compare-pair :eq a b) 0)))
                     (setf all (if all `(:and ,all ,p) p)))))
        (boolean-value all))))

;;; Objects

(define-primitive eq (a b) (boolean-value `(:eq ,a ,b)))
;;; Only fixnums, symbols and conses exist so far, so EQL is EQ.
(define-primitive eql (a b)
  ;; Identical objects are EQL; otherwise only numbers that are heap
  ;; objects (bignums, ratios, double floats, complexes) can be, which the kernel
  ;; decides.
  (let ((a (copy-to-var a)) (r (copy-to-var (t-value))) (number-p (new-var :raw))
        (no (new-block)) (general (new-block)) (slow (new-block)) (false (new-block))
        (done (new-block)))
    (br `(:eq ,a ,b) done no)
    (start-block no)
    (br `(:test-class ,kiln.kir::+packet-class-general+ ,a) general false)
    (start-block general)
    (emit `(:heap-number-p ,number-p ,a))
    (br number-p slow false)
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
(define-primitive consp (a) (boolean-value `(:test-class ,kiln.kir::+packet-class-cons+ ,a)))
(define-primitive atom (a) (boolean-value `(:eq (:test-class ,kiln.kir::+packet-class-cons+ ,a) 0)))

(define-primitive listp (a)
  (boolean-value `(:or (:test-class ,kiln.kir::+packet-class-cons+ ,a) (:eq ,a ,(nil-value)))))

(defun emit-kind-p (a class)
  "Is A a general object of KIND?"
  (let ((r (new-var)) (general (new-block)) (no (new-block)) (join (new-block)))
    (br `(:test-class ,kiln.kir::+packet-class-general+ ,a) general no)
    (start-block general)
    (emit `(:set ,r (:select (:test-header-class ,class ,a)
                             ,(t-value) ,(nil-value))))
    (jump join)
    (start-block no)
    (emit `(:set ,r ,(nil-value)))
    (jump join)
    (start-block join)
    r))

(define-primitive symbolp (a) (emit-kind-p a kiln.kir::+packet-class-symbol+))
(define-primitive functionp (a) (boolean-value (emit-function-test a)))
;;; Only fixnums exist so far.
(defun emit-integer-test (a)
  "Raw 0/1: is A a fixnum or a bignum?"
  `(:or (:test-class ,kiln.kir::+packet-class-fixnum+ ,a) ,(emit-kind-test a kiln.kir::+packet-class-bignum+)))
(define-primitive integerp (a) (boolean-value (emit-integer-test a)))
(define-primitive numberp (a)
  (boolean-value `(:or ,(emit-integer-test a)
                       (:or (:test-class ,kiln.kir::+packet-class-single-float+ ,a)
                            (:or (:or ,(emit-kind-test a kiln.kir::+packet-class-ratio+)
                                      ,(emit-kind-test a kiln.kir::+packet-class-double+))
                                 ,(emit-kind-test a kiln.kir::+packet-class-complex+))))))
(define-primitive zerop (a) (boolean-value (emit-compare-pair :eq a 0)))
(define-primitive plusp (a) (boolean-value (emit-compare-pair :gt a 0)))
(define-primitive minusp (a) (boolean-value (emit-compare-pair :lt a 0)))

(define-primitive cons (a b) (emit-cons a b))

(defun emit-car-cdr (x field)
  (let ((r (new-var))
        (is-cons (new-block)) (other (new-block)) (is-nil (new-block))
        (bad (new-block)) (join (new-block)))
    (br `(:test-class ,kiln.kir::+packet-class-cons+ ,x) is-cons other)
    (start-block is-cons)
    (emit `(:set ,r (:field-load ,field ,x)))
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

(define-primitive car (x) (emit-car-cdr x kiln.kir::+packet-field-cons-car+))
(define-primitive cdr (x) (emit-car-cdr x kiln.kir::+packet-field-cons-cdr+))

(define-primitive first (x) (emit-car-cdr x kiln.kir::+packet-field-cons-car+))
(define-primitive rest (x) (emit-car-cdr x kiln.kir::+packet-field-cons-cdr+))
(define-primitive cadr (x) (emit-car-cdr (emit-car-cdr x kiln.kir::+packet-field-cons-cdr+) kiln.kir::+packet-field-cons-car+))
(define-primitive second (x) (emit-car-cdr (emit-car-cdr x kiln.kir::+packet-field-cons-cdr+) kiln.kir::+packet-field-cons-car+))
(define-primitive third (x)
  (emit-car-cdr (emit-car-cdr (emit-car-cdr x kiln.kir::+packet-field-cons-cdr+) kiln.kir::+packet-field-cons-cdr+) kiln.kir::+packet-field-cons-car+))
(define-primitive cddr (x) (emit-car-cdr (emit-car-cdr x kiln.kir::+packet-field-cons-cdr+) kiln.kir::+packet-field-cons-cdr+))

(define-primitive endp (x)
  (let ((r (new-var))
        (is-cons (new-block)) (other (new-block)) (is-nil (new-block))
        (bad (new-block)) (join (new-block)))
    (br `(:test-class ,kiln.kir::+packet-class-cons+ ,x) is-cons other)
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
  (let ((ok (new-block)) (bad (new-block)))
    (br `(:ge ,n 0) ok bad)
    (start-block bad)
    (emit-error +err-index+ n)
    (start-block ok))
  (let ((i (copy-to-var n)) (cur (copy-to-var list))
        (head (new-block)) (body (new-block)) (done (new-block)))
    (jump head)
    (start-block head)
    (br `(:gt ,i 0) body done)
    (start-block body)
    (emit `(:set ,cur ,(emit-car-cdr cur kiln.kir::+packet-field-cons-cdr+)))
    (emit `(:set ,i (:sub ,i ,(ash 1 +fixnum-shift+))))
    (jump head)
    (start-block done)
    cur))

(define-primitive nthcdr (n list) (emit-nthcdr n list))
(define-primitive nth (n list) (emit-car-cdr (emit-nthcdr n list) kiln.kir::+packet-field-cons-car+))

(defun emit-check-cons (x)
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:test-class ,kiln.kir::+packet-class-cons+ ,x) ok bad)
    (start-block bad)
    (emit-error +err-not-list+ x)
    (start-block ok)))

;;; No write barrier yet: only non-generational GC plans.
(define-primitive (setf car) (v x) (emit-check-cons x) (emit `(:field-store ,kiln.kir::+packet-field-cons-car+ ,x ,v)) v)
(define-primitive (setf cdr) (v x) (emit-check-cons x) (emit `(:field-store ,kiln.kir::+packet-field-cons-cdr+ ,x ,v)) v)
(define-primitive rplaca (x v) (emit-check-cons x) (emit `(:field-store ,kiln.kir::+packet-field-cons-car+ ,x ,v)) x)
(define-primitive rplacd (x v) (emit-check-cons x) (emit `(:field-store ,kiln.kir::+packet-field-cons-cdr+ ,x ,v)) x)

(defun emit-list (vals tail)
  (let ((r tail))
    (dolist (v (reverse vals) r)
      (setf r (emit-cons v r)))))

(define-nary-primitive list (vals) (emit-list vals (nil-value)))
(define-nary-primitive list* (vals)
  (when (null vals) (hir-error "LIST* needs at least one argument"))
  (emit-list (butlast vals) (car (last vals))))
(define-nary-primitive vector (vals)
  (let ((result (new-var)))
    (emit `(:alloc-vector-elements ,result ,vals ,(rt-alloc) ,(handler)))
    result))

;;; Primitives may return a second value, the number of values;
;;; those that return one value omit it.

(define-nary-primitive values (vals)
  (when (> (length vals) (1+ kiln.kir::+backend-values-max+))
    (fail "VALUES with more than ~D arguments" (1+ kiln.kir::+backend-values-max+)))
  ;; All arguments are evaluated: store the values after the first.
  (loop for v in (rest vals)
        for i from 0
        do (emit `(:transfer-set ,i ,v)))
  (values (if vals (first vals) (nil-value)) (length vals)))

(define-primitive values-list (list)
  (emit-check-proper-list list)
  (emit-list-to-values list))

(define-nary-primitive apply (vals)
  (when (< (length vals) 2) (hir-error "APPLY needs a function and a list"))
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
    (br `(:test-class ,kiln.kir::+packet-class-cons+ ,cur) cons-b other)
    (start-block cons-b)
    (emit `(:set ,cur (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,cur)))
    (jump head)
    (start-block other)
    (br `(:eq ,cur ,(nil-value)) done bad)
    (start-block bad)
    (emit-error +err-not-list+ cur)
    (start-block done)))

(define-nary-primitive funcall (vals)
  (when (null vals) (hir-error "FUNCALL needs a function"))
  (emit-lisp-call (emit-function-designator (first vals)) (rest vals)))

;;; FDEFINITION and (SETF FDEFINITION) are kernel functions (they take
;;; (SETF symbol) names too); DEFUN's (SETF FDEFINITION) of a constant name
;;; stores into the cell directly (LOWER-GLOBAL-CALL).
(define-primop :symbol-function (name)
  (emit-check-symbol name)
  (copy-to-var `(:field-load ,kiln.kir::+packet-field-symbol-function+ ,name)))
(define-primop :set-symbol-function (name function)
  (emit-check-function function)
  (emit-check-symbol name)
  (emit `(:field-store ,kiln.kir::+packet-field-symbol-function+ ,name ,function))
  function)
(define-primop :symbol-setf-function (name)
  (emit-check-symbol name)
  (copy-to-var `(:field-load ,kiln.kir::+packet-field-symbol-setf-function+ ,name)))
(define-primop :set-symbol-setf-function (name function)
  (emit-check-function function)
  (emit-check-symbol name)
  (emit `(:field-store ,kiln.kir::+packet-field-symbol-setf-function+ ,name ,function))
  function)
(define-primop :undefined-function-p (f)
  ;; F is the content of a function cell.
  (let ((entry (copy-to-var `(:field-load ,kiln.kir::+packet-field-function-entry+ ,f) :raw)))
    (boolean-value `(:or (:eq ,entry (:addr ,(undefined-function-entry)))
                         (:eq ,entry (:addr ,(undefined-setf-function-entry)))))))

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
  (boolean-value `(:ne ,(emit-symbol-value name) (:unbound-value))))


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
;;; Primops. Type checks are the kernel's job; primops that
;;; index check their index.

(defun emit-kind-test (x class)
  "Raw 0/1: is X a general object of KIND? Safe for any value."
  (let ((r (new-var :raw)) (general (new-block)) (no (new-block)) (join (new-block)))
    (br `(:test-class ,kiln.kir::+packet-class-general+ ,x) general no)
    (start-block general)
    (emit `(:set ,r (:test-header-class ,class ,x)))
    (jump join)
    (start-block no)
    (emit `(:set ,r 0))
    (jump join)
    (start-block join)
    r))

(defun emit-function-test (x)
  "Raw 0/1: is X a function (a function object or funcallable instance)?"
  (let ((r (new-var :raw)) (general (new-block)) (no (new-block)) (join (new-block)))
    (br `(:test-class ,kiln.kir::+packet-class-general+ ,x) general no)
    (start-block general)
    (emit `(:set ,r (:test-header-class ,kiln.kir::+packet-class-function+ ,x)))
    (jump join)
    (start-block no)
    (emit `(:set ,r 0))
    (jump join)
    (start-block join)
    r))

(defun vector-length (v)
  "Fixnum length of the vector or string V."
  `(:fixnum-tag (:vector-length ,v)))

(defun emit-check-index (v i)
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:or (:and ,i 1) (:or (:lt ,i 0) (:ge ,i ,(vector-length v)))) bad ok)
    (start-block bad)
    (emit-error +err-index+ i)
    (start-block ok)))

(defun emit-check-length (n)
  "N must be a non-negative fixnum that fits the header's length field."
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:invalid-vector-length ,n) bad ok)
    (start-block bad)
    (emit-error +err-index+ n)
    (start-block ok)))

(define-primitive characterp (a)
  (boolean-value `(:test-class ,kiln.kir::+packet-class-character+ ,a)))
(define-primitive simple-vector-p (a)
  (boolean-value (emit-kind-test a kiln.kir::+packet-class-simple-vector+)))
(define-primitive kiln.kernel::fixnump (a)
  (boolean-value `(:test-class ,kiln.kir::+packet-class-fixnum+ ,a)))
(define-primitive kiln.kernel::bignump (a)
  (boolean-value (emit-kind-test a kiln.kir::+packet-class-bignum+)))
(define-primitive kiln.kernel::ratiop (a)
  (boolean-value (emit-kind-test a kiln.kir::+packet-class-ratio+)))
(define-primitive complexp (a)
  (boolean-value (emit-kind-test a kiln.kir::+packet-class-complex+)))
(define-primitive kiln.kernel::single-float-p (a)
  (boolean-value `(:test-class ,kiln.kir::+packet-class-single-float+ ,a)))
(define-primitive kiln.kernel::double-float-p (a)
  (boolean-value (emit-kind-test a kiln.kir::+packet-class-double+)))
(define-primitive floatp (a)
  (boolean-value `(:or (:test-class ,kiln.kir::+packet-class-single-float+ ,a)
                       ,(emit-kind-test a kiln.kir::+packet-class-double+))))
(define-primitive rationalp (a)
  (boolean-value `(:or ,(emit-integer-test a) ,(emit-kind-test a kiln.kir::+packet-class-ratio+))))
(define-primitive realp (a)
  (boolean-value `(:or (:or ,(emit-integer-test a) ,(emit-kind-test a kiln.kir::+packet-class-ratio+))
                       (:or (:test-class ,kiln.kir::+packet-class-single-float+ ,a)
                            ,(emit-kind-test a kiln.kir::+packet-class-double+)))))

(define-primop :fixnump (x) (boolean-value `(:test-class ,kiln.kir::+packet-class-fixnum+ ,x)))
(define-primop :characterp (x)
  (boolean-value `(:test-class ,kiln.kir::+packet-class-character+ ,x)))
(define-primop :stringp (x) (boolean-value (emit-kind-test x kiln.kir::+packet-class-string+)))
(define-primop :simple-vector-p (x) (boolean-value (emit-kind-test x kiln.kir::+packet-class-simple-vector+)))
(define-primop :symbolp (x)
  (boolean-value `(:or (:eq ,x ,(nil-value)) ,(emit-kind-test x kiln.kir::+packet-class-symbol+))))
(define-primop :functionp (x) (boolean-value (emit-function-test x)))

(define-primop :char-code (c)
  (copy-to-var `(:fixnum-tag (:character-untag ,c))))
(define-primop :code-char (n)
  (copy-to-var `(:character-tag (:fixnum-untag ,n))))

(defun emit-check-character (c)
  (let ((ok (new-block)) (bad (new-block)))
    (br `(:test-class ,kiln.kir::+packet-class-character+ ,c) ok bad)
    (start-block bad)
    (emit-error +err-not-character+ c)
    (start-block ok)))

(define-primitive char-code (c)
  (emit-check-character c)
  (copy-to-var `(:fixnum-tag (:character-untag ,c))))

(defun emit-char-compare (op vals)
  (when (null vals) (hir-error "character comparison needs at least one argument"))
  (dolist (c vals) (emit-check-character c))
  (if (null (rest vals))
      (t-value)
      (let ((all nil))
        (loop for (a b) on vals
              while b
              do (let ((p `(,op ,a ,b)))
                   (setf all (if all `(:and ,all ,p) p))))
        (boolean-value all))))

(macrolet ((compare (name op)
             `(define-nary-primitive ,name (vals) (emit-char-compare ,op vals))))
  (compare char= :eq) (compare char< :lt) (compare char> :gt)
  (compare char<= :le) (compare char>= :ge))

(define-nary-primitive char/= (vals)
  (when (null vals) (hir-error "CHAR/= needs at least one argument"))
  (dolist (c vals) (emit-check-character c))
  (if (null (rest vals))
      (t-value)
      (let ((all nil))
        (loop for (a . rest) on vals
              do (dolist (b rest)
                   (let ((p `(:ne ,a ,b)))
                     (setf all (if all `(:and ,all ,p) p)))))
        (boolean-value all))))

(define-primop :length (v) (copy-to-var (vector-length v)))

(define-primop :schar (s i)
  (emit-check-index s i)
  (copy-to-var `(:string-ref ,s (:fixnum-untag ,i))))
(define-primop :set-schar (s i c)
  (emit-check-index s i)
  (emit `(:string-set ,s (:fixnum-untag ,i) ,c))
  c)

(define-primop :make-string (n c)
  (emit-check-length n)
  (let* ((len (copy-to-var `(:fixnum-untag ,n) :raw))
         (code (copy-to-var `(:character-untag ,c) :raw)))
    (emit-vector-object kiln.kir::+packet-class-string+ len code)))

(define-primop :svref (v i)
  (emit-check-index v i)
  (copy-to-var `(:vector-ref ,v (:fixnum-untag ,i))))
(define-primop :svref-unchecked (v i)
  ;; V is known to be a simple vector and I a valid index of it (CLOS's
  ;; dispatch caches, whose indices are masked to their size).
  (copy-to-var `(:vector-ref ,v (:fixnum-untag ,i))))
(define-primop :set-svref (v i x)
  (emit-check-index v i)
  (emit `(:vector-set ,v (:fixnum-untag ,i) ,x))
  x)
(define-primop :set-svref-unchecked (v i x)
  (emit `(:vector-set ,v (:fixnum-untag ,i) ,x))
  x)

;;; SVREF, (SETF SVREF) and LENGTH are open-coded for simple vectors (and
;;; strings, for LENGTH); anything else, and a bad index, takes the slow
;;; path: a call to the kernel's function, which signals the error or
;;; handles the other sequences.
(defun emit-svref-fast-path (v i fast-fn slow-fn &optional known-vector)
  "Calls FAST-FN in a block where V is a simple vector and I a valid index
of it, SLOW-FN otherwise; both return an operand. Returns the result."
  (let ((r (new-var)) (vector (new-block)) (fast (new-block)) (slow (new-block))
        (done (new-block)))
    (if known-vector (jump vector)
        (br (emit-kind-test v kiln.kir::+packet-class-simple-vector+) vector slow))
    (start-block vector)
    (br `(:or (:and ,i 1) (:or (:lt ,i 0) (:ge ,i ,(vector-length v)))) slow fast)
    (start-block fast)
    (emit `(:set ,r ,(funcall fast-fn)))
    (jump done)
    (start-block slow)
    (emit `(:set ,r ,(funcall slow-fn)))
    (jump done)
    (start-block done)
    r))

(define-primitive svref (v i)
  (emit-svref-fast-path v i
                        (lambda () `(:vector-ref ,v (:fixnum-untag ,i)))
                        (lambda () (emit-slow-call 'svref v i))))

(define-primitive (setf svref) (x v i)
  (emit-svref-fast-path v i
                        (lambda () (emit `(:vector-set ,v (:fixnum-untag ,i) ,x)) x)
                        (lambda () (emit-slow-call '(setf svref) x v i))))

(defun emit-schar (s i c slow-name &optional known-string)
  (let ((r (new-var)) (string (new-block)) (fast (new-block)) (slow (new-block))
        (done (new-block))
        (bad-index `(:or (:and ,i 1) (:or (:lt ,i 0) (:ge ,i ,(vector-length s))))))
    (if known-string (jump string)
        (br (emit-kind-test s kiln.kir::+packet-class-string+) string slow))
    (start-block string)
    (br (if c
            `(:or ,bad-index (:eq (:test-class ,kiln.kir::+packet-class-character+ ,c) 0))
            bad-index)
        slow fast)
    (start-block fast)
    (if c
        (progn (emit `(:string-set ,s (:fixnum-untag ,i) ,c))
               (emit `(:set ,r ,c)))
        (emit `(:set ,r (:string-ref ,s (:fixnum-untag ,i)))))
    (jump done)
    (start-block slow)
    (emit `(:set ,r ,(if c
                         (emit-slow-call slow-name c s i)
                         (emit-slow-call slow-name s i))))
    (jump done)
    (start-block done)
    r))

(define-primitive schar (s i) (emit-schar s i nil 'schar))
(define-primitive (setf schar) (c s i) (emit-schar s i c '(setf schar)))
(define-primitive char (s i) (emit-schar s i nil 'char))
(define-primitive (setf char) (c s i) (emit-schar s i c '(setf char)))

;;; AREF and (SETF AREF) with one subscript (lower-global-call renames
;;; them): a simple vector or a string is accessed inline, anything else,
;;; a bad index or a non-character stored into a string through the
;;; kernel's two- and three-argument functions (no &REST list).
(defun emit-aref-1 (v i x)
  "The one-subscript AREF of V at I, or with X true, the store of X there."
  (let ((r (new-var))
        (general (new-block)) (other (new-block)) (vector (new-block)) (string (new-block))
        (fast-vector (new-block)) (fast-string (new-block)) (slow (new-block))
        (done (new-block))
        (bad-index `(:or (:and ,i 1) (:or (:lt ,i 0) (:ge ,i ,(vector-length v))))))
    (br `(:test-class ,kiln.kir::+packet-class-general+ ,v) general slow)
    (start-block general)
    (br `(:test-header-class ,kiln.kir::+packet-class-simple-vector+ ,v) vector other)
    (start-block other)
    (br `(:test-header-class ,kiln.kir::+packet-class-string+ ,v) string slow)
    (start-block vector)
    (br bad-index slow fast-vector)
    (start-block fast-vector)
    (if x
        (progn (emit `(:vector-set ,v (:fixnum-untag ,i) ,x))
               (emit `(:set ,r ,x)))
        (emit `(:set ,r (:vector-ref ,v (:fixnum-untag ,i)))))
    (jump done)
    (start-block string)
    (br (if x
            `(:or ,bad-index (:eq (:test-class ,kiln.kir::+packet-class-character+ ,x) 0))
            bad-index)
        slow fast-string)
    (start-block fast-string)
    (if x
        (progn (emit `(:string-set ,v (:fixnum-untag ,i) ,x))
               (emit `(:set ,r ,x)))
        (emit `(:set ,r (:string-ref ,v (:fixnum-untag ,i)))))
    (jump done)
    (start-block slow)
    (emit `(:set ,r ,(if x
                         (emit-slow-call 'kiln.kernel::%set-aref-1-slow x v i)
                         (emit-slow-call 'kiln.kernel::%aref-1-slow v i))))
    (jump done)
    (start-block done)
    r))

(define-primitive kiln.kernel::%aref-1 (v i) (emit-aref-1 v i nil))
(define-primitive kiln.kernel::%set-aref-1 (x v i) (emit-aref-1 v i x))

(define-primitive length (x)
  (let ((r (new-var)) (fast (new-block)) (slow (new-block)) (done (new-block)))
    (br `(:or ,(emit-kind-test x kiln.kir::+packet-class-simple-vector+) ,(emit-kind-test x kiln.kir::+packet-class-string+))
        fast slow)
    (start-block fast)
    (emit `(:set ,r ,(vector-length x)))
    (jump done)
    (start-block slow)
    (emit `(:set ,r ,(emit-slow-call 'length x)))
    (jump done)
    (start-block done)
    r))

(define-primop :make-simple-vector (n x)
  (emit-check-length n)
  (let* ((len (copy-to-var `(:fixnum-untag ,n) :raw))
         (zero (eql x 0))
         (x (if zero 0 (copy-to-var x))))
    (emit-vector-object kiln.kir::+packet-class-simple-vector+ len x)))

(define-nary-primitive kiln.kernel::make-simple-vector (vals)
  (unless (<= 1 (length vals) 2)
    (hir-error "MAKE-SIMPLE-VECTOR takes 1 or 2 arguments"))
  (let ((n (first vals))
        (x (if (rest vals) (second vals) (nil-value))))
    (if (and (integerp n) (zerop (logand n 1))
             (<= 0 (ash n (- +fixnum-shift+)) 15))
        (let* ((len (ash n (- +fixnum-shift+)))
               (x (if (integerp x) x (copy-to-var x))))
          (emit-vector-object kiln.kir::+packet-class-simple-vector+ len x))
        (funcall (gethash :make-simple-vector *primops*) (list n x)))))

(define-primop :symbol-name (s) (copy-to-var `(:field-load ,kiln.kir::+packet-field-symbol-name+ ,s)))
(define-primop :symbol-package (s) (copy-to-var `(:field-load ,kiln.kir::+packet-field-symbol-package+ ,s)))
(define-primop :make-symbol (name)
  ;; An uninterned symbol; both function cells hold an undefined-function
  ;; object for it.
  (let* ((name (copy-to-var name))
         (nil-object (copy-to-var (nil-value)))
         (s (new-var)))
    (emit `(:alloc-symbol ,s ,name ,nil-object ,(rt-alloc) ,(handler)))
    (emit-undefined-function-cells s)
    s))
(defun emit-undefined-function-cells (s &key (function t) (setf-function t))
  "Stores new undefined-function objects for the symbol S into its function
cells (both by default)."
  (dolist (cell (append (and function
                             (list (cons kiln.kir::+packet-field-symbol-function+ (undefined-function-entry))))
                        (and setf-function
                             (list (cons kiln.kir::+packet-field-symbol-setf-function+ (undefined-setf-function-entry))))))
    (let ((f (new-var)))
      (emit `(:alloc-closure ,f ,(cdr cell) 1 ,(rt-alloc) ,(handler)))
      (emit `(:closure-set ,f 0 ,s))
      (emit `(:field-store ,(car cell) ,s ,f)))))
;; NIL and T are defined by the runtime with empty function cells; the
;; kernel fills them in first thing.
(define-primop :init-function-cells (s)
  (emit-undefined-function-cells (copy-to-var s))
  s)
;; FMAKUNBOUND and MAKUNBOUND.
(define-primop :unbind-function (s)
  (let ((s (copy-to-var s)))
    (emit-check-symbol s)
    (emit-undefined-function-cells s :setf-function nil)
    s))
(define-primop :unbind-setf-function (s)
  (let ((s (copy-to-var s)))
    (emit-check-symbol s)
    (emit-undefined-function-cells s :function nil)
    s))
(define-primop :makunbound (s)
  (let ((s (copy-to-var s)))
    (emit-check-symbol s)
    (emit-set-symbol-value s '(:unbound-value))
    s))
(define-primop :symbol-plist (s) (copy-to-var `(:field-load ,kiln.kir::+packet-field-symbol-plist+ ,s)))
(define-primop :set-symbol-plist (s v) (emit `(:field-store ,kiln.kir::+packet-field-symbol-plist+ ,s ,v)) v)
;; The package system sets the home package of a symbol, and
;; makes a new keyword its own (global) value.
(define-primop :set-symbol-package (s p) (emit `(:field-store ,kiln.kir::+packet-field-symbol-package+ ,s ,p)) p)
(define-primop :symbol-global-value (s) (copy-to-var `(:field-load ,kiln.kir::+packet-field-symbol-value+ ,s)))
(define-primop :set-symbol-global-value (s v) (emit `(:field-store ,kiln.kir::+packet-field-symbol-value+ ,s ,v)) v)

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

(define-primop :bignump (x) (boolean-value (emit-kind-test x kiln.kir::+packet-class-bignum+)))

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

;;; Fixnum division for the kernel's fast paths: on tagged fixnums, the
;;; quotient of the tagged values is the untagged quotient, and their
;;; remainder the tagged remainder. The caller checks that the divisor is
;;; not 0 and that the quotient is a fixnum.
(define-primop :fixnum-quotient (a b) (copy-to-var `(:shl (:sdiv ,a ,b) 1)))
(define-primop :fixnum-remainder (a b) (copy-to-var `(:srem ,a ,b)))

;;; Fixnum-only bit operations, for the kernel's fast paths: on tagged
;;; fixnums (n << 1), AND, OR and XOR give the tagged result.
(define-primop :fixnum-logand (a b) (copy-to-var `(:and ,a ,b)))
;;; A sum known to be a fixnum (no overflow check).
(define-primop :fixnum+ (a b) (copy-to-var `(:add ,a ,b)))
(define-primop :fixnum-le (a b) (boolean-value `(:le ,a ,b)))
(define-primop :fixnum-logior (a b) (copy-to-var `(:or ,a ,b)))
(define-primop :fixnum-logxor (a b) (copy-to-var `(:xor ,a ,b)))
(define-primop :type-error-integer (x) (emit-error +err-not-integer+ x) (nil-value))
;;; Shifts of a tagged fixnum N by a fixnum count C in 0..62, for ASH's
;;; fast path. Shifting left can overflow: the kernel shifts back to check.
(define-primop :fixnum-shift-left (n c)
  (copy-to-var `(:shlv ,n (:sar ,c 1))))
(define-primop :fixnum-shift-right (n c)
  (copy-to-var `(:and (:sarv ,n (:sar ,c 1)) -2)))

(define-primop :ratiop (x) (boolean-value (emit-kind-test x kiln.kir::+packet-class-ratio+)))
(define-primop :double-float-p (x) (boolean-value (emit-kind-test x kiln.kir::+packet-class-double+)))
;;; Complex numbers (the kernel's COMPLEX makes them canonical).
(define-primop :complexp (x) (boolean-value (emit-kind-test x kiln.kir::+packet-class-complex+)))
(define-primop :make-complex (r i)
  (let ((r (copy-to-var r)) (i (copy-to-var i)))
    (emit-fixed-object kiln.kir::+packet-class-complex+ (list r i))))
(define-primop :realpart (x) (copy-to-var `(:field-load ,kiln.kir::+packet-field-complex-real+ ,x)))
(define-primop :imagpart (x) (copy-to-var `(:field-load ,kiln.kir::+packet-field-complex-imag+ ,x)))
;;; The bits of a float, as unsigned fixnums (lower.lisp writes float
;;; constants with them when it runs on kiln).
(define-primop :single-float-bits (x) (copy-to-var `(:fixnum-tag (:single-float-bits ,x))))
(define-primop :make-double-float-bits (high low)
  (let* ((bits (copy-to-var `(:or (:shl (:fixnum-unsigned-bits ,high) 32)
                                (:fixnum-unsigned-bits ,low)) :raw)))
    (emit-fixed-object kiln.kir::+packet-class-double+ (list bits))))
(define-primop :double-float-high-bits (x)
  (copy-to-var `(:fixnum-tag (:shr (:field-load ,kiln.kir::+packet-field-double-bits+ ,x) 32))))
(define-primop :double-float-low-bits (x)
  (copy-to-var `(:fixnum-tag (:and (:field-load ,kiln.kir::+packet-field-double-bits+ ,x) #xffffffff))))
(define-primop :single-float-p (x)
  (boolean-value `(:test-class ,kiln.kir::+packet-class-single-float+ ,x)))
(define-primop :type-error-number (x) (emit-error +err-not-number+ x) (nil-value))

(defun rt-number-op () (module-import-func "kiln_rt_number_op" 4 1 :unwinds))

(defun emit-number-op (code a b)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-number-op) (,r) (:ctx ,code ,a ,b) ,(handler)))
    r))

;;; Operation codes: rust/kiln-rt/src/number.rs.
(macrolet ((define-number-ops (&rest specs)
             `(progn
                ,@(mapcar (lambda (spec)
                            (destructuring-bind (name code &optional kind) spec
                              (ecase kind
                                ((nil) `(define-primop ,name (a b) (emit-number-op ,code a b)))
                                (:unary `(define-primop ,name (a) (emit-number-op ,code a 0)))
                                ;; The remainder is in ctx.values[0].
                                (:two-values `(define-primop ,name (a b)
                                                (values (emit-number-op ,code a b) 2))))))
                          specs))))
  (define-number-ops
    (:number-add 0) (:number-sub 1) (:number-mul 2) (:number-div 3)
    (:number-truncate 4 :two-values) (:number-floor 5 :two-values)
    (:number-ceiling 6 :two-values) (:number-round 7 :two-values)
    (:number-compare 8) (:number-eql 9)
    (:to-single-float 10 :unary) (:to-double-float 11 :unary)
    (:numerator 12 :unary) (:denominator 13 :unary)
    (:sqrt 14 :unary) (:exp 15 :unary) (:log 16 :unary)
    (:sin 17 :unary) (:cos 18 :unary) (:tan 19 :unary) (:atan 20 :unary)
    (:rational 21 :unary) (:atan2 22) (:number-expt 23)))
(define-primop :type-error-type (x) (emit-error +err-bad-type+ x) (nil-value))
(define-primop :lisp-error (x) (emit-fatal-error +err-lisp-error+ x) (nil-value))
(define-primop :fatal-error (code x)
  ;; CODE is a fixnum.
  (emit-fatal-error `(:fixnum-untag ,code) x)
  (nil-value))

;;; CLOS objects. A rack is [header, class, stamp, slot list,
;;; slots...]; STANDARD-INSTANCE-ACCESS location L is rack word L + 4, so
;;; -2 is the stamp and -1 the slot list (Clostrophilia's convention).

(defun funcallable-trampoline ()
  "Shared entry of funcallable instances: tail-calls the installed function
with the same arguments, so that it leaves no frame of its own. No
safepoint before the call, so arguments in the transfer area are passed on
intact."
  (let ((name "kiln_funcallable_trampoline"))
    (unless (or (shared-entry name) (gethash name (kiln.kir::kmodule-defined *module*)))
      (setf (gethash name (kiln.kir::kmodule-defined *module*)) t)
      (module-shared name)
      (let ((*regions* '()))
        (with-function (name)
          (let ((f (copy-to-var `(:funcallable-function :self))))
            (emit `(:tail-call-lisp (:field-load ,kiln.kir::+packet-field-function-entry+ ,f) (:ctx ,f :nargs :a0 :a1 :a2)))))))
    name))

(defun emit-tail-call (fobj vals)
  "Tail-calls FOBJ with the argument operands VALS: its values are the
current function's. Nothing after it in the block is reached."
  (when (> (length vals) (+ kiln.kir::+backend-reg-args+ kiln.kir::+backend-values-max+))
    (fail "calls with more than ~D arguments are not supported"
          (+ kiln.kir::+backend-reg-args+ kiln.kir::+backend-values-max+)))
  (let ((entry (copy-to-var `(:field-load ,kiln.kir::+packet-field-function-entry+ ,fobj) :raw)))
    (loop for v in (nthcdr kiln.kir::+backend-reg-args+ vals)
          for i from 0
          do (emit `(:transfer-set ,i ,v)))
    (emit `(:tail-call-lisp ,entry
                            (:ctx ,fobj ,(length vals)
                                  ,@(subseq vals 0 (min (length vals) kiln.kir::+backend-reg-args+)))))
    (nil-value)))

;;; (%PRIMOP :TAIL-FUNCALL F ARG...): calls the function F, leaving no
;;; frame of the caller. For the dispatch code of CLOS only: it must be in
;;; tail position, in a function with no special binding, CATCH or
;;; UNWIND-PROTECT active, since the caller's frame is gone when F runs.
(setf (gethash :tail-funcall *primops*)
      (lambda (vals)
        (when (null vals) (hir-error "primop :TAIL-FUNCALL needs a function"))
        (let ((f (copy-to-var (first vals))))
          (emit-check-function f)
          (emit-tail-call f (mapcar (lambda (v) (copy-to-var v)) (rest vals))))))

;;; (%PRIMOP :TAIL-FUNCALL-FUNCTION F ARG...): the same, F known to be a
;;; function object (a dispatch cache's entry, a method's fast function).
(setf (gethash :tail-funcall-function *primops*)
      (lambda (vals)
        (when (null vals) (hir-error "primop :TAIL-FUNCALL-FUNCTION needs a function"))
        (emit-tail-call (copy-to-var (first vals))
                        (mapcar (lambda (v) (copy-to-var v)) (rest vals)))))

(defun funcallable-unset ()
  "Function object installed in a new funcallable instance: signals an
error when called."
  (let ((name "kiln_funcallable_unset"))
    (unless (or (shared-entry "kiln_funcallable_unset_fobj")
                (gethash name (kiln.kir::kmodule-defined *module*)))
      (setf (gethash name (kiln.kir::kmodule-defined *module*)) t)
      (module-shared name)
      (let ((*regions* '()))
        (with-function (name)
          (emit-error +err-not-function+ :self)))
      (module-shared (module-data "kiln_funcallable_unset_fobj"
                                  `(:static-function ,name))))
    `(:object-address "kiln_funcallable_unset_fobj" :general)))

(defun emit-allocate-rack (class size)
  "A rack for CLASS with SIZE cells after the class word (stamp, slot list
and slots), zero-filled."
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:invalid-rack-length ,size) bad ok)
    (start-block bad)
    (emit-error +err-index+ size)
    (start-block ok))
  (let* ((n (copy-to-var `(:fixnum-untag ,size) :raw))
         (class (copy-to-var class))
         (result (new-var)))
    (emit `(:alloc-rack ,result ,class ,n ,(rt-alloc) ,(handler)))
    result))

(define-primop :allocate-general-instance (class size)
  (let ((rack (emit-allocate-rack class size)))
    (emit-fixed-object kiln.kir::+packet-class-instance+ (list rack))))

(define-primop :allocate-general-funcallable-instance (class size)
  (let* ((rack (emit-allocate-rack class size))
         (entry (copy-to-var `(:addr ,(funcallable-trampoline)) :raw))
         (unset (copy-to-var (funcallable-unset))))
    (emit-fixed-object kiln.kir::+packet-class-funcallable-instance+ (list entry rack unset))))

(define-primop :unbound-slot-value () '(:unbound-slot-value))

;;; Hashing (Salmagundi). The identity hash survives moving collections
;;; (header bits 40..64, rust/kiln-rt/src/rtfun.rs).
(define-primop :identity-hash (x)
  (let ((r (new-var)) (x (copy-to-var x)))
    (emit `(:identity-hash ,r ,x ,(rt-identity-hash)))
    r))
;;; File descriptor I/O (Cyclosis' POSIX file streams): VECTOR
;;; is a simple vector of octets as fixnums; the result is the count, or -1.
;;; The callers check the arguments.
(define-primop :fd-write (fd vector start end)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-fd-write) (,r) (:ctx ,fd ,vector ,start ,end) :nil))
    r))
(define-primop :fd-read (fd vector start end)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-fd-read) (,r) (:ctx ,fd ,vector ,start ,end) :nil))
    r))
;;; File system calls (pathnames and file streams): OP selects
;;; the call (rtfun.rs, kiln_rt_sys); the result is a fixnum, minus errno
;;; on failure.
(define-primop :sys (op a b c)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-sys) (,r) (:ctx ,op ,a ,b ,c) :nil))
    r))
;;; Writes the text of the KIR form FORM to the file descriptor FD
;;; (kirtext.rs, kiln_rt_write_kir): the bytes written, minus errno, or
;;; -1000 if FORM is not KIR.
(define-primop :write-kir (form fd)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-write-kir) (,r) (:ctx ,form ,fd) :nil))
    r))
;;; Compiles the KIR module in the string TEXT into the running image, its
;;; literal words filled from the simple vector LITERALS; the module's init
;;; function object, not yet called, or NIL if kiln-cg failed
;;; (kiln_rt_jit).
(define-primop :jit (text literals)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-jit) (,r) (:ctx ,text ,literals) :nil))
    r))
;;; Write owned packet bytes directly, avoiding a Lisp octet carrier.
(define-primop :write-packet (program fd)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-write-packet) (,r) (:ctx ,program ,fd) :nil))
    r))
;;; Snapshot compiler records before the result allocation can move objects.
(define-primop :encode-packet (program language)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-encode-packet) (,r) (:ctx ,program ,language) ,(handler)))
    r))
;;; Single-use image program: copy records without a serialized intermediate.
(define-primop :compile-program (program literals target)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-compile-program) (,r) (:ctx ,program ,literals ,target) :nil))
    r))
;;; Indexed backend request; PACKET and LITERALS remain caller roots.
(define-primop :compile-packet (packet literals)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-compile-packet) (,r) (:ctx ,packet ,literals) :nil))
    r))
;;; Writes a heap image (kiln_rt_save_image): PATH is a simple
;;; vector of octets, TOPLEVEL the function an executable started from
;;; the image calls, EXECUTABLE true to write a copy of the executable
;;; with the image appended. 0, or 1 if it failed.
(define-primop :save-image (path toplevel executable)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-save-image) (,r) (:ctx ,path ,toplevel ,executable) :nil))
    r))
;;; Frames (kiln_rt_frame): the frame pointer of the calling
;;; function, an aligned address, so a fixnum; and the inspection of
;;; frames, OP selecting what (debug.rs).
(define-primop :frame-pointer ()
  (copy-to-var '(:fp)))
(define-primop :frame (op a b)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-frame) (,r) (:ctx ,op ,a ,b) :nil))
    r))
;;; The shortest decimal representation of a float: WHICH selects the
;;; significand (0), exponent (1) or sign (2) (rtfun.rs).
(define-primop :float-decimal (x which)
  (let ((r (new-var)))
    (emit `(:call-rt ,(rt-float-decimal) (,r) (:ctx ,x ,which) :nil))
    r))
;;; One FNV-1a step on fixnums H and V, wrapping: (H xor V) * prime. Both
;;; are tagged (even), so the product is too.
(define-primop :hash-mix (h v)
  (copy-to-var `(:mul (:xor ,h ,v) #x100000001b3)))
(define-primop :standard-instance-p (x) (boolean-value (emit-kind-test x kiln.kir::+packet-class-instance+)))
(define-primop :funcallable-instance-p (x)
  (boolean-value (emit-kind-test x kiln.kir::+packet-class-funcallable-instance+)))
(define-primop :instance-rack (obj) (copy-to-var `(:instance-rack ,obj)))
(define-primop :set-instance-rack (obj rack)
  (emit `(:instance-rack-set ,obj ,rack))
  rack)
(define-primop :instance-class (obj)
  (copy-to-var `(:instance-class ,obj)))
(define-primop :standard-instance-access (obj location)
  (copy-to-var `(:instance-slot ,obj (:fixnum-untag ,location))))
(define-primop :set-standard-instance-access (obj location value)
  (emit `(:instance-slot-set ,obj (:fixnum-untag ,location) ,value))
  value)
(define-primop :funcallable-instance-function (fi)
  (copy-to-var `(:funcallable-function ,fi)))
(define-primop :set-funcallable-instance-function (fi f)
  (emit-check-function f)
  (emit `(:funcallable-function-set ,fi ,f))
  f)

;;; Native structures have a layout pointer and contiguous slots. SIZE is
;;; a literal slot count at constructor call sites, enabling bump allocation.
(define-primop :structure-instance-p (x)
  (boolean-value (emit-kind-test x kiln.kir::+packet-class-structure-instance+)))
(define-primop :structure-layout (object)
  (copy-to-var `(:structure-layout ,object)))
(define-primop :structure-slot (object location)
  (copy-to-var `(:structure-slot ,object (:fixnum-untag ,location))))
(define-primop :set-structure-slot (object location value)
  (emit `(:structure-slot-set ,object (:fixnum-untag ,location) ,value))
  value)
(define-primop :allocate-structure (layout size)
  (let* ((layout (copy-to-var layout))
         (n (if (integerp size) (ash size -1) (copy-to-var `(:fixnum-untag ,size) :raw)))
         (result (new-var)))
    (emit `(:alloc-structure ,result ,layout ,n ,(rt-alloc) ,(handler)))
    result))
