;;;; kiln kernel: the first target code (docs/09-m3-kernel.md §5).
;;;;
;;;; Written with %PRIMOP, compiler primitives (whose calls are inlined) and
;;;; Common-macros. Macro expanders run in the compile-time environment
;;;; (docs/08 §2): portable CL, and no LOOP until Khazern is loaded.
;;;;
;;;; Character case and classification cover Latin-1 only; Unicode tables
;;;; come later.

(in-package #:kiln.kernel)

;;; Proclamations at run time: SPECIAL is recorded on the plist, for the
;;; evaluator (the eval module). The others take effect at compile time
;;; only: the compiler on kiln sees them through *PROCLAIM-HOOK*
;;; (lisp/target/compiler/client.lisp). (Defined first: the DECLAIM below
;;; calls it at load time; %PUT is defined before any SPECIAL proclamation
;;; runs.)
(defun proclaim (declaration)
  (declare (special *proclaim-hook*))
  (when (and (consp declaration) (eq (car declaration) 'special))
    (dolist (name (cdr declaration))
      (%put name 'special t)))
  (when (and (boundp '*proclaim-hook*) *proclaim-hook*)
    (funcall *proclaim-hook* declaration))
  nil)


;;; Small functions whose calls are open-coded (docs/08 §8). Some are
;;; defined in types.lisp.
(declaim (inline bignump fixnump single-float-p double-float-p ratiop rationalp floatp realp
                 characterp char-code simple-string-p simple-vector-p native-vector-p
                 acons fourth fifth caar cdar caddr cdddr identity byte byte-size byte-position
                 caaar caadr cadar cdaar cdadr cddar))

;;; NIL's and T's function cells (the runtime defines the symbols).
(%primop :init-function-cells nil)
(%primop :init-function-cells t)

;;; (SETF GET) for the definitions below, which run before GET exists:
;;; only primitives.
(defun %put (symbol indicator value)
  (do ((l (%primop :symbol-plist symbol) (cdr (cdr l))))
      ((null l)
       (%primop :set-symbol-plist symbol
                (cons indicator (cons value (%primop :symbol-plist symbol))))
       value)
    (when (eq (car l) indicator)
      (rplaca (cdr l) value)
      (return value))))

(defvar *proclaim-hook* nil)

;;; The run-time macro environment: macro functions are kept on the
;;; symbol's plist under MACRO-FUNCTION. DEFMACRO calls (SETF
;;; MACRO-FUNCTION) at load time too, so this comes first. (At compile
;;; time the front end's own definitions are used, docs/08 §2.)
(defun (setf macro-function) (function name &optional environment)
  (declare (ignore environment))
  (%put name 'macro-function function))

;;; DEFINE-SETF-EXPANDER (and DEFSETF) at load time: the expander goes on
;;; the plist too, for the run-time GET-SETF-EXPANSION (the eval module).
(defun kiln.sys::%define-setf-expander (name expander)
  (%put name 'setf-expander expander)
  name)

;;; Byte specifiers are conses (size . position).
(defun byte (size position) (cons size position))
(defun byte-size (bytespec) (car bytespec))
(defun byte-position (bytespec) (cdr bytespec))
(defun ldb (bytespec integer)
  (logand (ash integer (- (cdr bytespec))) (- (ash 1 (car bytespec)) 1)))
(defun mask-field (bytespec integer)
  (logand integer (ash (- (ash 1 (car bytespec)) 1) (cdr bytespec))))
(defun dpb (newbyte bytespec integer)
  (let ((mask (ash (- (ash 1 (car bytespec)) 1) (cdr bytespec))))
    (logior (logand integer (lognot mask))
            (logand (ash newbyte (cdr bytespec)) mask))))
(defun ldb-test (bytespec integer) (not (zerop (ldb bytespec integer))))
(define-setf-expander ldb (bytespec place &environment env)
  (multiple-value-bind (temps vals stores store-form access-form)
      (get-setf-expansion place env)
    (let ((byte-temp (gensym "BYTE"))
          (store (gensym "NEW")))
      (values (cons byte-temp temps)
              (cons bytespec vals)
              (list store)
              `(let ((,(first stores) (dpb ,store ,byte-temp ,access-form)))
                 ,store-form
                 ,store)
              `(ldb ,byte-temp ,access-form)))))

;;; DEFCONSTANT: at compile time the name becomes a constant of the
;;; compile-time environment, so that references compile to the value; at
;;; load time the symbol gets the value. The compile-time environment of
;;; the compiler on kiln is the run-time one (docs/11 §8): there
;;; %DEFINE-CONSTANT is this function (the host's compile-time
;;; environment has its own).
(defun kiln.sys::%define-constant (name value)
  (setf (symbol-value name) value)
  (%put name 'constant t)
  name)

(defmacro defconstant (name value &optional documentation)
  (declare (ignore documentation))
  `(progn
     (eval-when (:compile-toplevel)
       (kiln.sys::%define-constant ',name ,value))
     (setf (symbol-value ',name) ,value)
     (%put ',name 'constant t)
     ',name))

(defconstant most-positive-fixnum 4611686018427387903)
(defconstant most-negative-fixnum -4611686018427387904)

;;; Calls pass at most 3 + 64 arguments, and return at most 1 + 64 values
;;; (docs/08 §4, §5.3).
(defconstant call-arguments-limit 1024)
(defconstant lambda-parameters-limit 1024)
(defconstant multiple-values-limit 1022)
(defconstant char-code-limit #x110000)
(defconstant lambda-list-keywords
  '(&optional &rest &key &allow-other-keys &aux &body &whole &environment))

(defconstant most-positive-single-float 3.4028235f38)
(defconstant most-negative-single-float -3.4028235f38)
(defconstant least-positive-single-float 1.4012985f-45)
(defconstant least-negative-single-float -1.4012985f-45)
(defconstant least-positive-normalized-single-float 1.1754944f-38)
(defconstant least-negative-normalized-single-float -1.1754944f-38)
(defconstant single-float-epsilon 5.960465f-8)
(defconstant single-float-negative-epsilon 2.9802326f-8)
(defconstant most-positive-double-float 1.7976931348623157d308)
(defconstant most-negative-double-float -1.7976931348623157d308)
(defconstant least-positive-double-float 4.9406564584124654d-324)
(defconstant least-negative-double-float -4.9406564584124654d-324)
(defconstant least-positive-normalized-double-float 2.2250738585072014d-308)
(defconstant least-negative-normalized-double-float -2.2250738585072014d-308)
(defconstant double-float-epsilon 1.1102230246251568d-16)
(defconstant double-float-negative-epsilon 5.551115123125784d-17)
;;; Short floats are single floats, long floats double floats.
(defconstant most-positive-short-float 3.4028235f38)
(defconstant most-negative-short-float -3.4028235f38)
(defconstant least-positive-short-float 1.4012985f-45)
(defconstant least-negative-short-float -1.4012985f-45)
(defconstant least-positive-normalized-short-float 1.1754944f-38)
(defconstant least-negative-normalized-short-float -1.1754944f-38)
(defconstant short-float-epsilon 5.960465f-8)
(defconstant short-float-negative-epsilon 2.9802326f-8)
(defconstant most-positive-long-float 1.7976931348623157d308)
(defconstant most-negative-long-float -1.7976931348623157d308)
(defconstant least-positive-long-float 4.9406564584124654d-324)
(defconstant least-negative-long-float -4.9406564584124654d-324)
(defconstant least-positive-normalized-long-float 2.2250738585072014d-308)
(defconstant least-negative-normalized-long-float -2.2250738585072014d-308)
(defconstant long-float-epsilon 1.1102230246251568d-16)
(defconstant long-float-negative-epsilon 5.551115123125784d-17)
(defconstant pi 3.141592653589793d0)

;;; Errors detected by compiled code call this with the error code
;;; (lisp/abi.lisp) and the offending object; the condition system
;;; redefines it to signal a condition (lisp/target/clos/conditions.lisp).
(defun %runtime-error (code object)
  (%primop :fatal-error code object))

;;; Primitives as functions. The calls inside are inlined, so each of these
;;; is the out-of-line version of its primitive: what #'CAR and
;;; (APPLY 'CAR ...) call.

(defmacro define-primitive-functions (&rest specs)
  ;; Expanders run in the compile-time environment, which has no LOOP yet.
  `(progn
     ,@(mapcar (lambda (spec)
                 `(defun ,(car spec) ,(cdr spec) (,(car spec) ,@(cdr spec))))
               specs)))

(define-primitive-functions
  (car x) (cdr x) (cons a b) (eq a b) (eql a b) (null x) (not x)
  (consp x) (atom x) (listp x) (symbolp x) (functionp x)
  (integerp x) (numberp x) (zerop n) (plusp n) (minusp n) (1+ n) (1- n)
  (first x) (rest x) (second x) (cadr x) (cddr x) (endp x)
  (rplaca c v) (rplacd c v) (nth n l) (nthcdr n l) (values-list l)
  (symbol-value s) (boundp s) (print x))

(defun (setf car) (v c) (setf (car c) v))
(defun (setf cdr) (v c) (setf (cdr c) v))
(defun (setf first) (v c) (setf (car c) v))
(defun (setf rest) (v c) (setf (cdr c) v))
(defun setf-function-name-p (name)
  (and (consp name) (eq (car name) 'setf) (consp (cdr name)) (symbolp (cadr name))
       (null (cddr name)) (cadr name) (not (eq (cadr name) t))))
(defun fdefinition (name)
  (if (setf-function-name-p name)
      (%primop :symbol-setf-function (cadr name))
      (%primop :symbol-function name)))
(defun (setf fdefinition) (f name)
  (if (setf-function-name-p name)
      (%primop :set-symbol-setf-function (cadr name) f)
      (%primop :set-symbol-function name f)))
;;; (SETF NIL) and (SETF T) have no function (the runtime defines NIL and
;;; T without a setf function cell).
(defun fboundp (name)
  (and (or (symbolp name) (setf-function-name-p name))
       (not (%primop :undefined-function-p (fdefinition name)))))
(defun fmakunbound (name)
  (if (setf-function-name-p name)
      (%primop :unbind-setf-function (cadr name))
      (%primop :unbind-function name))
  name)
(defun symbol-function (name) (%primop :symbol-function name))
(defun (setf symbol-function) (f name) (%primop :set-symbol-function name f))
(defun (setf symbol-value) (v s) (setf (symbol-value s) v))
(defun (setf nth) (v n l) (setf (car (nthcdr n l)) v))
(defun (setf cddr) (v c) (setf (cdr (cdr c)) v))
(defun (setf caddr) (v c) (setf (car (cddr c)) v))
(defun (setf second) (v c) (setf (car (cdr c)) v))
(defun (setf third) (v c) (setf (car (cddr c)) v))

(defun list (&rest elements) elements)
(defun list* (x &rest more)
  (if (null more)
      x
      (cons x (apply #'list* more))))
(defun values (&rest vals) (values-list vals))
(defun funcall (f &rest args) (apply f args))
(defun apply (f arg &rest args)
  (apply f (if (null args) arg (apply #'list* arg args))))

;;; Numbers. Calls to + - * and the comparisons are open-coded for
;;; fixnums; other numbers and fixnum overflow call the TWO-ARG- functions
;;; below, which hand them to the runtime's real arithmetic (docs/09 §8,
;;; §9). Complex numbers are not implemented yet.

(defun rationalp (x) (or (integerp x) (%primop :ratiop x)))
(defun floatp (x) (or (%primop :single-float-p x) (%primop :double-float-p x)))
(defun realp (x) (or (rationalp x) (floatp x)))

(defun check-number (x)
  (unless (realp x) (%primop :type-error-number x))
  x)

;; The arguments are checked here rather than in the runtime, so that the
;; error can be a condition.
(defun check-numbers (a b) (check-number a) (check-number b))
(defun two-arg-+ (a b) (check-numbers a b) (%primop :number-add a b))
(defun two-arg-- (a b) (check-numbers a b) (%primop :number-sub a b))
(defun two-arg-* (a b) (check-numbers a b) (%primop :number-mul a b))
;; The compare result is a fixnum, so the < here takes the fast path.
;; Rationals and floats compare exactly (CLHS 12.1.4.1).
(defun compare (a b) (check-numbers a b) (%primop :number-compare a b))
(defun two-arg-< (a b) (< (compare a b) 0))
(defun two-arg-> (a b) (> (compare a b) 0))
(defun two-arg-<= (a b) (<= (compare a b) 0))
(defun two-arg->= (a b) (>= (compare a b) 0))
(defun two-arg-= (a b) (= (compare a b) 0))
(defun eql-slow (a b)
  ;; Called by EQL for non-identical heap objects: numbers of the same type
  ;; and value (floats by their bits).
  (%primop :number-eql a b))

;;; MEMBER and ASSOC with EQL or EQ as the test and no key: the compiler
;;; calls these instead (lower.lisp, LOWER-GLOBAL-CALL), without parsing
;;; keyword arguments.
(defun %member-eql (item list)
  (do ((l list (cdr l)))
      ((null l) nil)
    (when (eql item (car l)) (return l))))
(defun %member-eq (item list)
  (do ((l list (cdr l)))
      ((null l) nil)
    (when (eq item (car l)) (return l))))
(defun %assoc-eql (item alist)
  (do ((l alist (cdr l)))
      ((null l) nil)
    (let ((pair (car l)))
      (when (and pair (eql item (car pair))) (return pair)))))
(defun %assoc-eq (item alist)
  (do ((l alist (cdr l)))
      ((null l) nil)
    (let ((pair (car l)))
      (when (and pair (eq item (car pair))) (return pair)))))

(defun check-divisor (n d)
  ;; Division by zero is signaled here, so that it can be a condition
  ;; (the runtime would end the program); 17 is the error code.
  (check-numbers n d)
  (when (zerop d)
    (%runtime-error 17 n)))

(defun / (n &rest ds)
  (if (null ds)
      (progn (check-divisor 1 n) (%primop :number-div 1 n))
      (dolist (d ds n)
        (check-divisor n d)
        (setq n (%primop :number-div n d)))))

(defun + (&rest ns)
  (let ((s 0)) (dolist (n ns s) (setq s (+ s n)))))
(defun * (&rest ns)
  (let ((p 1)) (dolist (n ns p) (setq p (* p n)))))
(defun - (n &rest ns)
  (if (null ns)
      (- n)
      (dolist (m ns n) (setq n (- n m)))))

(defmacro define-comparison (name)
  `(defun ,name (a &rest more)
     (dolist (b more t)
       (unless (,name a b) (return nil))
       (setq a b))))
(define-comparison <)
(define-comparison >)
(define-comparison <=)
(define-comparison >=)
(define-comparison =)

(defun /= (a &rest more)
  (loop-over-pairs a more))
(defun loop-over-pairs (a more)
  ;; True if no two of A and MORE are =.
  (if (null more)
      t
      (and (dolist (b more t) (when (= a b) (return nil)))
           (loop-over-pairs (car more) (cdr more)))))

(defun max (n &rest ns) (dolist (m ns n) (when (> m n) (setq n m))))
(defun min (n &rest ns) (dolist (m ns n) (when (< m n) (setq n m))))
(defun abs (n) (if (< n 0) (- n) n))
(defun signum (n) (cond ((> n 0) 1) ((< n 0) -1) (t 0)))

;;; Two fixnums whose quotient is a fixnum: the fast paths of the division
;;; functions (only the most negative fixnum divided by -1 is not).
(defmacro with-fixnum-division ((n d) fast slow)
  `(if (and (%primop :fixnump ,n) (%primop :fixnump ,d)
            (not (eql ,d 0))
            (not (and (eql ,d -1) (eql ,n most-negative-fixnum))))
       ,fast
       ,slow))

(defun truncate (n &optional (d 1))
  (with-fixnum-division (n d)
    (values (%primop :fixnum-quotient n d) (%primop :fixnum-remainder n d))
    (progn (check-divisor n d) (%primop :number-truncate n d))))
(defun floor (n &optional (d 1))
  (with-fixnum-division (n d)
    (let ((q (%primop :fixnum-quotient n d))
          (r (%primop :fixnum-remainder n d)))
      (if (and (not (eql r 0)) (if (< d 0) (> r 0) (< r 0)))
          (values (- q 1) (+ r d))
          (values q r)))
    (progn (check-divisor n d) (%primop :number-floor n d))))
(defun ceiling (n &optional (d 1))
  (with-fixnum-division (n d)
    (let ((q (%primop :fixnum-quotient n d))
          (r (%primop :fixnum-remainder n d)))
      (if (and (not (eql r 0)) (if (< d 0) (< r 0) (> r 0)))
          (values (+ q 1) (- r d))
          (values q r)))
    (progn (check-divisor n d) (%primop :number-ceiling n d))))
(defun round (n &optional (d 1))
  ;; To the nearest integer, an even one when halfway.
  (with-fixnum-division (n d)
    (let* ((q (%primop :fixnum-quotient n d))
           (r (%primop :fixnum-remainder n d))
           (twice (* 2 (abs r)))
           (ad (abs d)))
      (if (or (> twice ad) (and (= twice ad) (oddp q)))
          (if (eq (< r 0) (< d 0))
              (values (+ q 1) (- r d))
              (values (- q 1) (+ r d)))
          (values q r)))
    (progn (check-divisor n d) (%primop :number-round n d))))
(defun mod (n d)
  (with-fixnum-division (n d)
    (let ((r (%primop :fixnum-remainder n d)))
      (if (and (not (eql r 0)) (if (< d 0) (> r 0) (< r 0))) (+ r d) r))
    (nth-value 1 (floor n d))))
(defun rem (n d)
  (with-fixnum-division (n d)
    (%primop :fixnum-remainder n d)
    (nth-value 1 (truncate n d))))

(defmacro define-logop (name fixnum-op integer-op identity)
  `(progn
     (defun ,name (&rest ns)
       (let ((r ,identity))
         (dolist (n ns r) (setq r (,(intern (format nil "TWO-ARG-~A" name)) r n)))))
     (defun ,(intern (format nil "TWO-ARG-~A" name)) (a b)
       (if (and (%primop :fixnump a) (%primop :fixnump b))
           (%primop ,fixnum-op a b)
           (%primop ,integer-op a b)))))
(define-logop logand :fixnum-logand :integer-logand -1)
(define-logop logior :fixnum-logior :integer-logior 0)
(define-logop logxor :fixnum-logxor :integer-logxor 0)
(defun lognot (n) (logxor n -1))
(defun logtest (a b) (not (zerop (logand a b))))
(defun logbitp (index n) (logtest (ash 1 index) n))
(defun ash (n count)
  ;; Fixnums are shifted inline; the runtime's integer operation works on
  ;; bignums.
  (if (and (%primop :fixnump n) (%primop :fixnump count))
      (cond ((< count 0)
             (if (< count -62)
                 (if (< n 0) -1 0)
                 (%primop :fixnum-shift-right n (- count))))
            ((< count 62)
             (let ((r (%primop :fixnum-shift-left n count)))
               (if (eq (%primop :fixnum-shift-right r count) n)
                   r
                   (%primop :integer-ash n count))))
            ((eq n 0) 0)
            (t (%primop :integer-ash n count)))
      (%primop :integer-ash n count)))
(defun integer-length (n) (%primop :integer-length n 0))

(defun evenp (n)
  (if (%primop :fixnump n) (%primop :evenp n) (zerop (logand n 1))))
(defun oddp (n) (not (evenp n)))

(defun gcd (&rest ns)
  (let ((g 0)) (dolist (n ns g) (setq g (%primop :integer-gcd g n)))))
(defun lcm (&rest ns)
  (let ((l 1))
    (dolist (n ns l)
      (setq l (if (or (zerop l) (zerop n))
                  0
                  (truncate (abs (* l n)) (gcd l n)))))))
(defun expt (base power) (%primop :number-expt base power))

(defun float (x &optional prototype)
  (if (and prototype (%primop :double-float-p prototype))
      (%primop :to-double-float x)
      (if (floatp x) x (%primop :to-single-float x))))
(defun coerce-float (x type)
  ;; Until COERCE: TYPE is SINGLE-FLOAT or DOUBLE-FLOAT.
  (if (eq type 'double-float) (%primop :to-double-float x) (%primop :to-single-float x)))
(defun numerator (q) (%primop :numerator q))
(defun denominator (q) (%primop :denominator q))
(defun rational (x) (%primop :rational x))
(defun sqrt (x) (%primop :sqrt x))
(defun exp (x) (%primop :exp x))
(defun log (x &optional base)
  (if base (/ (%primop :log x) (%primop :log base)) (%primop :log x)))
(defun sin (x) (%primop :sin x))
(defun cos (x) (%primop :cos x))
(defun tan (x) (%primop :tan x))
(defun atan (y &optional x)
  (if x (%primop :atan2 y x) (%primop :atan y)))
(defun ffloor (n &optional (d 1))
  (multiple-value-bind (q r) (floor n d) (values (float q (if (floatp n) n 1.0)) r)))
(defun isqrt (n)
  ;; Newton's method on integers.
  (if (< n 2)
      n
      (let ((x n) (y (ash (+ n 1) -1)))
        (do () ((>= y x) x)
          (setq x y y (ash (+ x (truncate n x)) -1))))))

;;; Characters

(defun characterp (x) (%primop :characterp x))

(defun check-character (c)
  (unless (characterp c) (%primop :type-error-character c))
  c)

(defun char-code (c) (%primop :char-code (check-character c)))
(defun char-int (c) (char-code c))
(defun code-char (code)
  (if (and (%primop :fixnump code) (>= code 0) (< code #x110000))
      (%primop :code-char code)
      nil))

(defmacro define-char-comparison (name test)
  `(defun ,name (a &rest more)
     (let ((x (char-code a)))
       (dolist (b more t)
         (let ((y (char-code b)))
           (unless (,test x y) (return nil))
           (setq x y))))))
(define-char-comparison char= =)
(define-char-comparison char< <)
(define-char-comparison char> >)
(define-char-comparison char<= <=)
(define-char-comparison char>= >=)
(defun char/= (a &rest more)
  (apply #'/= (char-code a) (mapcar #'char-code more)))

(defun upper-case-p (c)
  (let ((x (char-code c)))
    (or (<= 65 x 90) (and (<= 192 x 222) (/= x 215)))))
(defun lower-case-p (c)
  (let ((x (char-code c)))
    (or (<= 97 x 122) (and (<= 223 x 255) (/= x 247) (/= x 223) (/= x 255)))))
(defun both-case-p (c) (or (upper-case-p c) (lower-case-p c)))
(defun char-upcase (c)
  (if (lower-case-p c) (code-char (- (char-code c) 32)) c))
(defun char-downcase (c)
  (if (upper-case-p c) (code-char (+ (char-code c) 32)) c))
(defun char-equal (a &rest more)
  (apply #'char= (char-downcase a) (mapcar #'char-downcase more)))
(defmacro define-char-comparison-ignoring-case (name test)
  `(defun ,name (a &rest more)
     (let ((x (char-code (char-downcase a))))
       (dolist (b more t)
         (let ((y (char-code (char-downcase b))))
           (unless (,test x y) (return nil))
           (setq x y))))))
(define-char-comparison-ignoring-case char-lessp <)
(define-char-comparison-ignoring-case char-greaterp >)
(define-char-comparison-ignoring-case char-not-greaterp <=)
(define-char-comparison-ignoring-case char-not-lessp >=)
(defun char-not-equal (a &rest more)
  (apply #'/= (char-code (char-downcase a))
         (mapcar (lambda (c) (char-code (char-downcase c))) more)))
(defun alpha-char-p (c)
  (or (both-case-p c) (= (char-code c) 223) (= (char-code c) 255)))
(defun digit-char-p (c &optional (radix 10))
  (let* ((x (char-code c))
         (d (cond ((<= 48 x 57) (- x 48))
                  ((<= 65 x 90) (- x 55))
                  ((<= 97 x 122) (- x 87))
                  (t nil))))
    (if (and d (< d radix)) d nil)))
(defun digit-char (weight &optional (radix 10))
  (cond ((or (< weight 0) (>= weight radix)) nil)
        ((< weight 10) (code-char (+ weight 48)))
        (t (code-char (+ weight 55)))))
(defun alphanumericp (c) (or (alpha-char-p c) (digit-char-p c)))
;;; Character names (CHAR-NAME, NAME-CHAR): the semi-standard ones.
(defparameter *character-names*
  '((0 . "Nul") (7 . "Bell") (8 . "Backspace") (9 . "Tab") (10 . "Newline")
    (12 . "Page") (13 . "Return") (27 . "Escape") (32 . "Space") (127 . "Rubout")))

(defun char-name (c)
  (cdr (assoc (char-code c) *character-names*)))

(defun name-char (name)
  (let ((name (string name)))
    (cond ((string-equal name "Linefeed") (code-char 10))
          (t (let ((entry (rassoc name *character-names* :test #'string-equal)))
               (and entry (code-char (car entry))))))))

(defun standard-char-p (c)
  (let ((x (char-code c)))
    (or (= x 10) (<= 32 x 126))))

(defun graphic-char-p (c)
  (let ((x (char-code c)))
    (or (<= 32 x 126) (>= x 160))))

;;; Sequences: strings, simple vectors and lists

;;; Simple vectors and strings are native objects. The other arrays are
;;; standard instances (Regalia, docs/10 §14): once the array layer is
;;; loaded, *COMPLEX-ARRAY-KIND* maps such an object to :STRING, :VECTOR
;;; (another vector) or :ARRAY (not a vector), and other objects to NIL;
;;; *COMPLEX-ARRAY-OP* performs an operation (a symbol) on it.
(defvar *complex-array-kind* nil)
(defvar *complex-array-op* nil)

(defun complex-array-kind (x)
  (if *complex-array-kind* (funcall *complex-array-kind* x) nil))

(defun complex-array-op (op array &rest args)
  (apply *complex-array-op* op array args))

(defun simple-string-p (x) (%primop :stringp x))
(defun simple-vector-p (x) (%primop :simple-vector-p x))
(defun native-vector-p (x) (or (%primop :stringp x) (%primop :simple-vector-p x)))
(defun stringp (x) (or (%primop :stringp x) (eq (complex-array-kind x) :string)))
(defun vectorp (x)
  (or (native-vector-p x)
      (let ((kind (complex-array-kind x))) (or (eq kind :string) (eq kind :vector)))))
(defun arrayp (x) (or (native-vector-p x) (if (complex-array-kind x) t nil)))
(defun simple-array-p (x)
  (or (native-vector-p x)
      (and (complex-array-kind x) (complex-array-op :simple-array-p x))))

(defun check-string (s)
  (unless (%primop :stringp s) (%primop :type-error-string s))
  s)
(defun check-simple-vector (v)
  (unless (simple-vector-p v) (%primop :type-error-vector v))
  v)

(defun schar (s i) (%primop :schar (check-string s) i))
(defun (setf schar) (c s i) (%primop :set-schar (check-string s) i (check-character c)))
(defun char (s i)
  (if (%primop :stringp s) (schar s i) (complex-aref (check-complex-string s) i)))
(defun (setf char) (c s i)
  (if (%primop :stringp s)
      (setf (schar s i) c)
      (setf (complex-aref (check-complex-string s) i) c)))
(defun check-complex-string (s)
  (unless (eq (complex-array-kind s) :string) (%primop :type-error-string s))
  s)
(defun svref (v i) (%primop :svref (check-simple-vector v) i))
(defun (setf svref) (x v i) (%primop :set-svref (check-simple-vector v) i x))

;;; Arrays: the native ones here, the others through *COMPLEX-ARRAY-OP*.
(defun check-array (a)
  (unless (arrayp a) (%primop :type-error-vector a))
  a)
(defun complex-aref (a &rest subscripts)
  (apply #'complex-array-op :aref (check-array a) subscripts))
(defun (setf complex-aref) (x a &rest subscripts)
  (apply #'complex-array-op :set-aref (check-array a) x subscripts))

(defun aref (a &rest subscripts)
  (cond ((%primop :stringp a)
         (unless (and subscripts (null (cdr subscripts))) (%primop :type-error-integer subscripts))
         (schar a (car subscripts)))
        ((%primop :simple-vector-p a)
         (unless (and subscripts (null (cdr subscripts))) (%primop :type-error-integer subscripts))
         (svref a (car subscripts)))
        (t (apply #'complex-aref a subscripts))))
(defun (setf aref) (x a &rest subscripts)
  (cond ((%primop :stringp a)
         (unless (and subscripts (null (cdr subscripts))) (%primop :type-error-integer subscripts))
         (setf (schar a (car subscripts)) x))
        ((%primop :simple-vector-p a)
         (unless (and subscripts (null (cdr subscripts))) (%primop :type-error-integer subscripts))
         (setf (svref a (car subscripts)) x))
        (t (apply #'(setf complex-aref) x a subscripts))))

(defun array-rank (a)
  (if (native-vector-p a) 1 (complex-array-op :array-rank (check-array a))))
(defun array-dimensions (a)
  (if (native-vector-p a)
      (list (%primop :length a))
      (complex-array-op :array-dimensions (check-array a))))
(defun array-dimension (a axis)
  (if (native-vector-p a)
      (progn (unless (eql axis 0) (%primop :type-error-integer axis))
             (%primop :length a))
      (nth axis (array-dimensions a))))
(defun array-total-size (a)
  (if (native-vector-p a)
      (%primop :length a)
      (complex-array-op :array-total-size (check-array a))))
(defun array-element-type (a)
  (cond ((%primop :stringp a) 'character)
        ((%primop :simple-vector-p a) t)
        (t (complex-array-op :array-element-type (check-array a)))))
(defun row-major-aref (a i)
  (if (native-vector-p a) (aref a i) (complex-array-op :row-major-aref (check-array a) i)))
(defun (setf row-major-aref) (x a i)
  (if (native-vector-p a)
      (setf (aref a i) x)
      (complex-array-op :set-row-major-aref (check-array a) x i)))

(defun make-string (n &key (initial-element #\Space))
  (%primop :make-string n (check-character initial-element)))
;;; The kernel makes its vectors with MAKE-SIMPLE-VECTOR: MAKE-ARRAY is
;;; redefined by the array layer (docs/10 §14).
(defun make-simple-vector (n &optional initial-element)
  (%primop :make-simple-vector n initial-element))
(defun make-array (n &key initial-element)
  (%primop :make-simple-vector n initial-element))
(defun vector (&rest elements)
  (let ((v (make-simple-vector (length elements))) (i 0))
    (dolist (e elements v)
      (setf (svref v i) e)
      (setq i (+ i 1)))))

(defun length (seq)
  (cond ((listp seq)
         (let ((n 0))
           (dolist (x seq n) (setq n (+ n 1)))))
        ((native-vector-p seq) (%primop :length seq))
        ((vectorp seq) (complex-array-op :length seq))
        (t (%primop :type-error-sequence seq))))

(defun elt (seq i)
  (if (listp seq) (nth i seq) (aref seq i)))
(defun (setf elt) (value seq i)
  (if (listp seq)
      (setf (car (nthcdr i seq)) value)
      (setf (aref seq i) value)))

(defun make-sequence (type n &key (initial-element nil initial-element-p))
  (let ((head (if (consp type) (car type) type)))
    (cond ((member head '(list cons null))
           (make-list n :initial-element initial-element))
          ((member head '(string simple-string base-string simple-base-string))
           (make-string n :initial-element (if initial-element-p initial-element #\Space)))
          ((member head '(bit-vector simple-bit-vector))
           (make-array n :element-type 'bit :initial-element (if initial-element-p initial-element 0)))
          ((and (member head '(vector simple-array array))
                (consp type) (cdr type) (not (eq (cadr type) '*)) (not (eq (cadr type) t)))
           ;; A specialized vector: the array layer's MAKE-ARRAY.
           (if initial-element-p
               (make-array n :element-type (cadr type) :initial-element initial-element)
               (make-array n :element-type (cadr type))))
          ((member head '(vector simple-vector simple-array array sequence))
           (make-simple-vector n initial-element))
          (t (%primop :type-error-type type)))))

(defun make-sequence-like (seq n)
  (cond ((stringp seq) (make-string n))
        ((vectorp seq) (make-simple-vector n))
        (t (%primop :type-error-sequence seq))))

(defun subseq (seq start &optional end)
  (if (listp seq)
      (let ((l (nthcdr start seq)) (result nil))
        (if end
            (dotimes (i (- end start)) (push (car l) result) (setq l (cdr l)))
            (dolist (x l) (push x result)))
        (nreverse result))
      (let* ((end (or end (length seq)))
             (new (make-sequence-like seq (- end start))))
        (dotimes (i (- end start) new)
          (setf (aref new i) (aref seq (+ start i)))))))

(defun copy-seq (seq) (subseq seq 0))

(defun reverse (seq)
  (if (listp seq)
      (let ((result nil))
        (dolist (x seq result) (push x result)))
      (let* ((n (length seq)) (new (make-sequence-like seq n)))
        (dotimes (i n new)
          (setf (aref new i) (aref seq (- n i 1)))))))

(defun nreverse (seq)
  (if (listp seq)
      (let ((prev nil))
        (loop-nreverse seq prev))
      (let ((n (length seq)))
        (dotimes (i (ash n -1) seq)
          (let ((x (aref seq i)))
            (setf (aref seq i) (aref seq (- n i 1)))
            (setf (aref seq (- n i 1)) x))))))
(defun loop-nreverse (l prev)
  (if (null l)
      prev
      (let ((next (cdr l)))
        (setf (cdr l) prev)
        (loop-nreverse next l))))

;;; Lists

(defun copy-list (l)
  (if (consp l) (cons (car l) (copy-list (cdr l))) l))
(defun last (l) (if (consp (cdr l)) (last (cdr l)) l))
(defun append (&rest lists)
  (cond ((null lists) nil)
        ((null (cdr lists)) (car lists))
        (t (let ((rest (apply #'append (cdr lists))))
             (append-2 (car lists) rest)))))
(defun append-2 (a b)
  (if (null a) b (cons (car a) (append-2 (cdr a) b))))
(defun nconc (&rest lists)
  (cond ((null lists) nil)
        ((null (car lists)) (apply #'nconc (cdr lists)))
        (t (setf (cdr (last (car lists))) (apply #'nconc (cdr lists)))
           (car lists))))
;; MEMBER, ASSOC and friends with keyword arguments: sequences.lisp.
(defun mapcar (f list &rest lists)
  (if (null lists)
      (let ((result nil))
        (dolist (x list (nreverse result)) (push (funcall f x) result)))
      (let ((lists (cons list lists)) (result nil))
        (loop-mapcar f lists result))))
(defun loop-mapcar (f lists result)
  (if (dolist (l lists nil) (when (null l) (return t)))
      (nreverse result)
      (loop-mapcar f (mapcar #'cdr lists)
                   (cons (apply f (mapcar #'car lists)) result))))

;;; EQUAL and EQUALP of two standard instances: pathnames compare by
;;; components (lisp/target/clos/pathnames.lisp sets this).
(defvar *instance-equal* nil)

(defun equal (a b)
  (cond ((eql a b) t)
        ((consp a) (and (consp b) (equal (car a) (car b)) (equal (cdr a) (cdr b))))
        ((stringp a) (and (stringp b) (%string= (string a) (string b))))
        ((and *instance-equal* (%primop :standard-instance-p a))
         (funcall *instance-equal* a b))
        (t nil)))

;;; Strings

(defun string (x)
  ;; A string that is not simple (Regalia) is copied into a simple one:
  ;; the string functions use SCHAR.
  (cond ((%primop :stringp x) x)
        ((stringp x)
         (let* ((n (length x)) (s (make-string n)))
           (dotimes (i n s) (setf (schar s i) (char x i)))))
        ((symbolp x) (symbol-name x))
        ((characterp x) (make-string 1 :initial-element x))
        (t (%primop :type-error-string x))))

;;; String comparison (CLHS string=, string<): the strings' designators,
;;; their bounds :START1 :END1 :START2 :END2.

(defun %string-bounds (s start end)
  (let ((n (%primop :length s)))
    (unless end (setq end n))
    (unless (and (%primop :fixnump start) (%primop :fixnump end) (<= 0 start end n))
      (error 'type-error :datum (list start end) :expected-type `(integer 0 ,n)))
    end))

(defun %string-mismatch (a b start1 end1 start2 end2 fold)
  "The indices in A and B of the first characters that differ (by CHAR=,
or by CHAR-EQUAL if FOLD), or of the end of either string."
  (let ((i start1) (j start2))
    (loop
      (when (or (= i end1) (= j end2)) (return))
      (let ((x (%primop :schar a i)) (y (%primop :schar b j)))
        (unless (or (eq x y) (and fold (eq (char-downcase x) (char-downcase y))))
          (return)))
      (setq i (+ i 1) j (+ j 1)))
    (values i j)))

(defun %string= (a b)
  ;; Simple strings (STRING returns them): their characters are compared
  ;; as immediates, without calls (EQUAL on strings, hash tables of names).
  (let ((n (%primop :length a)))
    (and (= n (%primop :length b))
         (dotimes (i n t)
           (unless (eq (%primop :schar a i) (%primop :schar b i)) (return nil))))))

(defun %string-compare (a b start1 end1 start2 end2 fold)
  "The index in A of the first difference, and how A compares with B
there: -1, 0 or 1."
  (let* ((a (string a)) (b (string b))
         (end1 (%string-bounds a start1 end1))
         (end2 (%string-bounds b start2 end2)))
    (multiple-value-bind (i j) (%string-mismatch a b start1 end1 start2 end2 fold)
      (values i
              (cond ((= i end1) (if (= j end2) 0 -1))
                    ((= j end2) 1)
                    (t (let ((x (char-code (%primop :schar a i)))
                             (y (char-code (%primop :schar b j))))
                         (when fold
                           (setq x (char-code (char-downcase (%primop :schar a i)))
                                 y (char-code (char-downcase (%primop :schar b j)))))
                         (if (< x y) -1 1))))))))

(defun string= (a b &key (start1 0) end1 (start2 0) end2)
  (if (and (eql start1 0) (null end1) (eql start2 0) (null end2))
      (%string= (string a) (string b))
      (multiple-value-bind (i order) (%string-compare a b start1 end1 start2 end2 nil)
        (declare (ignore i))
        (= order 0))))

(defun string-equal (a b &key (start1 0) end1 (start2 0) end2)
  (multiple-value-bind (i order) (%string-compare a b start1 end1 start2 end2 t)
    (declare (ignore i))
    (= order 0)))

(defmacro define-string-comparison (name fold orders)
  `(defun ,name (a b &key (start1 0) end1 (start2 0) end2)
     (multiple-value-bind (i order) (%string-compare a b start1 end1 start2 end2 ,fold)
       (if (member order ',orders) i nil))))
(define-string-comparison string/= nil (-1 1))
(define-string-comparison string< nil (-1))
(define-string-comparison string> nil (1))
(define-string-comparison string<= nil (-1 0))
(define-string-comparison string>= nil (0 1))
(define-string-comparison string-not-equal t (-1 1))
(define-string-comparison string-lessp t (-1))
(define-string-comparison string-greaterp t (1))
(define-string-comparison string-not-greaterp t (-1 0))
(define-string-comparison string-not-lessp t (0 1))

;;; Case conversion: the N versions change STRING in place (CHAR, so that
;;; strings that are not simple work too).
(defun nstring-upcase (string &key (start 0) end)
  (do ((i start (+ i 1)) (end (or end (length string))))
      ((>= i end) string)
    (setf (char string i) (char-upcase (char string i)))))
(defun nstring-downcase (string &key (start 0) end)
  (do ((i start (+ i 1)) (end (or end (length string))))
      ((>= i end) string)
    (setf (char string i) (char-downcase (char string i)))))
(defun string-upcase (s &key (start 0) end)
  (nstring-upcase (copy-seq (string s)) :start start :end end))
(defun string-downcase (s &key (start 0) end)
  (nstring-downcase (copy-seq (string s)) :start start :end end))

(defun concatenate (result-type &rest sequences)
  ;; RESULT-TYPE: STRING, SIMPLE-STRING, LIST, VECTOR or SIMPLE-VECTOR.
  (if (eq result-type 'list)
      (apply #'append (mapcar (lambda (s) (if (listp s) s (coerce-to-list s))) sequences))
      (let* ((n (apply #'+ (mapcar #'length sequences)))
             (new (if (or (eq result-type 'string) (eq result-type 'simple-string))
                      (make-string n)
                      (make-simple-vector n)))
             (i 0))
        (dolist (s sequences new)
          (dotimes (k (length s))
            (setf (aref new i) (elt s k))
            (setq i (+ i 1)))))))

(defun coerce-to-list (seq)
  (if (listp seq) seq (vector-to-list seq)))
(defun vector-to-list (seq)
  (let ((result nil))
    (dotimes (i (length seq) (nreverse result))
      (push (aref seq i) result))))

;;; Symbols

(defun make-symbol (name)
  (%primop :make-symbol (check-string name)))

(defvar *gensym-counter* 0)

(defun integer-to-decimal-string (n)
  (if (< n 10)
      (string (digit-char n))
      (concatenate 'string (integer-to-decimal-string (floor n 10))
                   (string (digit-char (mod n 10))))))

(defun gensym (&optional (x "G"))
  (if (integerp x)
      (make-symbol (concatenate 'string "G" (integer-to-decimal-string x)))
      (prog1 (make-symbol (concatenate 'string x (integer-to-decimal-string *gensym-counter*)))
        (setq *gensym-counter* (+ *gensym-counter* 1)))))

(defun symbol-name (s)
  (unless (symbolp s) (%primop :type-error-symbol s))
  (%primop :symbol-name s))
(defun symbol-package (s)
  (unless (symbolp s) (%primop :type-error-symbol s))
  (%primop :symbol-package s))
(defun symbol-plist (s)
  (unless (symbolp s) (%primop :type-error-symbol s))
  (%primop :symbol-plist s))
(defun (setf symbol-plist) (v s)
  (unless (symbolp s) (%primop :type-error-symbol s))
  (%primop :set-symbol-plist s v))
;;; Each module's init pushes its symbol table here before anything else
;;; (lower.lisp); the package system registers the symbols (docs/10 §12).
;;; No initial value: the kernel's own table is pushed before this runs.
(defvar *module-symbol-tables*)

;;; The KEYWORD package, once the package system exists. (No docstring:
;;; (SETF DOCUMENTATION) is defined in early.lisp.)
(defvar *keyword-package* nil)

(defun keywordp (x)
  ;; Before the package system has replaced it with the package, a
  ;; symbol's package is its package name.
  (and (symbolp x) x (not (eq x t))
       (let ((p (symbol-package x)))
         (if (stringp p)
             (string= p "KEYWORD")
             (and p (eq p *keyword-package*))))))

(defun getf (plist indicator &optional default)
  (do ((l plist (cddr l)))
      ((null l) default)
    (when (eq (car l) indicator) (return (cadr l)))))
(defun put-plist-value (plist indicator value)
  ;; PLIST with INDICATOR's value set to VALUE (destructively if present).
  (do ((l plist (cddr l)))
      ((null l) (list* indicator value plist))
    (when (eq (car l) indicator)
      (setf (cadr l) value)
      (return plist))))
(define-setf-expander getf (place indicator &optional default &environment env)
  (multiple-value-bind (temps vals stores store-form access-form)
      (get-setf-expansion place env)
    (let ((indicator-temp (gensym "INDICATOR"))
          (default-temp (gensym "DEFAULT"))
          (store (gensym "NEW")))
      (values (append temps (list indicator-temp default-temp))
              (append vals (list indicator default))
              (list store)
              `(let ((,(first stores) (put-plist-value ,access-form ,indicator-temp ,store)))
                 ,store-form
                 ,store)
              `(getf ,access-form ,indicator-temp ,default-temp)))))
;;; (SETF (VALUES place...) form)
(define-setf-expander values (&rest places &environment env)
  (let ((temps '()) (vals '()) (stores '()) (store-forms '()) (access-forms '()))
    (dolist (place places)
      (multiple-value-bind (ts vs ss store-form access-form)
          (get-setf-expansion place env)
        (setq temps (append temps ts)
              vals (append vals vs)
              stores (append stores (list (car ss)))
              store-forms (append store-forms (list store-form))
              access-forms (append access-forms (list access-form)))))
    (values temps vals stores
            `(values ,@store-forms)
            `(values ,@access-forms))))

(defun get-properties (plist indicator-list)
  (do ((l plist (cddr l)))
      ((null l) (values nil nil nil))
    (when (member (car l) indicator-list)
      (return (values (car l) (cadr l) l)))))
(defun get (symbol indicator &optional default)
  (do ((l (symbol-plist symbol) (cddr l)))
      ((null l) default)
    (when (eq (car l) indicator) (return (cadr l)))))
(defun (setf get) (value symbol indicator &optional default)
  (declare (ignore default))
  (do ((l (symbol-plist symbol) (cddr l)))
      ((null l)
       (setf (symbol-plist symbol) (list* indicator value (symbol-plist symbol)))
       value)
    (when (eq (car l) indicator)
      (setf (cadr l) value)
      (return value))))
(defun (setf cadr) (v l) (setf (car (cdr l)) v))

;;; Constants are keywords, NIL, T, the names of DEFCONSTANT, quoted forms
;;; and self-evaluating objects.
(defun constantp (form &optional environment)
  (declare (ignore environment))
  (cond ((symbolp form)
         (or (null form) (eq form t) (keywordp form) (get form 'constant)))
        ((consp form) (eq (car form) 'quote))
        (t t)))

;;; Run-time macro expansion (no symbol macros yet).
(defvar *macroexpand-hook* 'funcall)
;;; A lexical environment is one of the evaluator's (the eval module sets
;;; this to a function of the name and the environment).
(defvar *environment-macro-function* nil)
(defun macro-function (symbol &optional environment)
  (if (and environment *environment-macro-function*)
      (funcall *environment-macro-function* symbol environment)
      (get symbol 'macro-function)))
(defun macroexpand-1 (form &optional environment)
  (let ((expander (and (consp form) (symbolp (car form))
                       (macro-function (car form) environment))))
    (if expander
        (values (funcall *macroexpand-hook* expander form environment) t)
        (values form nil))))
(defun macroexpand (form &optional environment)
  (let ((expanded nil))
    (do () (nil)
     (multiple-value-bind (expansion expandedp) (macroexpand-1 form environment)
       (unless expandedp
         (return-from macroexpand (values form expanded)))
       (setf form expansion expanded t)))))

(defun special-operator-p (symbol)
  (and (member symbol '(block catch eval-when flet function go if labels let let*
                        load-time-value locally macrolet multiple-value-call
                        multiple-value-prog1 progn progv quote return-from setq
                        symbol-macrolet tagbody the throw unwind-protect))
       t))

;;; No function keeps its source (CLHS allows NIL).
(defun function-lambda-expression (function)
  (declare (ignore function))
  (values nil t nil))
;;; The other CxR functions and their SETF functions.
(defun (setf caar) (v x) (setf (car (car x)) v))
(defun (setf cdar) (v x) (setf (cdr (car x)) v))
(defun caaar (x) (car (caar x)))
(defun (setf caaar) (v x) (setf (car (caar x)) v))
(defun caadr (x) (car (cadr x)))
(defun (setf caadr) (v x) (setf (car (cadr x)) v))
(defun cadar (x) (car (cdar x)))
(defun (setf cadar) (v x) (setf (car (cdar x)) v))
(defun cdaar (x) (cdr (caar x)))
(defun (setf cdaar) (v x) (setf (cdr (caar x)) v))
(defun cdadr (x) (cdr (cadr x)))
(defun (setf cdadr) (v x) (setf (cdr (cadr x)) v))
(defun cddar (x) (cdr (cdar x)))
(defun (setf cddar) (v x) (setf (cdr (cdar x)) v))
(defun (setf cdddr) (v x) (setf (cdr (cddr x)) v))
(defun caaaar (x) (car (caaar x)))
(defun (setf caaaar) (v x) (setf (car (caaar x)) v))
(defun caaadr (x) (car (caadr x)))
(defun (setf caaadr) (v x) (setf (car (caadr x)) v))
(defun caadar (x) (car (cadar x)))
(defun (setf caadar) (v x) (setf (car (cadar x)) v))
(defun caaddr (x) (car (caddr x)))
(defun (setf caaddr) (v x) (setf (car (caddr x)) v))
(defun cadaar (x) (car (cdaar x)))
(defun (setf cadaar) (v x) (setf (car (cdaar x)) v))
(defun cadadr (x) (car (cdadr x)))
(defun (setf cadadr) (v x) (setf (car (cdadr x)) v))
(defun caddar (x) (car (cddar x)))
(defun (setf caddar) (v x) (setf (car (cddar x)) v))
(defun cadddr (x) (car (cdddr x)))
(defun (setf cadddr) (v x) (setf (car (cdddr x)) v))
(defun cdaaar (x) (cdr (caaar x)))
(defun (setf cdaaar) (v x) (setf (cdr (caaar x)) v))
(defun cdaadr (x) (cdr (caadr x)))
(defun (setf cdaadr) (v x) (setf (cdr (caadr x)) v))
(defun cdadar (x) (cdr (cadar x)))
(defun (setf cdadar) (v x) (setf (cdr (cadar x)) v))
(defun cdaddr (x) (cdr (caddr x)))
(defun (setf cdaddr) (v x) (setf (cdr (caddr x)) v))
(defun cddaar (x) (cdr (cdaar x)))
(defun (setf cddaar) (v x) (setf (cdr (cdaar x)) v))
(defun cddadr (x) (cdr (cdadr x)))
(defun (setf cddadr) (v x) (setf (cdr (cdadr x)) v))
(defun cdddar (x) (cdr (cddar x)))
(defun (setf cdddar) (v x) (setf (cdr (cddar x)) v))
(defun cddddr (x) (cdr (cdddr x)))
(defun (setf cddddr) (v x) (setf (cdr (cdddr x)) v))
