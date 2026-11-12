(in-package #:kiln.compiler)

;;;; Lowering to KIR: the module, functions, calls, special variables,
;;;; non-local exits, allocation and constants. lisp/hir/lower.lisp walks
;;;; the HIR of each top-level form and emits its nodes with these; the
;;;; top-level forms of a file run in order from the module's init
;;;; function.

(define-condition kiln-compile-error (error)
  ((message :initarg :message :reader kiln-compile-error-message))
  (:report (lambda (c s) (write-string (kiln-compile-error-message c) s))))

(define-condition kiln-program-error (kiln-compile-error program-error) ())

(defun fail (control &rest args)
  (error 'kiln-compile-error :message (apply #'format nil control args)))

;;; Names in the object file

(defun mangle-char-p (c)
  (let ((code (char-code c)))
    (or (<= 48 code 57) (<= 65 code 90) (<= 97 code 122))))

(defun mangle (string)
  "STRING with every character but an ASCII letter or digit written as
_HEX_. Most names need no change and are returned as they are."
  (if (every #'mangle-char-p string)
      string
      (with-output-to-string (out)
        (loop for c across string
              do (if (mangle-char-p c)
                     (write-char c out)
                     (progn (write-char #\_ out)
                            (write-string (hex-string (char-code c)) out)
                            (write-char #\_ out)))))))

(defun hex-string (n)
  "N, a non-negative integer, in upper-case hexadecimal."
  (if (zerop n)
      "0"
      (let ((digits '()))
        (loop until (zerop n)
              do (push (char "0123456789ABCDEF" (logand n 15)) digits)
                 (setf n (ash n -4)))
        (coerce digits 'string))))

(defvar *uninterned-symbols* nil
  "Uninterned symbol -> (INDEX . NAME) in the module (COMPILE-MODULE).")
(defvar *uninterned-count*)

(defun uninterned-entry (sym)
  "An uninterned symbol is the module's own, numbered by the order in
which the module first names it, as SBCL's fasl dumper keeps them by
identity: its label has that number, not its name, so two of the same name
stay two symbols. A name ending in digits (a gensym's) gets that number
instead: the host's own gensyms (SBCL's PCL makes some while compiling)
shift the counter, so the numbers differ between hosts."
  (or (gethash sym *uninterned-symbols*)
      (setf (gethash sym *uninterned-symbols*)
            (let* ((index (incf *uninterned-count*))
                   (name (symbol-name sym))
                   (end (position-if-not #'digit-char-p name :from-end t)))
              (cons index
                    (if (and (plusp (length name))
                             (digit-char-p (char name (1- (length name)))))
                        (kiln.kir::kir-name (subseq name 0 (if end (1+ end) 0)) index)
                        name))))))

(defun module-symbol-name (sym)
  "The name of SYM in the module."
  (if (or (symbol-package sym) (null *uninterned-symbols*))
      (symbol-name sym)
      (cdr (uninterned-entry sym))))

(defun symbol-label (sym)
  (mangle (cond ((symbol-package sym)
                 (kiln.kir::kir-name (target-package-name (symbol-package sym)) ":" (symbol-name sym)))
                (*uninterned-symbols*
                 (let ((entry (uninterned-entry sym)))
                   (kiln.kir::kir-name "#" (kiln.kir::kmodule-name *module*) ":"
                                      (car entry) ":" (cdr entry))))
                (t (kiln.kir::kir-name "#:" (symbol-name sym))))))

(defvar *counter*)

;;; Primitives (primitives.lisp)
(defvar *primitives* (make-hash-table :test 'equal)
  "Function name -> function of the list of argument operands.")

(defvar *primops* (make-hash-table :test 'eq)
  "Keyword -> function of the list of argument operands (primitives.lisp).")

(defvar *regions* '())                  ; dynamic-extent regions (REGION below)

(defvar *module-label*)                 ; mangled module name

(defun fresh-label (prefix)
  "A name local to the current module. Modules are combined by kiln-cg,
so local names carry the module's name; shared ones (symbols) do not."
  (kiln.kir::kir-name prefix *module-label* "_" (incf *counter*)))

;;; Runtime functions

(defun rt-print () (module-import-func "kiln_rt_print" 2 1))
(defun rt-error () (module-import-func "kiln_rt_error" 3 0 :unwinds :noreturn))
(defun rt-poll () (module-import-func "kiln_rt_poll" 2 1 :unwinds))
(defun rt-throw () (module-import-func "kiln_rt_throw" 4 0 :unwinds))
(defun rt-exit-to () (module-import-func "kiln_rt_exit_to" 4 0 :unwinds))
(defun rt-continue-unwind ()
  (module-import-func "kiln_rt_continue_unwind" 2 0 :unwinds :noreturn))
(defun rt-alloc () (module-import-func "kiln_rt_alloc" 3 1 :unwinds))
(defun rt-gc () (module-import-func "kiln_rt_gc" 1 1 :unwinds))
(defun rt-gc-count () (module-import-func "kiln_rt_gc_count" 1 1))
(defun rt-call-on-new-stack ()
  (module-import-func "kiln_rt_call_on_new_stack" 3 1 :unwinds))

;;; Constants and static data
;;;
;;; Operands are KIR expressions; data words are KIR data words. A constant
;;; is built as a data word, then turned into an operand.
;;;
;;; Code compiled into the running image (COMPILE) refers to
;;; the image's objects: a literal that is not an immediate is a word of
;;; the module's literal words ("kiln_literals", static roots), which the
;;; loader fills in from a vector (kiln_rt_jit), and its data word is
;;; (:LITERAL index). The shared functions are the image's (imported).

(defvar *image-literals* nil
  "When compiling into the running image: a hash table from literal objects
to their indices in the literal words; else NIL.")

(defvar *image-literal-objects*)        ; the literals, newest first

(defparameter +literals-label+ "kiln_literals")

(defun literal-word (x)
  `(:literal ,(or (gethash x *image-literals*)
                  (progn (push x *image-literal-objects*)
                         (setf (gethash x *image-literals*)
                               (1- (length *image-literal-objects*)))))))

(defun word-operand (word)
  (cond ((integerp word) word)
        ((eq (first word) :literal)
         `(:load (:addr ,+literals-label+) ,(* 8 (second word))))
        (t `(:addr ,@(rest word)))))

(defun emit-literal-words ()
  "Defines the literal words of a module compiled into the running image;
returns the literals, a vector."
  (let ((n (length *image-literal-objects*)))
    (module-data +literals-label+ `(:words ,@(make-list (max n 1) :initial-element 0)))
    (dotimes (i n)
      (module-root +literals-label+ i))
    (coerce (nreverse *image-literal-objects*) 'simple-vector)))

(defun shared-entry (name)
  "When compiling into the running image, imports the shared definition
NAME, and returns NAME; else NIL (the caller defines it)."
  (when *image-literals*
    (module-import-data name)))

(defun nil-word () `(:data ,(module-import-data "kiln_nil") ,+tag-general+))
(defun t-word () `(:data ,(module-import-data "kiln_t") ,+tag-general+))
(defun nil-value () (word-operand (nil-word)))
(defun t-value () (word-operand (t-word)))
(defun boolean-value (condition)
  (copy-to-var `(:select ,condition ,(t-value) ,(nil-value))))

(defun undefined-function-entry ()
  "A function that signals an undefined-function error for the symbol in
its first env word. Every function cell starts out holding one."
  (let ((name "kiln_undefined_function"))
    (unless (or (shared-entry name) (gethash name (kiln.kir::kmodule-defined *module*)))
      (setf (gethash name (kiln.kir::kmodule-defined *module*)) t)
      (module-shared name)
      (let ((*regions* '()))
        (with-function (name)
          (emit-error +err-undefined-function+ `(:closure-ref :self 0)))))
    name))

(defun undefined-setf-function-entry ()
  "As UNDEFINED-FUNCTION-ENTRY, for the function (SETF symbol)."
  (let ((name "kiln_undefined_setf_function"))
    (unless (or (shared-entry name) (gethash name (kiln.kir::kmodule-defined *module*)))
      (setf (gethash name (kiln.kir::kmodule-defined *module*)) t)
      (module-shared name)
      (let ((*regions* '()))
        (with-function (name)
          (emit-error +err-undefined-setf-function+ `(:closure-ref :self 0)))))
    name))

(defun function-cell-place (name)
  "The address operand and offset of the global function cell of NAME."
  (multiple-value-bind (symbol index)
      (cond ((symbolp name) (values name 3))
            ((and (consp name) (eq (first name) 'setf) (symbolp (second name))
                  (second name) (not (eq (second name) t)))
             ;; (SETF symbol): the symbol's setf function word.
             (values (second name) 7))
            (t (fail "invalid function name ~S" name)))
    (if *image-literals*
        (values (constant-object symbol) (- (* 8 index) +tag-general+))
        (values `(:addr ,(symbol-data symbol)) (* 8 index)))))

(defun string-words (string)
  "Data words of a string object: header, then UTF-32 code points packed
two per word (little-endian), padded."
  (let ((codes (map 'list #'char-code string)))
    (cons (logior +kind-string+ (ash (length codes) +length-shift+))
          (loop for (a b) on codes by #'cddr
                collect (logior a (ash (or b 0) 32))))))

(defun string-data (label string)
  "Defines LABEL as a static string object holding STRING (once)."
  (module-data label `(:words ,@(string-words string)))
  label)

(defun package-name-word (package)
  "Until package objects exist (M3.3), a symbol's package slot holds the
name of its package as a string."
  (if package
      (let ((name (target-package-name package)))
        `(:data ,(module-shared (string-data (format nil "kiln_pkg_~A" (mangle name)) name))
                ,+tag-general+))
      (nil-word)))

(defvar *module-symbols*)               ; symbols with static data, newest first

(defvar *symbol-data-names*)            ; symbol -> SYMBOL-DATA's name, per module

(defun symbol-data (sym)
  "Name of the static data object of the symbol SYM (not NIL or T)."
  (or (gethash sym *symbol-data-names*)
      (setf (gethash sym *symbol-data-names*) (make-symbol-data sym))))

(defun make-symbol-data (sym)
  (let* ((label (symbol-label sym))
         (obj (kiln.kir::kir-name "kiln_sym_" label)))
    (unless (gethash obj (kiln.kir::kmodule-defined *module*))
      (let ((name (string-data (kiln.kir::kir-name "kiln_name_" label) (module-symbol-name sym)))
            (undef (kiln.kir::kir-name "kiln_undef_" label))
            (undef-setf (kiln.kir::kir-name "kiln_undef_setf_" label)))
        (module-data undef `(:words ,(logior +kind-function+ (ash 1 +length-shift+))
                                    (:func ,(undefined-function-entry))
                                    (:data ,obj ,+tag-general+)))
        (module-data undef-setf `(:words ,(logior +kind-function+ (ash 1 +length-shift+))
                                         (:func ,(undefined-setf-function-entry))
                                         (:data ,obj ,+tag-general+)))
        ;; [header, name, package, function, value, TLS index, plist,
        ;; setf function]
        (module-data obj `(:words ,+kind-symbol+
                                  (:data ,name ,+tag-general+)
                                  ,(package-name-word (symbol-package sym))
                                  (:data ,undef ,+tag-general+)
                                  ,(if (keywordp sym) `(:data ,obj ,+tag-general+) +unbound+)
                                  0
                                  ,(nil-word)
                                  (:data ,undef-setf ,+tag-general+)))
        (module-shared name)
        (module-shared undef)
        (module-shared undef-setf)
        (module-shared obj)
        (push sym *module-symbols*)
        ;; The package slot holds the package object once packages exist.
        ;; The TLS index (a fixnum) is not a GC root, but it changes as
        ;; the other words do: a heap image saves the static roots.
        (module-root obj 2)
        (module-root obj 3)
        (module-root obj 4)
        (module-root obj 5)
        (module-root obj 6)
        (module-root obj 7)))
    obj))

(defun symbol-word (sym)
  (cond ((null sym) (nil-word))
        ((eq sym t) (t-word))
        (*image-literals* (literal-word sym))
        (t `(:data ,(symbol-data sym) ,+tag-general+))))

(defconstant +most-positive-fixnum+ (1- (ash 1 62)))
(defconstant +most-negative-fixnum+ (- (ash 1 62)))

;;; The bits of floats, unsigned: in the host (SBCL) and on kiln (the
;;; compiler module).
(defun single-float-bits (x)
  #+sbcl (ldb (byte 32 0) (sb-kernel:single-float-bits x))
  #+kiln (kiln.sys:%primop :single-float-bits x))

(defun double-float-high-bits (x)
  #+sbcl (ldb (byte 32 0) (sb-kernel:double-float-high-bits x))
  #+kiln (kiln.sys:%primop :double-float-high-bits x))

(defun double-float-low-bits (x)
  #+sbcl (sb-kernel:double-float-low-bits x)
  #+kiln (kiln.sys:%primop :double-float-low-bits x))

(defvar *constants*)                    ; host object -> data word
(defvar *string-constants*)             ; static string contents -> data word
(defvar *cons-words*)                   ; (car word, cdr word) -> data word of a cons
(defvar *pending-conses*)               ; conses being emitted -> their word if a cycle needs it

(defun constant-word (x)
  (when (and *image-literals*
             (not (or (typep x '(or character single-float symbol))
                      (and (integerp x) (<= +most-negative-fixnum+ x +most-positive-fixnum+)))))
    (return-from constant-word (literal-word x)))
  (typecase x
    (integer
     (if (<= +most-negative-fixnum+ x +most-positive-fixnum+)
         (ash x +fixnum-shift+)
         (or (gethash x *constants*)
             (let ((label (fresh-label "kiln_bignum_"))
                   (n (ceiling (1+ (integer-length x)) 64)))
               ;; Two's complement digits, minimal length.
               (module-data label `(:words ,(logior +kind-bignum+ (ash n +length-shift+))
                                           ,@(loop for i below n
                                                   collect (let ((d (ldb (byte 64 (* 64 i)) x)))
                                                             (if (logbitp 63 d) (- d (ash 1 64)) d)))))
               (setf (gethash x *constants*) `(:data ,label ,+tag-general+))))))
    (symbol (symbol-word x))
    (single-float
     (signed-word (logior (ash (single-float-bits x) 32)
                          +single-float-tag+)))
    (double-float
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_double_")))
           (module-data label `(:words ,+kind-double+
                                       ,(signed-word
                                         (logior (ash (double-float-high-bits x) 32)
                                                 (double-float-low-bits x)))))
           (setf (gethash x *constants*) `(:data ,label ,+tag-general+)))))
    (ratio
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_ratio_")))
           (module-data label `(:words ,+kind-ratio+ ,(constant-word (numerator x))
                                       ,(constant-word (denominator x))))
           (setf (gethash x *constants*) `(:data ,label ,+tag-general+)))))
    (complex
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_complex_")))
           (module-data label `(:words ,+kind-complex+ ,(constant-word (realpart x))
                                       ,(constant-word (imagpart x))))
           (setf (gethash x *constants*) `(:data ,label ,+tag-general+)))))
    (character
     (logior (ash (char-code x) +character-shift+) +character-tag+))
    (string
     (or (gethash x *constants*)
         (setf (gethash x *constants*)
               (or (gethash x *string-constants*)
                   (setf (gethash x *string-constants*)
                         `(:data ,(string-data (fresh-label "kiln_string_") x) ,+tag-general+))))))
    (simple-vector
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_vector_")))
           (setf (gethash x *constants*) `(:data ,label ,+tag-general+))
           (module-data label `(:words ,(logior +kind-simple-vector+
                                                (ash (length x) +length-shift+))
                                       ,@(map 'list #'constant-word x)))
           `(:data ,label ,+tag-general+))))
    (cons
     ;; Static conses: the GC neither moves nor scans them, and they only
     ;; point to static data. Conses with the same car and cdr words are
     ;; one (similar constants coalesced, CLHS 3.2.4.4, as SBCL's
     ;; COMPILE-FILE does): the KIR does not depend on which conses the
     ;; host happened to share. The label is made after the
     ;; car and cdr, unless the cons is part of a cycle.
     (or (gethash x *constants*)
         (multiple-value-bind (word pending) (gethash x *pending-conses*)
           (when pending
             (return-from constant-word
               (or word
                   (setf (gethash x *pending-conses*)
                         `(:data ,(fresh-label "kiln_const_") ,+tag-cons+)))))
           (setf (gethash x *pending-conses*) nil)
           (let* ((car-word (constant-word (car x)))
                  (cdr-word (constant-word (cdr x)))
                  (cyclic (gethash x *pending-conses*))
                  (key (list car-word cdr-word)))
             (remhash x *pending-conses*)
             (setf (gethash x *constants*)
                   (or (and (not cyclic) (gethash key *cons-words*))
                       (let ((word (or cyclic `(:data ,(fresh-label "kiln_const_") ,+tag-cons+))))
                         (module-data (second word) `(:words ,+kind-cons+ ,car-word ,cdr-word))
                         (unless cyclic
                           (setf (gethash key *cons-words*) word))
                         word)))))))
    (t (fail "constants of type ~S are not supported yet" (type-of x)))))

(defun signed-word (u)
  "The 64-bit pattern U as a signed integer (KIR words are signed)."
  (if (logbitp 63 u) (- u (ash 1 64)) u))

(defun constant-object (x)
  (word-operand (constant-word x)))

;;; Regions: dynamic-environment entries established by the function being
;;; compiled, innermost first.

(defstruct region
  kind            ; :catch, :unwind-protect, :cleanup-running or :exit-point
  slot            ; stack slot holding the entry
  handler         ; block that dispatches exceptional entry into this frame
  cleanup         ; unwind-protect cleanup ASTs
  outer)          ; regions outside this one

(defun handler ()
  "The handler block for calls here: that of the innermost region that has
one (bindings have none)."
  (let ((r (find-if #'region-handler *regions*)))
    (if r (kiln.kir::kblock-name (region-handler r)) :nil)))

(declaim (inline bname))
(defun bname (b) (kiln.kir::kblock-name b))
(defun jump (b) (emit (list :jump (bname b))))
(defun br (cond then else) (emit (list :br cond (bname then) (bname else))))

(defun copy-to-var (operand &optional (kind :obj))
  (let ((v (new-var kind)))
    (emit (list :set v operand))
    v))

(defun emit-fatal-error (code obj)
  "Reports error CODE about the Lisp value OBJ and ends the program."
  (emit `(:call-rt ,(rt-error) () (:ctx ,code ,obj) ,(handler)))
  (emit '(:trap)))

(defun emit-error (code obj)
  "Signals error CODE about the Lisp value OBJ: by calling the kernel's
%RUNTIME-ERROR with the code (a fixnum) and OBJ, which the condition
system redefines to signal a condition; before the kernel has defined it,
by ending the program."
  (let ((obj (copy-to-var obj))
        (f (function-cell-value 'kiln.kernel::%runtime-error))
        (lisp (new-block))
        (fatal (new-block)))
    (br `(:eq (:field-load ,kiln.kir::+packet-field-function-entry+ ,f) (:addr ,(undefined-function-entry))) fatal lisp)
    (start-block lisp)
    (emit-lisp-call f (list (ash code +fixnum-shift+) obj))
    (jump fatal)
    (start-block fatal)
    (emit-fatal-error code obj)))

(defun emit-poll (&key stack)
  "A poll point. With STACK (function entries), it compares the frame
with the context's stack limit instead of reading the poll flag: a poll
request raises the limit above every stack, so one
comparison covers both. The slow path returns true when the stack is
exhausted, and KILN.KERNEL::%STACK-EXHAUSTED signals the STORAGE-CONDITION."
  (let ((slow (new-block)) (overflow (new-block)) (cont (new-block))
        (exhausted (new-var :raw)))
    (br (if stack
            `(:lt (:fp) (:load :ctx ,+ctx-stack-limit+))
            `(:load :ctx ,+ctx-poll-flag+))
        slow cont)
    (start-block slow)
    (emit `(:call-rt ,(rt-poll) (,exhausted) (:ctx 0) ,(handler)))
    (br exhausted overflow cont)
    (start-block overflow)
    (emit-slow-call 'kiln.kernel::%stack-exhausted)
    (jump cont)
    (start-block cont)))

(defun poll-retry ()
  "The shared function that the entry poll of a function with at most
+REG-ARGS+ positional parameters and no &REST or &KEY tail-calls on its
slow path, with that function as self and its arguments: it calls the poll
slow path, then enters the function again. The function's own hit path
makes no call, so its arguments are not spilled for the safepoint.
Registers beyond the arguments are zeroed, so that the GC never sees
them."
  (let ((name "kiln_poll_retry"))
    (unless (or (shared-entry name) (gethash name (kiln.kir::kmodule-defined *module*)))
      (setf (gethash name (kiln.kir::kmodule-defined *module*)) t)
      (module-shared name)
      (let ((*regions* '()) (*call-source* nil))
        (with-function (name)
          (let ((self (copy-to-var :self))
                (entry (copy-to-var `(:field-load ,kiln.kir::+packet-field-function-entry+ :self) :raw))
                (args (loop for reg in '(:a0 :a1 :a2)
                            for i from 0
                            collect (copy-to-var `(:select (:gt :nargs ,i) ,reg 0))))
                (exhausted (new-var :raw))
                (overflow (new-block)) (cont (new-block)))
            (emit `(:call-rt ,(rt-poll) (,exhausted) (:ctx ,entry) ,(handler)))
            (br exhausted overflow cont)
            (start-block overflow)
            (emit-slow-call 'kiln.kernel::%stack-exhausted)
            (jump cont)
            (start-block cont)
            (emit `(:tail-call-lisp ,entry (:ctx ,self :nargs ,@args)))))))
    name))

(defun emit-entry-poll ()
  "The poll at the entry of a function whose arguments are all in
registers, before it reads them: the slow path re-enters the function
through POLL-RETRY."
  (let ((slow (new-block)) (cont (new-block)))
    (br `(:lt (:fp) (:load :ctx ,+ctx-stack-limit+)) slow cont)
    (start-block slow)
    (emit `(:tail-call-lisp (:addr ,(poll-retry)) (:ctx :self :nargs :a0 :a1 :a2)))
    (start-block cont)))

(defun pop-entry (region)
  (emit `(:store :ctx ,+ctx-dynenv+ (:load (:slot ,(region-slot region)) ,+dyn-prev+))))

(defun emit-local-exit (target-regions)
  "Leaves the regions entered since TARGET-REGIONS, running cleanups."
  (loop for regions on *regions*
        until (eq regions target-regions)
        do (let ((r (first regions)))
             (case (region-kind r)
               (:bind (emit-unbind r))
               (:progv (emit-unbind-progv r)))
             (pop-entry r)
             (when (eq (region-kind r) :unwind-protect)
               (let ((*regions* (region-outer r)))
                 (lower-progn (region-cleanup r)))))))

(defun establish-entry (kind &optional (tag 0))
  "Links a new dynamic-environment entry into the context. Returns its
region; code inside it runs with the region pushed on *REGIONS*."
  (let* ((slot (new-slot +dynentry-size+))
         (region (make-region :kind kind :slot slot
                              :handler (if (member kind '(:bind :progv :stack-roots)) nil (new-block))
                              :outer *regions*)))
    (emit `(:store (:slot ,slot) ,+dyn-kind+ ,(ecase kind
                                                 (:catch +dyn-catch+)
                                                 (:unwind-protect +dyn-unwind-protect+)
                                                 (:exit-point +dyn-exit-point+)
                                                 (:bind +dyn-bind+)
                                                 (:progv +dyn-progv+)
                                                 (:stack-roots +dyn-stack-roots+))))
    (emit `(:store (:slot ,slot) ,+dyn-prev+ (:load :ctx ,+ctx-dynenv+)))
    (emit `(:store (:slot ,slot) ,+dyn-fp+ (:fp)))
    ;; Initialize object fields and range descriptors before linking the entry.
    (emit `(:store (:slot ,slot) ,+dyn-tag+ ,tag))
    (emit `(:store (:slot ,slot) ,+dyn-pend-target+ 0))
    (emit `(:store (:slot ,slot) ,+dyn-pend-value+ 0))
    (emit `(:store :ctx ,+ctx-dynenv+ (:slot ,slot)))
    region))

(defun start-dispatch (region land)
  "Emits the handler block of REGION: payload exn0 names the target entry.
Unwinds to other entries of this frame are dispatched outward."
  (start-block (region-handler region))
  (let ((outer (new-block)))
    ;; Bit 0 of exn0 flags packed multiple values (see EMIT-UNWIND-VALUES).
    (br `(:eq (:and :exn0 -2) (:slot ,(region-slot region))) land outer)
    (start-block outer)
    (let ((h (let ((*regions* (region-outer region))) (handler))))
      (if (eq h :nil)
          (emit '(:trap))
          (emit `(:jump ,h))))))

(defun emit-unwind-values (v n)
  "Operands for passing the values (V, N) through an unwind: the value
word and the packed flag. With more or fewer than one value, the value
word is a list of them and the flag is 1."
  (if (eql n 1)
      (values v 0)
      (values (emit-save-values v n) (copy-to-var `(:ne ,n 1) :raw))))

(defun emit-landed-values ()
  "In a landing block: the values passed by the unwind (exn0, exn1)."
  (let ((v (new-var)) (n (new-var :raw))
        (packed (new-block)) (single (new-block)) (join (new-block)))
    (br `(:and :exn0 1) packed single)
    (start-block single)
    (set-mv v n :exn1 1)
    (jump join)
    (start-block packed)
    (multiple-value-call #'set-mv v n (emit-list-to-values :exn1))
    (jump join)
    (start-block join)
    (values v n)))

;;; Variables. Closure conversion guarantees that a variable is only
;;; referenced in the function that defines it.

(defvar *self*)                         ; variable holding the function object

;;; Debug information. Each function has a debug info object,
;;; #(NAME FILE START END VARIABLES): the name backtraces show, the source
;;; file and range of the function (or of its top-level form), and the
;;; names of its variables, a simple vector whose elements are symbols,
;;; or (:CELL symbol) for a variable that a closure assigns (its value is
;;; in a cell). The KIR variables that hold source variables carry the
;;; index of the name, and calls carry the source range of the call
;;; form: kiln-cg records where the variables are during each call.

(defstruct (toplevel-form (:constructor make-toplevel-form (ast file source definition form)))
  "A top-level form to compile (front.lisp): its HIR, the name
of its file, its source range (START . END), the definition it belongs
to, (NAME . FUNCTION-P) as DEFINITION-NAME returns them, or NIL, and the
outermost form as written (before macro expansion)."
  ast file source definition form (symbols nil))

(defun toplevel-symbols (toplevel)
  "The symbols that occur in TOPLEVEL's form, a hash table."
  (or (toplevel-form-symbols toplevel)
      (setf (toplevel-form-symbols toplevel)
            (let ((table (make-hash-table :test 'eq))
                  (seen nil))
              (labels ((walk (x depth)
                         (cond ((symbolp x) (setf (gethash x table) t))
                               ((or (not (consp x)) (zerop depth)))
                               ((and (< depth 99900)
                                     (let ((s (or seen (setf seen (make-hash-table :test 'eq)))))
                                       (or (gethash x s) (progn (setf (gethash x s) t) nil)))))
                               (t (walk (car x) (1- depth))
                                  (walk (cdr x) (1- depth))))))
                (walk (toplevel-form-form toplevel) 100000))
              table))))

(defvar *toplevel* nil)                 ; the TOPLEVEL-FORM being compiled
(defvar *function-name* nil)            ; name of the function being compiled; NIL at top level
(defvar *debug-vars* '())               ; names of its variables, newest first
(defvar *debug-var-count* 0)
(defvar *call-source* nil)              ; packed source position of the innermost call form

(defun call-loc ()
  "The (LOC START END) part of the call being emitted, as a list."
  (and *call-source* *toplevel* (toplevel-form-file *toplevel*)
       `((:loc ,(ldb (byte 25 25) *call-source*)
               ,(ldb (byte 25 0) *call-source*)))))

(defun note-debug-var (var name cell &optional representation)
  (when (and name (symbolp name) (symbol-package name))
    (push (cond (cell (list :cell name))
                (representation (list representation name))
                (t name))
          *debug-vars*)
    (kiln.kir::label-var var *debug-var-count*)
    (incf *debug-var-count*)))

(defun local-function-debug-name (name)
  "The debug name of a local function named NAME (a LAMBDA's is a gensym)
in the function being compiled."
  (let* ((definition (and *toplevel* (toplevel-form-definition *toplevel*)))
         (parent (or *function-name* (car definition))))
    (cond ((or (and (symbolp name) (symbol-package name))
               (and (consp name) (eq (first name) 'setf)))
           (if parent `(flet ,name :in ,parent) `(flet ,name)))
          ;; The function a DEFUN (DEFMETHOD...) defines.
          ((and (null *function-name*) (cdr definition))
           (car definition))
          (parent `(lambda :in ,parent))
          (t '(lambda)))))

(defun set-function-debug (name source)
  "Gives the function being built its debug info object."
  (let* ((file (and *toplevel* (toplevel-form-file *toplevel*)))
         (source (or source (and *toplevel* (toplevel-form-source *toplevel*))))
         (word (constant-word
                (vector name file (car source) (cdr source)
                        (and *debug-vars* (coerce (nreverse *debug-vars*) 'simple-vector))))))
    (setf (kiln.kir::kfunc-debug *func*)
          (if (and (consp word) (eq (first word) :literal))
              `(:debug-ref ,+literals-label+ ,(* 8 (second word)))
              `(:debug ,word)))))

(defun source-variable-name (definition)
  "The name of the variable DEFINITION for the debug info if it is written
in the source: it occurs in the top-level form. Variables that macros
introduce do not; their names are of no use, and differ between the host
and kiln, where some macro packages have other names."
  (let ((name (and definition (hir-var-name definition))))
    (and name (>= (hir-policy-quality (hir-var-policy definition) :debug) 2)
         (symbolp name) (symbol-package name) *toplevel*
         (gethash name (toplevel-symbols *toplevel*))
         name)))

(defvar *hir-entry-p* nil)

(defun bind-var (definition operand &key (name (source-variable-name definition)) cell)
  "Binds the variable DEFINITION to a new KIR variable holding OPERAND.
NAME is the source variable's name for the debug info, NIL for none; CELL
true if the variable holds the cell of the variable NAME."
  (let ((v (copy-to-var operand)))
    (setf (hir-var-lowering definition) v)
    (unless *hir-entry-p*
      (note-debug-var v name cell))
    v))

;;; Lowering

(defgeneric lower (ast)
  (:documentation "Emits code for AST; returns an operand holding its value."))

(defmethod lower ((ast t))
  (fail "cannot compile ~S yet" (class-name (class-of ast))))

;;; Multiple values. LOWER-MV returns the operand of the
;;; primary value and the number of values: an integer, or a raw variable.
;;; Values after the first are in the context's transfer area (ctx.values)
;;; and must be consumed before the next call. Forms through which values
;;; pass define LOWER-MV, and their LOWER takes the primary value.

(defgeneric lower-mv (ast))

(defmethod lower-mv ((ast t))
  (values (lower ast) 1))

(defun lower-progn-mv (asts)
  (if (null asts)
      (values (nil-value) 1)
      (progn
        (dolist (a (butlast asts))
          (lower a))
        (lower-mv (car (last asts))))))

(defun lower-progn (asts)
  (values (lower-progn-mv asts)))

(defun lower-or-nil-mv (ast)
  (if ast (lower-mv ast) (values (nil-value) 1)))

(defun set-mv (r n v nv)
  "Assigns the values (V, NV) to the variables R and N."
  (emit `(:set ,r ,v))
  (emit `(:set ,n ,nv)))

(defun constant-value (ast)
  "The value of AST if it is a constant (QUOTE, a literal, or a variable
known to hold one), and true; else NIL and NIL."
  (typecase ast
    (hir-node
     (case (hir-node-kind ast)
       (0 (values (hir-node-a ast) t))
       (1 (let ((var (hir-node-a ast)))
            (values (hir-var-constant var)
                    (and (hir-var-constant-p var) (not (logtest 1 (hir-var-flags var)))))))
       (otherwise (values nil nil))))
    (t (values nil nil))))

(defun lower-switch-mv (reference arms default &optional effect)
  (let ((value (lower reference))
        (r (and (not effect) (new-var))) (n (and (not effect) (new-var :raw)))
        (fallback (new-block)) (dispatch (new-block)) (join (new-block))
        (blocks '()))
    (dolist (arm arms)
      (unless (assoc (cdr arm) blocks :test #'eq)
        (push (cons (cdr arm) (new-block)) blocks)))
    (setf blocks (nreverse blocks))
    (br `(:eq (:and ,value 1) 0) dispatch fallback)
    (start-block dispatch)
    (emit `(:switch (:sar ,value ,+fixnum-shift+) ,(kiln.kir::kblock-name fallback)
                    ,(loop for (key . body) in arms
                           collect (list key (kiln.kir::kblock-name
                                              (cdr (assoc body blocks :test #'eq)))))))
    (loop for (body . block) in blocks
          do (start-block block)
             (if effect (funcall effect body)
                 (multiple-value-call #'set-mv r n (lower-mv body)))
             (jump join))
    (start-block fallback)
    (if effect (when default (funcall effect default))
        (multiple-value-call #'set-mv r n (lower-or-nil-mv default)))
    (jump join)
    (start-block join)
    (if effect (values (nil-value) 1) (values r n))))


;;; Tests (the test of an IF, HIR-LOWER-BRANCH): a predicate's (:SELECT
;;; condition T NIL) becomes a branch on the condition. The unused SELECT
;;; is left to kiln-cg's dead code elimination.

(defun boolean-condition (v)
  "The condition C if the last statement of the current block is
(:SET V (:SELECT C T NIL)): the value V was just made from it."
  (let ((stmt (first (kiln.kir::kblock-stmts (kiln.kir::kfunc-current *func*)))))
    (and (kiln.kir::kvar-p v)
         (consp stmt)
         (eq (first stmt) :set)
         (eq (second stmt) v)
         (let ((x (third stmt)))
           (and (consp x)
                (eq (first x) :select)
                (equal (third x) (t-value))
                (equal (fourth x) (nil-value))
                (second x))))))

(defun branch-on-value (v then else)
  (br (or (boolean-condition v) `(:ne ,v ,(nil-value))) then else))


;;; Special variables: TLS-index scheme (C1, rust/kiln-rt/src/special.rs).
;;; Symbols store their TLS index as a fixnum (index << 1), so the address
;;; of the slot is the table plus the stored index shifted left by 2.
;;; A symbol's value in a context is its slot in the context's TLS table if
;;; that holds a value, else its global value. Slot 0 is always empty, so a
;;; symbol that was never bound (index 0) needs no test.

(defun rt-tls-index () (module-import-func "kiln_rt_tls_index" 2 1))
(defun rt-identity-hash () (module-import-func "kiln_rt_identity_hash" 2 1))
(defun rt-fd-write () (module-import-func "kiln_rt_fd_write" 5 1))
(defun rt-fd-read () (module-import-func "kiln_rt_fd_read" 5 1))
(defun rt-float-decimal () (module-import-func "kiln_rt_float_decimal" 3 1))
(defun rt-sys () (module-import-func "kiln_rt_sys" 5 1))
(defun rt-write-kir () (module-import-func "kiln_rt_write_kir" 3 1))
(defun rt-jit () (module-import-func "kiln_rt_jit" 3 1))
(defun rt-write-packet () (module-import-func "kiln_rt_write_packet" 3 1))
(defun rt-encode-packet () (module-import-func "kiln_rt_encode_packet" 3 1 :unwinds))
(defun rt-compile-program () (module-import-func "kiln_rt_compile_program" 4 1))
(defun rt-compile-packet () (module-import-func "kiln_rt_compile_packet" 3 1))
(defun rt-save-image () (module-import-func "kiln_rt_save_image" 4 1))
(defun rt-frame () (module-import-func "kiln_rt_frame" 4 1))

(defun emit-tls-slot (sym)
  "Raw address of the TLS slot of the symbol operand SYM (index 0 if it
has never been bound). The table does not move."
  (copy-to-var `(:add (:load :ctx ,+ctx-tls+) (:shl (:field-load ,kiln.kir::+packet-field-symbol-tls-index+ ,sym) 2)) :raw))

(defun emit-symbol-value (sym)
  "Current value of the symbol operand SYM, possibly UNBOUND."
  (let ((addr (emit-tls-slot sym))
        (v (new-var))
        (global (new-block)) (join (new-block)))
    (emit `(:set ,v (:load ,addr 0)))
    (br `(:eq ,v ,+no-tls-value+) global join)
    (start-block global)
    (emit `(:set ,v (:field-load ,kiln.kir::+packet-field-symbol-value+ ,sym)))
    (jump join)
    (start-block join)
    v))

(defun emit-set-symbol-value (sym value)
  (let ((addr (emit-tls-slot sym))
        (global (new-block)) (local (new-block)) (join (new-block)))
    (br `(:eq (:load ,addr 0) ,+no-tls-value+) global local)
    (start-block global)
    (emit `(:field-store ,kiln.kir::+packet-field-symbol-value+ ,sym ,value))
    (jump join)
    (start-block local)
    (emit `(:store ,addr 0 ,value))
    (jump join)
    (start-block join)))

(defun emit-check-bound (v sym)
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:eq ,v ,+unbound+) bad ok)
    (start-block bad)
    (emit-error +err-unbound-variable+ sym)
    (start-block ok)))

(defun constant-symbol-p (name)
  (or (null name) (eq name t) (keywordp name)))

(defun emit-unbind (region)
  "Restores the value saved in the binding entry of REGION."
  (let ((s `(:slot ,(region-slot region))))
    (emit `(:store (:add (:load :ctx ,+ctx-tls+) (:shl (:load ,s ,+dyn-pend-target+) 2))
                   0 (:load ,s ,+dyn-pend-value+)))))

(defun emit-tls-index (sym)
  "Raw variable holding the TLS index of the symbol operand SYM, assigned
if needed (not a safepoint)."
  (let ((index (copy-to-var `(:field-load ,kiln.kir::+packet-field-symbol-tls-index+ ,sym) :raw))
        (assign (new-block)) (have (new-block)))
    (br `(:eq ,index 0) assign have)
    (start-block assign)
    (emit `(:call-rt ,(rt-tls-index) (,index) (:ctx ,sym) :nil))
    (jump have)
    (start-block have)
    index))

(defun emit-unbind-progv (region)
  "Restores the bindings saved in the progv entry of REGION. No calls."
  (let ((l (copy-to-var `(:load (:slot ,(region-slot region)) ,+dyn-tag+)))
        (head (new-block)) (body (new-block)) (done (new-block)))
    (jump head)
    (start-block head)
    (br `(:eq ,l ,(nil-value)) done body)
    (start-block body)
    (let ((pair (copy-to-var `(:field-load ,kiln.kir::+packet-field-cons-car+ ,l))))
      (emit `(:store (:add (:load :ctx ,+ctx-tls+)
                           (:shl (:field-load ,kiln.kir::+packet-field-symbol-tls-index+ (:field-load ,kiln.kir::+packet-field-cons-car+ ,pair)) 2))
                     0 (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,pair))))
    (emit `(:set ,l (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,l)))
    (jump head)
    (start-block done)))


;;; Allocation

(defparameter *inline-alloc-limit* 128
  "Objects of at most this many bytes (a constant size) are allocated by
compiled code itself, bumping the allocator's cursor.")

(defun emit-alloc (bytes header &optional (zero-p t))
  "Allocates an object; returns a raw variable holding its untagged
address. The payload is zeroed when ZERO-P is true. No safepoint may occur
before the address is tagged and stored in an obj variable."
  (let ((p (new-var :raw)))
    (if (and (integerp bytes) (<= 8 bytes *inline-alloc-limit*) (zerop (mod bytes 8)))
        (let ((cursor (new-var :raw)) (end (new-var :raw))
              (fast (new-block)) (slow (new-block)) (done (new-block)))
          (emit `(:set ,cursor (:load :ctx ,+ctx-alloc-cursor+)))
          (emit `(:set ,p (:load ,cursor 0)))
          (emit `(:set ,end (:add ,p ,bytes)))
          (br `(:le ,end (:load (:load :ctx ,+ctx-alloc-limit+) 0)) fast slow)
          (start-block fast)
          (emit `(:store ,cursor 0 ,end))
          (emit `(:store ,p 0 ,header))
          (when zero-p
            (loop for offset from 8 below bytes by 8
                  do (emit `(:store ,p ,offset 0))))
          (jump done)
          (start-block slow)
          (emit `(:call-rt ,(rt-alloc) (,p) (:ctx ,bytes ,header) ,(handler)))
          (jump done)
          (start-block done))
        (emit `(:call-rt ,(rt-alloc) (,p) (:ctx ,bytes ,header) ,(handler))))
    p))

(defun emit-cons (a b)
  ;; A and B are live across the allocation; as variables they are spilled
  ;; and reloaded around it (stack maps).
  (let* ((a (if (integerp a) a (copy-to-var a)))
         (b (if (integerp b) b (copy-to-var b)))
         (p (emit-alloc +cons-bytes+ +kind-cons+ nil)))
    (emit `(:store ,p 8 ,a))
    (emit `(:store ,p 16 ,b))
    (copy-to-var `(:add ,p ,+tag-cons+))))

;;; Cells (assignment conversion): a cell is a cons whose car is the value.


;;; Functions

(defstruct (parsed-lambda-list (:conc-name ll-))
  (required '())   ; variable definitions
  (optional '())   ; (variable supplied-p) definitions
  (rest nil)       ; variable definition
  (keys '())       ; (variable supplied-p keyword)
  (key-p nil)
  (allow-other-keys nil))

(defun arg-operand (args i)
  "Argument I (an integer) on function entry: ARGS hold the register
arguments; later ones are in the transfer area."
  (if (< i +reg-args+)
      (nth i args)
      `(:transfer-ref ,(- i +reg-args+))))

(defun emit-nargs-check (min max)
  "MAX is NIL for no upper limit."
  (let ((bad (new-block)) (ok (new-block)))
    (br (cond ((and max (= min max)) `(:ne :nargs ,min))
              (max `(:or (:lt :nargs ,min) (:gt :nargs ,max)))
              (t `(:lt :nargs ,min)))
        bad ok)
    (start-block bad)
    (emit-error +err-wrong-nargs+ `(:shl :nargs ,+fixnum-shift+))
    (start-block ok)))

(defun emit-find-key (plist keyword value supplied)
  "Sets VALUE and SUPPLIED (variables) from the first occurrence of
KEYWORD in the keyword argument list PLIST; leaves them alone otherwise."
  (let ((cur (copy-to-var plist)) (found (copy-to-var (nil-value)))
        (head (new-block)) (body (new-block)) (hit (new-block)) (next (new-block))
        (done (new-block)))
    (jump head)
    (start-block head)
    (br `(:eq ,cur ,(nil-value)) done body)
    (start-block body)
    (br `(:and (:eq (:field-load ,kiln.kir::+packet-field-cons-car+ ,cur) ,(constant-object keyword))
               (:eq ,found ,(nil-value)))
        hit next)
    (start-block hit)
    (emit `(:set ,value (:field-load ,kiln.kir::+packet-field-cons-car+ (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,cur))))
    (emit `(:set ,supplied ,(t-value)))
    (emit `(:set ,found ,(t-value)))
    (jump next)
    (start-block next)
    (emit `(:set ,cur (:field-load ,kiln.kir::+packet-field-cons-cdr+ (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,cur))))
    (jump head)
    (start-block done)))

(defun emit-check-keywords (plist keywords allow-other-keys)
  "Signals an error if PLIST has odd length, or (unless other keys are
allowed) a keyword not in KEYWORDS."
  (let ((cur (copy-to-var plist))
        (allow (copy-to-var (if allow-other-keys (t-value) (nil-value))))
        (allow-supplied (copy-to-var (nil-value)))
        (head (new-block)) (body (new-block)) (odd (new-block)) (even (new-block))
        (check (new-block)) (unknown (new-block)) (next (new-block)) (done (new-block)))
    ;; Parity first: the other loops step two elements at a time.
    (let ((c (copy-to-var plist))
          (h (new-block)) (b (new-block)) (step (new-block)) (ok (new-block)))
      (jump h)
      (start-block h)
      (br `(:eq ,c ,(nil-value)) ok b)
      (start-block b)
      (br `(:eq (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,c) ,(nil-value)) odd step)
      (start-block step)
      (emit `(:set ,c (:field-load ,kiln.kir::+packet-field-cons-cdr+ (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,c))))
      (jump h)
      (start-block odd)
      (emit-error +err-odd-keywords+ plist)
      (start-block ok))
    (unless allow-other-keys
      (emit-find-key plist :allow-other-keys allow allow-supplied))
    (jump head)
    (start-block head)
    (br `(:eq ,cur ,(nil-value)) done body)
    (start-block body)
    (jump even)
    (start-block even)
    (br `(:ne ,allow ,(nil-value)) next check)
    (start-block check)
    (let ((key (copy-to-var `(:field-load ,kiln.kir::+packet-field-cons-car+ ,cur))))
      (dolist (k (cons :allow-other-keys keywords))
        (let ((no (new-block)))
          (br `(:eq ,key ,(constant-object k)) next no)
          (start-block no)))
      (jump unknown)
      (start-block unknown)
      (emit-error +err-unknown-keyword+ key))
    (start-block next)
    (emit `(:set ,cur (:field-load ,kiln.kir::+packet-field-cons-cdr+ (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,cur))))
    (jump head)
    (start-block done)))

(defun emit-entry (ll &key rest-slots)
  "Binds the parameters of the parsed lambda list LL on function entry."
  (let* ((args (loop for reg in '(:a0 :a1 :a2) collect (copy-to-var reg)))
         (nreq (length (ll-required ll)))
         (npos (+ nreq (length (ll-optional ll))))
         (rest-p (or (ll-rest ll) (ll-key-p ll))))
    (when (> npos (+ +reg-args+ +values-max+))
      (fail "functions with more than ~D positional parameters are not supported"
            (+ +reg-args+ +values-max+)))
    ;; Positional arguments first: the transfer area is only valid until
    ;; the first safepoint. Reading it before the count check is harmless.
    (loop for p in (ll-required ll)
          for i from 0
          do (bind-var p (arg-operand args i)))
    (loop for (p supplied) in (ll-optional ll)
          for i from nreq
          do (bind-var p `(:select (:gt :nargs ,i) ,(arg-operand args i) ,(nil-value)))
             (bind-var supplied `(:select (:gt :nargs ,i) ,(t-value) ,(nil-value))))
    (emit-nargs-check nreq (if rest-p nil npos))
    (when rest-p
      (let ((list (emit-rest-list args npos rest-slots)))
        (when (ll-rest ll)
          (bind-var (ll-rest ll) list))
        (when (ll-key-p ll)
          (emit-check-keywords list (mapcar #'third (ll-keys ll)) (ll-allow-other-keys ll))
          (loop for (p supplied keyword) in (ll-keys ll)
                do (let ((v (bind-var p (nil-value)))
                         (s (bind-var supplied (nil-value))))
                     (emit-find-key list keyword v s))))))))

(defun local-function-label-name (name)
  "NAME's part of the label of a local function: a gensym's without its
number, so that the labels do not depend on the image that compiles (the
host or kiln)."
  (mangle (cond ((and (symbolp name) (symbol-package name)) (symbol-name name))
                ((symbolp name) (string-right-trim "0123456789" (symbol-name name)))
                (t (princ-to-string name)))))


;;; Calls

(defun emit-check-function (f)
  (let ((general (new-block)) (bad (new-block)) (ok (new-block)))
    (br `(:eq (:and ,f ,+tag-mask+) ,+tag-general+) general bad)
    (start-block general)
    (br `(:eq (:and (:load ,f ,(- +tag-general+)) ,+function-kind-mask+) ,+kind-function+) ok bad)
    (start-block bad)
    (emit-error +err-not-function+ f)
    (start-block ok)))

(defun emit-function-designator (f)
  "Returns a variable holding the function designated by F: F itself if
it is a function, the global function of F if it is a symbol."
  (let ((r (copy-to-var f))
        (general (new-block)) (not-function (new-block)) (symbol (new-block))
        (bad (new-block)) (ok (new-block)))
    (br `(:eq (:and ,r ,+tag-mask+) ,+tag-general+) general bad)
    (start-block general)
    (br `(:eq (:and (:load ,r ,(- +tag-general+)) ,+function-kind-mask+) ,+kind-function+) ok not-function)
    (start-block not-function)
    (br `(:eq (:and (:load ,r ,(- +tag-general+)) ,+kind-mask+) ,+kind-symbol+) symbol bad)
    (start-block symbol)
    (emit `(:set ,r (:field-load ,kiln.kir::+packet-field-symbol-function+ ,r)))
    (jump ok)
    (start-block bad)
    (emit-error +err-not-function+ r)
    (start-block ok)
    r))

(defun emit-check-symbol (s)
  (let ((general (new-block)) (bad (new-block)) (ok (new-block)))
    (br `(:eq (:and ,s ,+tag-mask+) ,+tag-general+) general bad)
    (start-block general)
    (br `(:eq (:and (:load ,s ,(- +tag-general+)) ,+kind-mask+) ,+kind-symbol+) ok bad)
    (start-block bad)
    (emit-error +err-not-symbol+ s)
    (start-block ok)))

(defun emit-lisp-call (fobj vals)
  "Calls FOBJ after evaluating all operands; the backend arranges the ABI."
  (when (> (length vals) (+ +reg-args+ +values-max+))
    (fail "calls with more than ~D arguments are not supported"
          (+ +reg-args+ +values-max+)))
  (let* ((callee (if (kiln.kir::kvar-p fobj) fobj (copy-to-var fobj)))
         (arguments (mapcar (lambda (v)
                              (if (or (integerp v) (kiln.kir::kvar-p v)) v (copy-to-var v)))
                            vals))
         (v0 (new-var)) (nv (new-var :raw)))
    (emit `(:invoke ,v0 ,nv ,callee ,arguments ,(handler) ,@(call-loc)))
    (values v0 nv)))

(defun function-cell-value (name)
  (multiple-value-bind (base offset) (function-cell-place name)
    (copy-to-var `(:load ,base ,offset))))

(defun lower-args (asts)
  (mapcar (lambda (a) (copy-to-var (lower a))) asts))

(defparameter *type-predicates*
  '((cons . consp) (symbol . symbolp) (list . listp) (null . null) (atom . atom)
    (integer . integerp) (signed-byte . integerp) (number . numberp)
    (character . characterp) (function . functionp) (compiled-function . compiled-function-p)
    (keyword . keywordp) (string . stringp) (base-string . kiln.kernel::base-string-p)
    (simple-string . simple-string-p) (simple-base-string . kiln.kernel::simple-base-string-p)
    (simple-vector . simple-vector-p)
    (fixnum . kiln.kernel::fixnump) (bignum . kiln.kernel::bignump)
    (ratio . kiln.kernel::ratiop) (complex . complexp)
    (float . floatp) (real . realp) (rational . rationalp)
    (single-float . kiln.kernel::single-float-p)
    (short-float . kiln.kernel::single-float-p)
    (double-float . kiln.kernel::double-float-p)
    (long-float . kiln.kernel::double-float-p))
  "Atomic types whose TYPEP is a call to a predicate.")

(defun integer-bound (bound upperp)
  "The inclusive integer bound for BOUND (an integer, a one-element
integer list, or * / NIL), or NIL if unbounded or invalid."
  (cond ((integerp bound) bound)
        ((and (consp bound) (integerp (first bound)) (null (rest bound)))
         (if upperp (1- (first bound)) (1+ (first bound))))
        (t nil)))

(defun type-fixnum-bounds (type)
  "If TYPE is a specifier for an integer range within fixnum bounds,
returns LOW, HIGH and T; else NIL, NIL and NIL."
  (cond ((eq type 'fixnum)
         (values +most-negative-fixnum+ +most-positive-fixnum+ t))
        ((eq type 'bit)
         (values 0 1 t))
        ((and (consp type) (hir-proper-list-p (rest type)))
         (let ((head (first type)) (args (rest type)))
           (multiple-value-bind (low high)
               (case head
                 (integer
                  (when (<= (length args) 2)
                    (values (if (or (null args) (eq (first args) '*)) nil (integer-bound (first args) nil))
                            (if (or (null (rest args)) (eq (second args) '*)) nil (integer-bound (second args) t)))))
                 (mod
                  (when (and (= (length args) 1) (integerp (first args)) (plusp (first args)))
                    (values 0 (1- (first args)))))
                 (unsigned-byte
                  (when (and (= (length args) 1) (integerp (first args)) (<= 1 (first args) 62))
                    (values 0 (1- (ash 1 (first args))))))
                 (signed-byte
                  (when (and (= (length args) 1) (integerp (first args)) (<= 1 (first args) 63))
                    (let ((half (ash 1 (1- (first args)))))
                      (values (- half) (1- half))))))
             (if (and low high
                      (<= +most-negative-fixnum+ low)
                      (<= high +most-positive-fixnum+))
                 (values low high t)
                 (values nil nil nil)))))
        (t (values nil nil nil))))

(defun emit-fixnum-range-test (val low high)
  "Raw 0/1 operand: is VAL a fixnum in LOW..HIGH?"
  (let ((cond `(:eq (:and ,val 1) 0)))
    (when (> low +most-negative-fixnum+)
      (setf cond `(:and ,cond (:ge ,val ,(ash low +fixnum-shift+)))))
    (when (< high +most-positive-fixnum+)
      (setf cond `(:and ,cond (:le ,val ,(ash high +fixnum-shift+)))))
    cond))

(defun inline-typep-specifier-p (type)
  (cond ((member type '(t nil boolean)) t)
        ((nth-value 2 (type-fixnum-bounds type)) t)
        ((and (symbolp type) (assoc type *type-predicates*)) t)
        ((and (consp type) (hir-proper-list-p (rest type)))
         (case (first type)
           (eql (= (length (rest type)) 1))
           (member (<= (length (rest type)) 8))
           (not (and (= (length (rest type)) 1)
                     (inline-typep-specifier-p (second type))))
           ((or and) (every #'inline-typep-specifier-p (rest type)))))
        (t nil)))

(defun emit-inline-typep (val type)
  (multiple-value-bind (low high fixnum-range-p) (type-fixnum-bounds type)
    (cond (fixnum-range-p
           (boolean-value (emit-fixnum-range-test val low high)))
          ((eq type t) (t-value))
          ((eq type nil) (nil-value))
          ((eq type 'boolean)
           (boolean-value `(:or (:eq ,val ,(nil-value)) (:eq ,val ,(t-value)))))
          ((symbolp type)
           (let* ((predicate (cdr (assoc type *type-predicates*)))
                  (primitive (gethash predicate *primitives*)))
             (if primitive
                 (funcall primitive (list val))
                 (emit-lisp-call (function-cell-value predicate) (list val)))))
          ((eq (first type) 'eql)
           (let ((c (hir-node 0 nil (second type))))
             (if (eq-comparable-constant-p c)
                 (boolean-value `(:eq ,val ,(constant-object (second type))))
                 (funcall (gethash 'eql *primitives*)
                          (list val (constant-object (second type)))))))
          ((eq (first type) 'member)
           (let ((items (rest type)))
             (cond ((null items) (nil-value))
                   ((every (lambda (x) (eq-comparable-constant-p (hir-node 0 nil x))) items)
                    (boolean-value
                     (reduce (lambda (a b) `(:or ,a ,b))
                             (mapcar (lambda (x) `(:eq ,val ,(constant-object x))) items))))
                   (t (emit-lisp-call (function-cell-value 'kiln.kernel::%member-eql)
                                      (list val (constant-object items)))))))
          ((eq (first type) 'not)
           (boolean-value `(:eq ,(emit-inline-typep val (second type)) ,(nil-value))))
          ((eq (first type) 'or)
           (if (null (rest type))
               (nil-value)
               (let ((r (copy-to-var (t-value)))
                     (done (new-block)))
                 (loop for (sub . more) on (rest type)
                       do (let ((v (emit-inline-typep val sub)))
                            (if more
                                (let ((next (new-block)))
                                  (br `(:ne ,v ,(nil-value)) done next)
                                  (start-block next))
                                (progn
                                  (emit `(:set ,r ,v))
                                  (jump done)))))
                 (start-block done)
                 r)))
          ((eq (first type) 'and)
           (if (null (rest type))
               (t-value)
               (let ((r (copy-to-var (nil-value)))
                     (done (new-block)))
                 (loop for (sub . more) on (rest type)
                       do (let ((v (emit-inline-typep val sub)))
                            (if more
                                (let ((next (new-block)))
                                  (br `(:eq ,v ,(nil-value)) done next)
                                  (start-block next))
                                (progn
                                  (emit `(:set ,r ,v))
                                  (jump done)))))
                 (start-block done)
                 r))))))

(defun cached-typep-specifier-p (type)
  (cond ((symbolp type)
         (and type
              (not (member (symbol-package type)
                           (list (find-package '#:common-lisp) (find-package '#:keyword))))))
        ((and (consp type) (hir-proper-list-p (rest type)))
         (case (first type)
           ((or and)
            (and (every (lambda (x) (or (symbolp x) (cached-typep-specifier-p x))) (rest type))
                 (some #'cached-typep-specifier-p (rest type))))
           (not
            (and (= (length (rest type)) 1)
                 (cached-typep-specifier-p (second type))))))
        (t nil)))

(defun call-ast (name arg-asts)
  (hir-node 7 nil name (coerce arg-asts 'simple-vector)))

(defun long-call-ast (name arg-asts)
  "An AST equivalent to the call of NAME (LIST, LIST*, VECTOR, NCONC or
APPEND) with ARG-ASTS, whose calls have few enough arguments: (LIST* a1
... an REST) in chunks, (COERCE list 'SIMPLE-VECTOR) for VECTOR, nested
calls for the associative NCONC and APPEND."
  (let ((chunk 60))
    (labels ((literal (value) (hir-node 0 nil value))
             (list-ast (asts tail-ast)
               ;; The list of ASTS's values followed by TAIL-AST's value.
               (if (<= (length asts) chunk)
                   (call-ast 'list* (append asts (list tail-ast)))
                   (call-ast 'list* (append (subseq asts 0 chunk)
                                            (list (list-ast (nthcdr chunk asts) tail-ast)))))))
      (ecase name
        ((nconc append)
         ;; Associative: (F (F a1 ... a60) (F a61 ...)).
         (call-ast name (list (call-ast name (subseq arg-asts 0 chunk))
                              (call-ast name (nthcdr chunk arg-asts)))))
        (list (list-ast arg-asts (literal nil)))
        (list* (list-ast (butlast arg-asts) (car (last arg-asts))))
        (vector (call-ast 'coerce
                          (list (list-ast arg-asts (literal nil))
                                (literal 'simple-vector))))))))

(defun eq-comparable-constant-p (ast)
  "True if AST is a constant that EQL compares as EQ: not a number that is
a heap object (bignum, ratio, double float, complex)."
  (multiple-value-bind (value constantp) (constant-value ast)
    (and constantp
         (not (and (integerp value)
                   (not (<= +most-negative-fixnum+ value +most-positive-fixnum+))))
         (not (typep value '(or ratio double-float complex))))))

(defun simple-sequence-test (keyword-asts)
  "EQL or EQ if the keyword arguments KEYWORD-ASTS (of MEMBER or ASSOC)
make that the test, with no key: none, or :TEST #'EQL, #'EQ, 'EQL or
'EQ. Else NIL."
  (cond ((null keyword-asts) 'eql)
        ((and (= (length keyword-asts) 2)
              (eq (constant-value (first keyword-asts)) :test))
         (let* ((test (second keyword-asts))
                (name (cond ((and (hir-node-p test) (= (hir-node-kind test) 5)) (hir-node-a test))
                            (t (multiple-value-bind (value constantp) (constant-value test)
                                 (and constantp value))))))
           (and (member name '(eq eql)) name)))
        (t nil)))

(defun lower-cached-typep (object-ast type)
  "(TYPEP OBJECT 'TYPE), TYPE a symbol that is not a standard type name
(a class name, mostly): a call to KILN.KERNEL::%TYPEP-CACHED with a cache
of this call: a cons of static data whose car is NIL or a fixnum, the
stamp of the last object's class and the result. Holding
no pointer, the cons need not be scanned by the GC."
  (let ((object (copy-to-var (lower object-ast)))
        (label (fresh-label "kiln_typep_cache_")))
    (module-data label `(:words ,+kind-cons+ ,(nil-word) ,(nil-word)))
    (emit-lisp-call (function-cell-value 'kiln.kernel::%typep-cached)
                    (list object (constant-object type) `(:addr ,label ,+tag-cons+)))))

(defun lower-cached-slot-value (object-ast slot-name)
  "(SLOT-VALUE OBJECT 'SLOT-NAME) at a call site: a call to
KILN.KERNEL::%SLOT-VALUE-CACHED with a cache of this call, a cons of static
data whose car is the stamp of the last object's class and whose cdr is the
slot's location there, both fixnums: a stamp belongs to one finalization of
a class, so it is the guard of the location (see lisp/target/clos/
support.lisp)."
  (let ((object (copy-to-var (lower object-ast)))
        (label (fresh-label "kiln_slot_value_cache_")))
    (module-data label `(:words ,+kind-cons+ ,(nil-word) ,(nil-word)))
    (emit-lisp-call (function-cell-value 'kiln.kernel::%slot-value-cached)
                    (list object (constant-object slot-name)
                          `(:addr ,label ,+tag-cons+)))))

(defun lower-cached-set-slot-value (value-ast object-ast slot-name)
  "(SETF (SLOT-VALUE OBJECT 'SLOT-NAME) VALUE), the same cache as
LOWER-CACHED-SLOT-VALUE."
  (let ((value (copy-to-var (lower value-ast)))
        (object (copy-to-var (lower object-ast)))
        (label (fresh-label "kiln_set_slot_value_cache_")))
    (module-data label `(:words ,+kind-cons+ ,(nil-word) ,(nil-word)))
    (emit-lisp-call (function-cell-value 'kiln.kernel::%set-slot-value-cached)
                    (list value object (constant-object slot-name)
                          `(:addr ,label ,+tag-cons+)))))

(defun call-site-root ()
  "A mutable cache cons whose object-valued car is a static GC root."
  (let ((label (fresh-label "kiln_call_site_")))
    (module-data label `(:words ,+kind-cons+ ,(nil-word) ,(nil-word)))
    (module-root label 1)
    `(:addr ,label ,+tag-cons+)))

(defun call-site-specialization-p ()
  ;; The construction protocol itself (kernel, CLOS) calls MAKE-INSTANCE plainly.
  (not (member (kmodule-name *module*) '("kernel" "clos") :test #'string=)))

(defun lower-constructor-call (name arg-asts class-name keys)
  (let* ((vals (lower-args arg-asts))
         (helper (function-cell-value 'kiln.kernel::%constructor-target))
         (entry (copy-to-var `(:field-load ,kiln.kir::+packet-field-function-entry+ ,helper) :raw))
         (fallback (new-block)) (specialized (new-block)) (done (new-block))
         (result (new-var)) (count (new-var :raw)))
    (br `(:eq ,entry (:addr ,(undefined-function-entry))) fallback specialized)
    (start-block fallback)
    (multiple-value-call #'set-mv result count
      (emit-lisp-call (function-cell-value name) vals))
    (jump done)
    (start-block specialized)
    (let ((function (copy-to-var
                     (emit-lisp-call helper (list (call-site-root)
                                                  (constant-object class-name)
                                                  (constant-object keys))))))
      (multiple-value-call #'set-mv result count
        (emit-lisp-call function
                        (loop for value in (cddr vals) by #'cddr collect value))))
    (jump done)
    (start-block done)
    (values result count)))

(defun list-call-elements (ast)
  "The argument ASTs of AST if it is a call to LIST, and T; else NIL and NIL."
  (if (and (hir-node-p ast) (= (hir-node-kind ast) 7) (eq (hir-node-a ast) 'list))
      (values (coerce (hir-node-b ast) 'list) t)
      (values nil nil)))

(defun null-constant-p (ast)
  (multiple-value-bind (value constantp) (constant-value ast)
    (and constantp (null value))))

(defun simplify-append-asts (asts)
  "Simplifies the argument ASTs of APPEND (such as quasiquote expansions):
drops empty lists, merges adjacent LIST calls, and drops a trailing NIL
after a LIST call."
  (let ((out '()))
    (loop for (ast . rest) on asts
          do (multiple-value-bind (elems listp) (list-call-elements ast)
               (cond ((and (null rest) (null-constant-p ast)
                           out (nth-value 1 (list-call-elements (first out)))))
                     ((and rest (or (null-constant-p ast) (and listp (null elems)))))
                     ((and (null rest) listp (null elems))
                      (unless (and out (nth-value 1 (list-call-elements (first out))))
                        (push (hir-node 0 nil nil) out)))
                     ((and listp out (nth-value 1 (list-call-elements (first out))))
                      (setf (first out)
                            (call-ast 'list (append (list-call-elements (first out)) elems))))
                     (t (push ast out)))))
    (nreverse out)))

(defun lower-global-call (name arg-asts)
  (when (eq name 'append)
    (let ((asts (simplify-append-asts arg-asts)))
      (cond ((null asts)
             (return-from lower-global-call (nil-value)))
            ((null (rest asts))
             (return-from lower-global-call (lower (first asts))))
            ((nth-value 1 (list-call-elements (first asts)))
             (return-from lower-global-call
               (lower-global-call 'list*
                                  (append (list-call-elements (first asts))
                                          (list (call-ast 'append (rest asts)))))))
            ((= (length asts) 2)
             (return-from lower-global-call
               (lower-global-call 'kiln.kernel::append-2 asts)))
            (t (setf arg-asts asts)))))
  (when (and (eq name 'make-instance) (call-site-specialization-p)
             (oddp (length arg-asts))
             (<= (length arg-asts) (+ +reg-args+ +values-max+)))
    (multiple-value-bind (class-name constantp) (constant-value (first arg-asts))
      (when (and constantp (symbolp class-name) class-name)
        (let ((keys '()) (valid t))
          (loop for key-ast in (rest arg-asts) by #'cddr
                do (multiple-value-bind (key constantp) (constant-value key-ast)
                     (if (and constantp (symbolp key)) (push key keys) (setf valid nil))))
          (when valid
            (return-from lower-global-call
              (lower-constructor-call name arg-asts class-name (nreverse keys))))))))
  ;; (EQL x constant), as CASE expands into, is EQ for most constants.
  (when (and (eq name 'eql) (= (length arg-asts) 2)
             (or (eq-comparable-constant-p (first arg-asts))
                 (eq-comparable-constant-p (second arg-asts))))
    (return-from lower-global-call (lower-global-call 'eq arg-asts)))
  ;; One subscript: the primitives with a simple vector fast path.
  (cond ((and (eq name 'aref) (= (length arg-asts) 2))
         (setf name 'kiln.kernel::%aref-1))
        ((and (equal name '(setf aref)) (= (length arg-asts) 3))
         (setf name 'kiln.kernel::%set-aref-1)))
  (when (and (eq name 'typep) (= (length arg-asts) 2))
    (multiple-value-bind (type constantp) (constant-value (second arg-asts))
      (when constantp
        (let ((predicate (and (symbolp type) (cdr (assoc type *type-predicates*)))))
          (cond (predicate
                 (return-from lower-global-call
                   (lower-global-call predicate (list (first arg-asts)))))
                ((inline-typep-specifier-p type)
                 (return-from lower-global-call
                   (emit-inline-typep (copy-to-var (lower (first arg-asts))) type)))
                ((cached-typep-specifier-p type)
                 (return-from lower-global-call
                   (lower-cached-typep (first arg-asts) type))))))))
  ;; SLOT-VALUE and (SETF SLOT-VALUE) with a constant slot name: a cache
  ;; of the slot's location, guarded by the object's stamp.
  (when (and (eq name 'slot-value) (= (length arg-asts) 2))
    (multiple-value-bind (slot-name constantp) (constant-value (second arg-asts))
      (when (and constantp (symbolp slot-name))
        (return-from lower-global-call
          (lower-cached-slot-value (first arg-asts) slot-name)))))
  (when (and (equal name '(setf slot-value)) (= (length arg-asts) 3))
    (multiple-value-bind (slot-name constantp) (constant-value (third arg-asts))
      (when (and constantp (symbolp slot-name))
        (return-from lower-global-call
          (lower-cached-set-slot-value (first arg-asts) (second arg-asts)
                                       slot-name)))))
  ;; MEMBER and ASSOC with EQL or EQ as the test and no key: functions of
  ;; two arguments, without parsing keywords.
  (when (and (member name '(member assoc)) (>= (length arg-asts) 2))
    (let ((test (simple-sequence-test (rest (rest arg-asts)))))
      (when test
        (return-from lower-global-call
          (lower-global-call (cdr (assoc (list name test)
                                         '(((member eql) . kiln.kernel::%member-eql)
                                           ((member eq) . kiln.kernel::%member-eq)
                                           ((assoc eql) . kiln.kernel::%assoc-eql)
                                           ((assoc eq) . kiln.kernel::%assoc-eq))
                                         :test #'equal))
                             (subseq arg-asts 0 2))))))
  ;; (FUNCALL #'F ...) and %PRIMOP are converted before (lisp/hir/convert.lisp).
  (progn
      (let ((constant-name (and (equal name '(setf fdefinition))
                                (= (length arg-asts) 2)
                                (quoted-constant (second arg-asts)))))
        (cond
          ;; (SETF FDEFINITION) of a constant name, as DEFUN expands to:
          ;; store straight into the cell. This is also the only way to
          ;; define (SETF F) functions until run-time function names exist.
          ((and constant-name (or (symbolp constant-name)
                                  (and (consp constant-name)
                                       (eq (first constant-name) 'setf))))
           (let ((f (copy-to-var (lower (first arg-asts)))))
             (emit-check-function f)
             (multiple-value-bind (base offset) (function-cell-place constant-name)
               (emit `(:store ,base ,offset ,f)))
             ;; Early kernel definitions precede the notification function.
             (let* ((notify (function-cell-value 'kiln.kernel::note-function-change))
                    (entry (copy-to-var `(:field-load ,kiln.kir::+packet-field-function-entry+ ,notify) :raw))
                    (changed (new-block))
                    (done (new-block)))
               (br `(:eq ,entry (:addr ,(undefined-function-entry))) done changed)
               (start-block changed)
               (emit-lisp-call notify (list (constant-object constant-name)))
               (jump done)
               (start-block done))
             f))
          ((and (> (length arg-asts) (+ +reg-args+ +values-max+))
                (member name '(list list* vector nconc append)))
           ;; Calls are limited to +REG-ARGS+ + +VALUES-MAX+ arguments:
           ;; build long lists in chunks, and vectors from them.
           (lower (long-call-ast name arg-asts)))
          (t
           (when (> (length arg-asts) (+ +reg-args+ +values-max+))
             (fail "the call to ~S has ~D arguments; at most ~D are supported"
                   name (length arg-asts) (+ +reg-args+ +values-max+)))
           (let ((primitive (and (not (and (eq name 'print)
                                            (or *image-literals* (/= (length arg-asts) 1))))
                                 (gethash name *primitives*)))
                 (vals (lower-args arg-asts)))
             ;; The PRINT primitive is the runtime's printer, for programs
             ;; without streams; code compiled into a running image has
             ;; them, and its output goes where *STANDARD-OUTPUT* says. A
             ;; call with a stream is the printer's PRINT.
             (if primitive
                 (funcall primitive vals)
                 (emit-lisp-call (function-cell-value name) vals))))))))

(defun quoted-constant (ast)
  (values (constant-value ast)))


;;; BLOCK and RETURN-FROM

(defstruct exit-info
  func            ; KIR function that contains the block or tagbody
  regions         ; regions outside it (targets of local exits)
  exit            ; BLOCK: exit block
  result          ; BLOCK: result variable
  count           ; BLOCK: raw variable, number of values
  double-primary  ; BLOCK: local exits carry binary64 bits
  block)          ; TAGBODY: KIR block of the tag

(defun emit-exit-token ()
  "A fresh object identifying one activation of a block or tagbody that a
closure may exit to. The closure holds it rather than the entry's stack
address: heap objects must not point into frames (C5), and a token cannot
be confused with a later activation at the same address."
  (emit-cons (nil-value) (nil-value)))


;;; TAGBODY and GO


;;; CATCH, THROW, UNWIND-PROTECT


;;; Module

(defun symbol-table-cell ()
  (format nil "kiln_symtab_~A" *module-label*))

(defun emit-note-symbol-table ()
  "Pushes the module's symbol table (SYMBOL-TABLE-LITERAL, stored in a
static cell when the module is complete) onto
KILN.KERNEL::*MODULE-SYMBOL-TABLES*, then calls
KILN.KERNEL::%REGISTER-MODULE-SYMBOLS if the package system has defined
it. Nothing binds the variable while modules are loaded, so
its global value is used directly."
  (let* ((sym (copy-to-var (word-operand (symbol-word 'kiln.kernel::*module-symbol-tables*))))
         (old (new-var))
         (unbound (new-block)) (join (new-block)))
    (emit `(:set ,old (:field-load ,kiln.kir::+packet-field-symbol-value+ ,sym)))
    (br `(:eq ,old ,+unbound+) unbound join)
    (start-block unbound)
    (emit `(:set ,old ,(nil-value)))
    (jump join)
    (start-block join)
    (let ((table (copy-to-var `(:load (:addr ,(symbol-table-cell)) 0))))
      (emit `(:field-store ,kiln.kir::+packet-field-symbol-value+ ,sym ,(emit-cons table old)))))
  (let ((f (function-cell-value 'kiln.kernel::%register-module-symbols))
        (call (new-block)) (join (new-block)))
    (br `(:eq (:field-load ,kiln.kir::+packet-field-function-entry+ ,f) (:addr ,(undefined-function-entry))) join call)
    (start-block call)
    (emit-lisp-call f '())
    (jump join)
    (start-block join)))

(defparameter *toplevel-chunk-size* 16
  "Top-level forms per function: the init function calls one function per
chunk, since code generation time grows faster than linearly with the
size of a function.")

(defun compile-toplevel-chunk (name asts)
  "A function NAME of no arguments that runs the top-level forms ASTS;
returns the operand of its (static) function object."
  (let ((*regions* '())
        (*debug-vars* '())
        (*debug-var-count* 0)
        (files (remove-duplicates (mapcar #'toplevel-form-file asts))))
    (with-function (name)
      (let ((*self* (copy-to-var :self)))
        (emit-poll)
        (dolist (form asts)
          (let ((*toplevel* form))
            (hir-lower-toplevel (toplevel-form-ast form))))
        (emit `(:return ,(nil-value) 1)))
      (let ((*toplevel* (and (= (length files) 1) (first files)
                             (make-toplevel-form nil (first files) nil nil nil))))
        (set-function-debug '(:top-level-form) nil))))
  (let ((fobj (kiln.kir::kir-name name "_fobj")))
    (module-data fobj `(:words ,+kind-function+ (:func ,name)))
    `(:data ,fobj ,+tag-general+)))

(defun compile-toplevel-function (asts)
  "The module's init function: registers the module's symbols, then runs
the top-level forms in order, in chunks."
  (let ((chunks (loop with remaining = asts
                      for i from 0
                      while remaining
                      collect (compile-toplevel-chunk
                               (format nil "kiln_toplevel_~A_~D" *module-label* i)
                               (loop repeat *toplevel-chunk-size*
                                     while remaining
                                     collect (pop remaining))))))
    (let ((*regions* '()))
      (with-function ((format nil "kiln_toplevel_~A" *module-label*))
        (let ((*self* (copy-to-var :self)))
          (emit-poll)
          (unless *image-literals*
            (emit-note-symbol-table))
          (dolist (fobj chunks)
            (emit-lisp-call (copy-to-var (word-operand fobj)) '()))
          (emit `(:return ,(nil-value) 1)))))))

;;; The module's symbol table, for the package system: a
;;; simple vector of package descriptions #(name nicknames uses entries),
;;; one for each host package that is the home of a symbol of the module
;;; or that the module defined. ENTRIES holds a symbol and its status in
;;; the package, alternately: 1 if external, + 2 if shadowing, + 4 if the
;;; package is its home package. The run-time packages mirror the host
;;; packages the target sources were read into; KILN-USER (where test
;;; programs are read) is COMMON-LISP-USER.

(defun target-package-name (package)
  (if (eq package (find-package '#:kiln-user))
      "COMMON-LISP-USER"
      (package-name package)))

(defun target-package-nicknames (package)
  ;; Sorted, as the use list (SYMBOL-TABLE-LITERAL): their order differs
  ;; between images (ALEXANDRIA's nicknames).
  (if (eq package (find-package '#:kiln-user))
      '("CL-USER")
      (sort (copy-list (package-nicknames package)) #'string<)))

(defun target-package-local-nicknames (package known)
  "PACKAGE's local nicknames for packages among KNOWN: a list of
nickname, package name..., sorted by nickname."
  (loop for (nickname . actual)
          in (sort (copy-list (#+sbcl sb-ext:package-local-nicknames
                               #+kiln parcl::package-local-nicknames
                               package))
                   #'string< :key #'car)
        when (member actual known)
          append (list nickname (target-package-name actual))))

(defun package-entries (package symbols)
  (let ((shadowing (package-shadowing-symbols package)))
    (coerce (loop for sym in symbols
                  append (multiple-value-bind (found status)
                             (find-symbol (symbol-name sym) package)
                           (when (and (eq found sym) (member status '(:internal :external)))
                             (list sym (logior (if (eq status :external) 1 0)
                                               (if (member sym shadowing) 2 0)
                                               (if (eq (symbol-package sym) package) 4 0))))))
            'simple-vector)))

(defun symbol-table-literal (symbols session defined-packages)
  "SESSION (if any) remembers the packages described so far: a package's
use list only names packages that exist at run time."
  (let ((packages (copy-list defined-packages)))
    (dolist (sym symbols)
      (let ((p (symbol-package sym)))
        (when p (pushnew p packages))))
    (let ((known (if session
                     (dolist (p packages (session-packages session))
                       (pushnew p (session-packages session)))
                     packages)))
      (coerce (loop for p in packages
                    collect (vector (target-package-name p)
                                    (target-package-nicknames p)
                                    (sort (loop for u in (package-use-list p)
                                                when (member u known)
                                                  collect (target-package-name u))
                                          #'string<)
                                    (package-entries p symbols)
                                    (target-package-local-nicknames p known)))
              'simple-vector))))

(defun compile-module (asts module-name &key session defined-packages extra-symbols image)
  "Compiles the top-level forms ASTS (TOPLEVEL-FORMs) into a KIR module. The module's
symbol table describes its symbols, the EXTRA-SYMBOLS and the symbols of
the DEFINED-PACKAGES (host packages its DEFPACKAGE forms created) for the
package system.
IMAGE true: the module is to be loaded into the running image; its
literals are the image's objects, and it has no symbol table.
Returns the module and the vector of its literals."
  (let ((*module* (make-kmodule module-name))
        (*hir-lowering-epoch* (list nil))
        (*hir-native-environments* nil)
        (*hir-lifted-environments* nil)
        (*image-literals* (and image (make-hash-table :test 'eq)))
        (*image-literal-objects* '())
        (*module-label* (mangle module-name))
        (*counter* 0)
        (*constants* (make-hash-table :test 'eql))
        (*string-constants* (make-hash-table :test 'equal))
        (*cons-words* (make-hash-table :test 'equal))
        (*pending-conses* (make-hash-table :test 'eq))
        (*module-symbols* '())
        (*symbol-data-names* (make-hash-table :test 'eq))
        (*uninterned-symbols* (make-hash-table :test 'eq))
        (*uninterned-count* 0))
    (compile-toplevel-function asts)
    (when image
      (let ((literals (emit-literal-words))
            (init (kiln.kir::kir-name "kiln_toplevel_" *module-label*)))
        (module-data (kiln.kir::kir-name init "_fobj") `(:words ,+kind-function+ (:func ,init)))
        (module-init (kiln.kir::kir-name init "_fobj"))
        (return-from compile-module (values *module* literals))))
    ;; Sorted by name: the order of a package's symbols differs between
    ;; images.
    (dolist (sym (sort (copy-list extra-symbols) #'string< :key #'symbol-name))
      (symbol-word sym))
    ;; A package of the module has its external symbols, and those it
    ;; imports from packages that exist at run time: the module's code
    ;; may not refer to them (a macro imported and expanded away), but
    ;; source read in the package at run time does.
    (let ((target-packages (append defined-packages
                                   (and session (session-packages session))
                                   (list (find-package '#:common-lisp)))))
      (dolist (package defined-packages)
        (let ((symbols '()))
          (do-symbols (sym package)
            (let ((home (symbol-package sym)))
              (when (or (eq (nth-value 1 (find-symbol (symbol-name sym) package)) :external)
                        (and home (not (eq home package))
                             (member home target-packages)
                             (eq (nth-value 1 (find-symbol (symbol-name sym) package))
                                 :internal)))
                (pushnew sym symbols))))
          (dolist (sym (sort symbols #'string< :key #'symbol-name))
            (symbol-word sym)))))
    (module-data (symbol-table-cell)
                 `(:words ,(constant-word (symbol-table-literal
                                           *module-symbols* session defined-packages))))
    (let ((init (format nil "kiln_toplevel_~A" *module-label*)))
      (module-data (format nil "~A_fobj" init) `(:words ,+kind-function+ (:func ,init)))
      (module-init (format nil "~A_fobj" init)))
    *module*))
