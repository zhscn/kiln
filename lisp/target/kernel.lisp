;;;; kiln kernel: the first target code (docs/09-m3-kernel.md §5).
;;;;
;;;; Written with %PRIMOP, compiler primitives (whose calls are inlined) and
;;;; Common-macros. Macro expanders run in the compile-time environment
;;;; (docs/08 §2): portable CL, and no LOOP until Khazern is loaded.
;;;;
;;;; Character case and classification cover Latin-1 only; Unicode tables
;;;; come later.

(in-package #:kiln.kernel)

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
;;; load time the symbol gets the value.
(defmacro defconstant (name value &optional documentation)
  (declare (ignore documentation))
  `(progn
     (eval-when (:compile-toplevel)
       (kiln.sys::%define-constant ',name ,value))
     (setf (symbol-value ',name) ,value)
     ',name))

(defconstant most-positive-fixnum 4611686018427387903)
(defconstant most-negative-fixnum -4611686018427387904)

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
(defun fboundp (name)
  (not (%primop :undefined-function-p (fdefinition name))))
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

(defun truncate (n &optional (d 1)) (check-divisor n d) (%primop :number-truncate n d))
(defun floor (n &optional (d 1)) (check-divisor n d) (%primop :number-floor n d))
(defun ceiling (n &optional (d 1)) (check-divisor n d) (%primop :number-ceiling n d))
(defun round (n &optional (d 1)) (check-divisor n d) (%primop :number-round n d))
(defun mod (n d) (nth-value 1 (floor n d)))
(defun rem (n d) (nth-value 1 (truncate n d)))

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
(defun ash (n count) (%primop :integer-ash n count))
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
(defun graphic-char-p (c)
  (let ((x (char-code c)))
    (or (<= 32 x 126) (>= x 160))))

;;; Sequences: strings, simple vectors and lists

(defun stringp (x) (%primop :stringp x))
(defun simple-string-p (x) (stringp x))
(defun simple-vector-p (x) (%primop :simple-vector-p x))
(defun vectorp (x) (or (stringp x) (simple-vector-p x)))
(defun arrayp (x) (vectorp x))

(defun check-string (s)
  (unless (stringp s) (%primop :type-error-string s))
  s)
(defun check-simple-vector (v)
  (unless (simple-vector-p v) (%primop :type-error-vector v))
  v)

(defun schar (s i) (%primop :schar (check-string s) i))
(defun (setf schar) (c s i) (%primop :set-schar (check-string s) i (check-character c)))
(defun char (s i) (schar s i))
(defun (setf char) (c s i) (setf (schar s i) c))
(defun svref (v i) (%primop :svref (check-simple-vector v) i))
(defun (setf svref) (x v i) (%primop :set-svref (check-simple-vector v) i x))

(defun aref (v i)
  (if (stringp v) (schar v i) (svref v i)))
(defun (setf aref) (x v i)
  (if (stringp v) (setf (schar v i) x) (setf (svref v i) x)))

;;; Until Regalia, every array is a one-dimensional simple vector or string.
(defun check-array (a) (unless (vectorp a) (%primop :type-error-vector a)) a)
(defun array-rank (a) (check-array a) 1)
(defun array-dimensions (a) (list (length (check-array a))))
(defun array-dimension (a axis)
  (unless (eql axis 0) (%primop :type-error-integer axis))
  (length (check-array a)))
(defun array-total-size (a) (length (check-array a)))
(defun row-major-aref (a i) (aref a i))
(defun (setf row-major-aref) (x a i) (setf (aref a i) x))

(defun make-string (n &key (initial-element #\Space))
  (%primop :make-string n (check-character initial-element)))
(defun make-array (n &key initial-element)
  (%primop :make-simple-vector n initial-element))
(defun vector (&rest elements)
  (let ((v (make-array (length elements))) (i 0))
    (dolist (e elements v)
      (setf (svref v i) e)
      (setq i (+ i 1)))))

(defun length (seq)
  (cond ((listp seq)
         (let ((n 0))
           (dolist (x seq n) (setq n (+ n 1)))))
        ((vectorp seq) (%primop :length seq))
        (t (%primop :type-error-sequence seq))))

(defun elt (seq i)
  (if (listp seq) (nth i seq) (aref seq i)))

(defun make-sequence-like (seq n)
  (cond ((stringp seq) (make-string n))
        ((simple-vector-p seq) (make-array n))
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

(defun equal (a b)
  (cond ((eql a b) t)
        ((consp a) (and (consp b) (equal (car a) (car b)) (equal (cdr a) (cdr b))))
        ((stringp a) (and (stringp b) (string= a b)))
        (t nil)))

;;; Strings

(defun string (x)
  (cond ((stringp x) x)
        ((symbolp x) (symbol-name x))
        ((characterp x) (make-string 1 :initial-element x))
        (t (%primop :type-error-string x))))

(defun string= (a b)
  (let ((a (string a)) (b (string b)))
    (and (= (length a) (length b))
         (dotimes (i (length a) t)
           (unless (char= (schar a i) (schar b i)) (return nil))))))

(defun string-equal (a b)
  (let ((a (string a)) (b (string b)))
    (and (= (length a) (length b))
         (dotimes (i (length a) t)
           (unless (char-equal (schar a i) (schar b i)) (return nil))))))

(defun string< (a b)
  ;; The index of the first difference if A < B, else NIL.
  (let* ((a (string a)) (b (string b)) (la (length a)) (lb (length b)))
    (dotimes (i (min la lb) (if (< la lb) la nil))
      (let ((x (schar a i)) (y (schar b i)))
        (cond ((char< x y) (return i))
              ((char> x y) (return nil)))))))

(defun string-upcase (s)
  (let* ((s (string s)) (new (copy-seq s)))
    (dotimes (i (length new) new)
      (setf (schar new i) (char-upcase (schar new i))))))
(defun string-downcase (s)
  (let* ((s (string s)) (new (copy-seq s)))
    (dotimes (i (length new) new)
      (setf (schar new i) (char-downcase (schar new i))))))

(defun concatenate (result-type &rest sequences)
  ;; RESULT-TYPE: STRING, SIMPLE-STRING, LIST, VECTOR or SIMPLE-VECTOR.
  (if (eq result-type 'list)
      (apply #'append (mapcar (lambda (s) (if (listp s) s (coerce-to-list s))) sequences))
      (let* ((n (apply #'+ (mapcar #'length sequences)))
             (new (if (or (eq result-type 'string) (eq result-type 'simple-string))
                      (make-string n)
                      (make-array n)))
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
