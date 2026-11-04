(in-package #:kiln.compiler)

;;;; Lowering simplified Iconoclast ASTs to KIR. See docs/08-m2-front-end.md.
;;;;
;;;; The input comes from SIMPLIFY-AST: closures are converted (LABELS plus
;;;; SET-STATIC-ENVIRONMENT, READ-STATIC-ENVIRONMENT), assigned captured
;;;; variables live in cells (MAKE-CELL, READ-CELL, WRITE-CELL), and every
;;;; BLOCK and TAGBODY has a variable naming its exit point. Each
;;;; LOCAL-FUNCTION-AST becomes one KIR function; the top-level forms of a
;;;; file run in order from the module's init function.

(define-condition kiln-compile-error (error)
  ((message :initarg :message :reader kiln-compile-error-message))
  (:report (lambda (c s) (write-string (kiln-compile-error-message c) s))))

(defun fail (control &rest args)
  (error 'kiln-compile-error :message (apply #'format nil control args)))

;;; Names in the object file

(defun mangle (string)
  (with-output-to-string (out)
    (loop for c across string
          do (if (and (< (char-code c) 128) (alphanumericp c))
                 (write-char c out)
                 (format out "_~X_" (char-code c))))))

(defun symbol-label (sym)
  (mangle (format nil "~A:~A"
                  (let ((p (symbol-package sym))) (if p (package-name p) "#"))
                  (symbol-name sym))))

(defvar *counter*)

;;; Primitives (primitives.lisp)
(defvar *primitives* (make-hash-table :test 'equal)
  "Function name -> function of the list of argument operands.")


(defvar *module-label*)                 ; mangled module name

(defun fresh-label (prefix)
  "A name local to the current module. Modules are combined by kiln-cg,
so local names carry the module's name; shared ones (symbols) do not."
  (format nil "~A~A_~D" prefix *module-label* (incf *counter*)))

;;; Runtime functions

(defun rt-print () (module-import-func "kiln_rt_print" 2 1))
(defun rt-error () (module-import-func "kiln_rt_error" 3 0 :unwinds :noreturn))
(defun rt-poll () (module-import-func "kiln_rt_poll" 1 0 :unwinds))
(defun rt-throw () (module-import-func "kiln_rt_throw" 4 0 :unwinds :noreturn))
(defun rt-exit-to () (module-import-func "kiln_rt_exit_to" 4 0 :unwinds :noreturn))
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

(defun word-operand (word)
  (if (integerp word) word `(:addr ,@(rest word))))

(defun nil-word () `(:data ,(module-import-data "kiln_nil") ,+tag-general+))
(defun t-word () `(:data ,(module-import-data "kiln_t") ,+tag-general+))
(defun nil-value () (word-operand (nil-word)))
(defun t-value () (word-operand (t-word)))

(defun undefined-function-entry ()
  "A function that signals an undefined-function error for the symbol in
its first env word. Every function cell starts out holding one."
  (let ((name "kiln_undefined_function"))
    (unless (gethash name (kiln.kir::kmodule-defined *module*))
      (setf (gethash name (kiln.kir::kmodule-defined *module*)) t)
      (module-shared name)
      (let ((*regions* '()))
        (with-function (name)
          (emit-error +err-undefined-function+ `(:load :self ,+fobj-env+)))))
    name))

(defun undefined-setf-function-entry ()
  "As UNDEFINED-FUNCTION-ENTRY, for the function (SETF symbol)."
  (let ((name "kiln_undefined_setf_function"))
    (unless (gethash name (kiln.kir::kmodule-defined *module*))
      (setf (gethash name (kiln.kir::kmodule-defined *module*)) t)
      (module-shared name)
      (let ((*regions* '()))
        (with-function (name)
          (emit-error +err-undefined-setf-function+ `(:load :self ,+fobj-env+)))))
    name))

(defun function-cell-data (name)
  "Data object and word index of the global function cell of NAME."
  (cond ((symbolp name)
         (values (symbol-data name) 3))
        ((and (consp name) (eq (first name) 'setf) (symbolp (second name))
              (second name) (not (eq (second name) t)))
         ;; (SETF symbol): the symbol's setf function word.
         (values (symbol-data (second name)) 7))
        (t (fail "invalid function name ~S" name))))

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
      (let ((name (package-name package)))
        `(:data ,(module-shared (string-data (format nil "kiln_pkg_~A" (mangle name)) name))
                ,+tag-general+))
      (nil-word)))

(defvar *module-symbols*)               ; symbols with static data, newest first

(defun symbol-data (sym)
  "Name of the static data object of the symbol SYM (not NIL or T)."
  (let* ((label (symbol-label sym))
         (obj (format nil "kiln_sym_~A" label)))
    (unless (gethash obj (kiln.kir::kmodule-defined *module*))
      (let ((name (string-data (format nil "kiln_name_~A" label) (symbol-name sym)))
            (undef (format nil "kiln_undef_~A" label))
            (undef-setf (format nil "kiln_undef_setf_~A" label)))
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
        (module-root obj 2)
        (module-root obj 3)
        (module-root obj 4)
        (module-root obj 6)
        (module-root obj 7)))
    obj))

(defun symbol-word (sym)
  (cond ((null sym) (nil-word))
        ((eq sym t) (t-word))
        (t `(:data ,(symbol-data sym) ,+tag-general+))))

(defconstant +most-positive-fixnum+ (1- (ash 1 62)))
(defconstant +most-negative-fixnum+ (- (ash 1 62)))

(defvar *constants*)                    ; host object -> data word

(defun constant-word (x)
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
     (signed-word (logior (ash (ldb (byte 32 0) (sb-kernel:single-float-bits x)) 32)
                          +single-float-tag+)))
    (double-float
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_double_")))
           (module-data label `(:words ,+kind-double+
                                       ,(signed-word
                                         (logior (ash (ldb (byte 32 0) (sb-kernel:double-float-high-bits x)) 32)
                                                 (sb-kernel:double-float-low-bits x)))))
           (setf (gethash x *constants*) `(:data ,label ,+tag-general+)))))
    (ratio
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_ratio_")))
           (module-data label `(:words ,+kind-ratio+ ,(constant-word (numerator x))
                                       ,(constant-word (denominator x))))
           (setf (gethash x *constants*) `(:data ,label ,+tag-general+)))))
    (character
     (logior (ash (char-code x) +character-shift+) +character-tag+))
    (string
     (or (gethash x *constants*)
         (setf (gethash x *constants*)
               `(:data ,(string-data (fresh-label "kiln_string_") x) ,+tag-general+))))
    (simple-vector
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_vector_")))
           (setf (gethash x *constants*) `(:data ,label ,+tag-general+))
           (module-data label `(:words ,(logior +kind-simple-vector+
                                                (ash (length x) +length-shift+))
                                       ,@(map 'list #'constant-word x)))
           `(:data ,label ,+tag-general+))))
    (cons
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_const_")))
           ;; Static conses: the GC neither moves nor scans them, and
           ;; they only point to static data.
           (setf (gethash x *constants*) `(:data ,label ,+tag-cons+))
           (module-data label `(:words ,+kind-cons+ ,(constant-word (car x))
                                       ,(constant-word (cdr x))))
           `(:data ,label ,+tag-cons+))))
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

(defvar *regions* '())

(defun handler ()
  "The handler block for calls here: that of the innermost region that has
one (bindings have none)."
  (let ((r (find-if #'region-handler *regions*)))
    (if r (kiln.kir::kblock-name (region-handler r)) :nil)))

(defun bname (b) (kiln.kir::kblock-name b))
(defun jump (b) (emit `(:jump ,(bname b))))
(defun br (cond then else) (emit `(:br ,cond ,(bname then) ,(bname else))))

(defun copy-to-var (operand &optional (kind :obj))
  (let ((v (new-var kind)))
    (emit `(:set ,v ,operand))
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
    (br `(:eq (:load ,f ,+fobj-entry+) (:addr ,(undefined-function-entry))) fatal lisp)
    (start-block lisp)
    (emit-lisp-call f (list (ash code +fixnum-shift+) obj))
    (jump fatal)
    (start-block fatal)
    (emit-fatal-error code obj)))

(defun emit-poll ()
  (let ((slow (new-block)) (cont (new-block)))
    (br `(:load :ctx ,+ctx-poll-flag+) slow cont)
    (start-block slow)
    (emit `(:call-rt ,(rt-poll) () (:ctx) ,(handler)))
    (jump cont)
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
                              :handler (if (member kind '(:bind :progv)) nil (new-block))
                              :outer *regions*)))
    (emit `(:store (:slot ,slot) ,+dyn-kind+ ,(ecase kind
                                                 (:catch +dyn-catch+)
                                                 (:unwind-protect +dyn-unwind-protect+)
                                                 (:exit-point +dyn-exit-point+)
                                                 (:bind +dyn-bind+)
                                                 (:progv +dyn-progv+))))
    (emit `(:store (:slot ,slot) ,+dyn-prev+ (:load :ctx ,+ctx-dynenv+)))
    (emit `(:store (:slot ,slot) ,+dyn-fp+ (:fp)))
    ;; Tag and pending value are GC roots: always initialize them.
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

(defvar *vars*)                         ; definition AST -> (kfunc . var)
(defvar *self*)                         ; variable holding the function object

(defun bind-var (definition operand)
  (let ((v (copy-to-var operand)))
    (setf (gethash definition *vars*) (cons *func* v))
    v))

(defun var-of (definition)
  (let ((entry (gethash definition *vars*)))
    (unless entry
      (fail "variable ~S is not bound" (ico:name definition)))
    (unless (eq (car entry) *func*)
      (fail "variable ~S referenced outside its function (not closure converted?)"
            (ico:name definition)))
    (cdr entry)))

;;; AST walking

(defun ast-children (ast)
  (unless (typep ast '(or ico:function-name-ast ico:variable-name-ast
                       ico:block-name-ast ico:tag-ast))
    (loop for designator in (ico:slot-designators ast)
          for cardinality = (first designator)
          when (member cardinality '(ico:? 1 *))
            append (let ((v (funcall (second designator) ast)))
                     (cond ((null v) '())
                           ((listp v) (remove-if-not (lambda (x) (typep x 'ico:ast)) v))
                           ((typep v 'ico:ast) (list v)))))))

(defun walk (function ast)
  "Calls FUNCTION on AST and its descendants, with a flag telling whether
the node is inside a LOCAL-FUNCTION-AST below the starting point. Some
slots link back to ancestors (a segment to its tagbody), so each node is
visited once."
  (let ((seen (make-hash-table :test 'eq)))
    (labels ((visit (ast inside)
               (unless (gethash ast seen)
                 (setf (gethash ast seen) t)
                 (funcall function ast inside)
                 (let ((inside (or inside (typep ast 'ico:local-function-ast))))
                   (dolist (child (ast-children ast))
                     (visit child inside))))))
      (visit ast nil))))

(defun exits-from-closure-p (asts predicate)
  "Does a node satisfying PREDICATE occur inside a nested function in ASTS?"
  (dolist (ast asts nil)
    (walk (lambda (node inside)
            (when (and inside (funcall predicate node))
              (return-from exits-from-closure-p t)))
          ast)))

;;; Lowering

(defgeneric lower (ast)
  (:documentation "Emits code for AST; returns an operand holding its value."))

(defmethod lower ((ast t))
  (fail "cannot compile ~S yet" (class-name (class-of ast))))

;;; Multiple values (docs/08 §5.3). LOWER-MV returns the operand of the
;;; primary value and the number of values: an integer, or a raw variable.
;;; Values after the first are in the context's transfer area (ctx.values)
;;; and must be consumed before the next call. Forms through which values
;;; pass define LOWER-MV, and their LOWER takes the primary value.

(defgeneric lower-mv (ast))

(defmethod lower-mv ((ast t))
  (values (lower ast) 1))

(defmacro define-mv-lowering (class (var) &body body)
  `(progn
     (defmethod lower-mv ((,var ,class)) ,@body)
     (defmethod lower ((,var ,class)) (values (lower-mv ,var)))))

(defun lower-progn-mv (asts)
  (if (null asts)
      (values (nil-value) 1)
      (progn
        (dolist (a (butlast asts))
          (lower a))
        (lower-mv (car (last asts))))))

(defun lower-progn (asts)
  (values (lower-progn-mv asts)))

(defun lower-or-nil (ast)
  (if ast (lower ast) (nil-value)))

(defun lower-or-nil-mv (ast)
  (if ast (lower-mv ast) (values (nil-value) 1)))

(define-mv-lowering ico:progn-ast (ast) (lower-progn-mv (ico:form-asts ast)))
(define-mv-lowering ico:locally-ast (ast) (lower-progn-mv (ico:form-asts ast)))
(define-mv-lowering ico:the-ast (ast) (lower-mv (ico:form-ast ast)))
;;; The expansions have already replaced the symbol macros.
(define-mv-lowering ico:symbol-macrolet-ast (ast) (lower-progn-mv (ico:form-asts ast)))

(define-mv-lowering ico:eval-when-ast (ast)
  ;; Not at top level: only :EXECUTE matters.
  (if (intersection (mapcar (lambda (s)
                              (let ((n (ico:name s))) (if (typep n 'cst:cst) (cst:raw n) n)))
                            (ico:situation-asts ast))
                    '(:execute eval))
      (lower-progn-mv (ico:form-asts ast))
      (values (nil-value) 1)))

(defun set-mv (r n v nv)
  "Assigns the values (V, NV) to the variables R and N."
  (emit `(:set ,r ,v))
  (emit `(:set ,n ,nv)))

(defmethod lower ((ast ico:literal-ast))
  (constant-object (ico:literal ast)))

(defmethod lower ((ast ico:quote-ast))
  (let ((object (ico:object-ast ast)))
    (constant-object
     (if (typep object 'ico:unparsed-form-ast)
         (let ((form (ico:form object)))
           (if (typep form 'cst:cst) (cst:raw form) form))
         (fail "unexpected QUOTE object ~S" object)))))

(defmethod lower ((ast ico:variable-reference-ast))
  (copy-to-var (var-of (ico:definition-ast ast))))

(defvar *constant-vars*)                ; variable definition -> constant

(define-mv-lowering ico:let-temporary-ast (ast)
  (let* ((binding (ico:binding-ast ast))
         (def (ico:variable-name-ast binding))
         (form (ico:form-ast binding)))
    ;; Remember temporaries bound to constants and never assigned, so that
    ;; (FUNCALL #'(SETF FDEFINITION) F NAME) from DEFUN sees the name.
    (multiple-value-bind (constant constantp) (constant-value form)
      (when (and constantp (not (assigned-in-p def (ico:form-asts ast))))
        (setf (gethash def *constant-vars*) constant)))
    (bind-var def (lower form))
    (lower-progn-mv (ico:form-asts ast))))

(defun assigned-in-p (definition asts)
  "Is the variable DEFINITION the target of a SETQ in ASTS?"
  (dolist (ast asts nil)
    (walk (lambda (node inside)
            (declare (ignore inside))
            (when (and (typep node 'ico:simple-setq-ast)
                       (eq (ico:definition-ast (ico:variable-name-ast node)) definition))
              (return-from assigned-in-p t)))
          ast)))

(defun constant-value (ast)
  "The value of AST if it is a constant (QUOTE, a literal, or a variable
known to hold one), and true; else NIL and NIL."
  (typecase ast
    (ico:quote-ast
     (let ((object (ico:object-ast ast)))
       (if (typep object 'ico:unparsed-form-ast)
           (let ((form (ico:form object)))
             (values (if (typep form 'cst:cst) (cst:raw form) form) t))
           (values nil nil))))
    (ico:literal-ast (values (ico:literal ast) t))
    (ico:variable-reference-ast
     (multiple-value-bind (value found) (gethash (ico:definition-ast ast) *constant-vars*)
       (values value found)))
    (t (values nil nil))))

(defmethod lower ((ast ico:simple-setq-ast))
  (let ((v (lower (ico:value-ast ast)))
        (var (var-of (ico:definition-ast (ico:variable-name-ast ast)))))
    (emit `(:set ,var ,v))
    (copy-to-var var)))

(define-mv-lowering ico:if-ast (ast)
  (let ((tv (lower (ico:test-ast ast)))
        (r (new-var)) (n (new-var :raw))
        (then-b (new-block)) (else-b (new-block)) (join (new-block)))
    (br `(:ne ,tv ,(nil-value)) then-b else-b)
    (start-block then-b)
    (multiple-value-call #'set-mv r n (lower-mv (ico:then-ast ast)))
    (jump join)
    (start-block else-b)
    (multiple-value-call #'set-mv r n (lower-or-nil-mv (ico:else-ast ast)))
    (jump join)
    (start-block join)
    (values r n)))

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

(defun emit-tls-slot (sym)
  "Raw address of the TLS slot of the symbol operand SYM (index 0 if it
has never been bound). The table does not move."
  (copy-to-var `(:add (:load :ctx ,+ctx-tls+) (:shl (:load ,sym ,+symbol-tls-index+) 2)) :raw))

(defun emit-symbol-value (sym)
  "Current value of the symbol operand SYM, possibly UNBOUND."
  (let ((addr (emit-tls-slot sym))
        (v (new-var))
        (global (new-block)) (join (new-block)))
    (emit `(:set ,v (:load ,addr 0)))
    (br `(:eq ,v ,+no-tls-value+) global join)
    (start-block global)
    (emit `(:set ,v (:load ,sym ,+symbol-value+)))
    (jump join)
    (start-block join)
    v))

(defun emit-set-symbol-value (sym value)
  (let ((addr (emit-tls-slot sym))
        (global (new-block)) (local (new-block)) (join (new-block)))
    (br `(:eq (:load ,addr 0) ,+no-tls-value+) global local)
    (start-block global)
    (emit `(:store ,sym ,+symbol-value+ ,value))
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

(defmethod lower ((ast ico:special-variable-reference-ast))
  (let ((name (ico:name ast)))
    (if (constant-symbol-p name)
        (constant-object name)
        (let* ((sym (constant-object name))
               (v (emit-symbol-value sym)))
          (emit-check-bound v sym)
          v))))

(defmethod lower ((ast ico:special-variable-setq-ast))
  (let ((name (ico:name (ico:variable-name-ast ast)))
        (v (copy-to-var (lower (ico:value-ast ast)))))
    (emit-set-symbol-value (constant-object name) v)
    v))

(defun emit-unbind (region)
  "Restores the value saved in the binding entry of REGION."
  (let ((s `(:slot ,(region-slot region))))
    (emit `(:store (:add (:load :ctx ,+ctx-tls+) (:shl (:load ,s ,+dyn-pend-target+) 2))
                   0 (:load ,s ,+dyn-pend-value+)))))

(define-mv-lowering ico:special-variable-bind-ast (ast)
  (let* ((binding (ico:binding-ast ast))
         (name (ico:name (ico:variable-name-ast binding)))
         (v (copy-to-var (lower (ico:form-ast binding))))
         (sym (constant-object name))
         (index (emit-tls-index sym)))
    (let* ((addr (copy-to-var `(:add (:load :ctx ,+ctx-tls+) (:shl ,index 2)) :raw))
           (region (establish-entry :bind sym))
           (s `(:slot ,(region-slot region)))
           (r (new-var)) (n (new-var :raw)))
      ;; No safepoint between linking the entry and filling it in.
      (emit `(:store ,s ,+dyn-pend-target+ ,index))
      (emit `(:store ,s ,+dyn-pend-value+ (:load ,addr 0)))
      (emit `(:store ,addr 0 ,v))
      (let ((*regions* (cons region *regions*)))
        (multiple-value-call #'set-mv r n (lower-progn-mv (ico:form-asts ast))))
      ;; Unbinding makes no calls, so the values in ctx.values survive.
      (emit-unbind region)
      (pop-entry region)
      (values r n))))

(defun emit-tls-index (sym)
  "Raw variable holding the TLS index of the symbol operand SYM, assigned
if needed (not a safepoint)."
  (let ((index (copy-to-var `(:load ,sym ,+symbol-tls-index+) :raw))
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
    (let ((pair (copy-to-var `(:load ,l ,+cons-car+))))
      (emit `(:store (:add (:load :ctx ,+ctx-tls+)
                           (:shl (:load (:load ,pair ,+cons-car+) ,+symbol-tls-index+) 2))
                     0 (:load ,pair ,+cons-cdr+))))
    (emit `(:set ,l (:load ,l ,+cons-cdr+)))
    (jump head)
    (start-block done)))

(define-mv-lowering ico:progv-ast (ast)
  (let* ((symbols (copy-to-var (lower (ico:symbols-ast ast))))
         (vals (copy-to-var (lower (ico:values-ast ast))))
         (saved (copy-to-var (nil-value))))
    (emit-check-proper-list symbols)
    (emit-check-proper-list vals)
    ;; Save the old values first, then link the entry, then bind: an
    ;; unwind then always finds the complete list.
    (let ((cur (copy-to-var symbols))
          (head (new-block)) (body (new-block)) (done (new-block)))
      (jump head)
      (start-block head)
      (br `(:eq ,cur ,(nil-value)) done body)
      (start-block body)
      (let* ((sym (copy-to-var `(:load ,cur ,+cons-car+)))
             (index (progn (emit-check-symbol sym) (emit-tls-index sym)))
             (old (copy-to-var `(:load (:add (:load :ctx ,+ctx-tls+) (:shl ,index 2)) 0))))
        (emit `(:set ,saved ,(emit-cons (emit-cons sym old) saved))))
      (emit `(:set ,cur (:load ,cur ,+cons-cdr+)))
      (jump head)
      (start-block done))
    (let ((region (establish-entry :progv saved))
          (cur (copy-to-var symbols)) (vcur (copy-to-var vals))
          (head (new-block)) (body (new-block)) (done (new-block))
          (r (new-var)) (n (new-var :raw)))
      (jump head)
      (start-block head)
      (br `(:eq ,cur ,(nil-value)) done body)
      (start-block body)
      ;; Symbols without a value become unbound.
      (let ((v (copy-to-var `(:select (:eq ,vcur ,(nil-value)) ,+unbound+ (:load ,vcur ,+cons-car+)))))
        (emit `(:store (:add (:load :ctx ,+ctx-tls+)
                             (:shl (:load (:load ,cur ,+cons-car+) ,+symbol-tls-index+) 2))
                       0 ,v)))
      (emit `(:set ,cur (:load ,cur ,+cons-cdr+)))
      (emit `(:set ,vcur (:select (:eq ,vcur ,(nil-value)) ,vcur (:load ,vcur ,+cons-cdr+))))
      (jump head)
      (start-block done)
      (let ((*regions* (cons region *regions*)))
        (multiple-value-call #'set-mv r n (lower-progn-mv (ico:form-asts ast))))
      (emit-unbind-progv region)
      (pop-entry region)
      (values r n))))

;;; LOAD-TIME-VALUE: the forms are evaluated by the module's init function
;;; just before the top-level form that contains them, and kept in static
;;; root cells.

(defvar *load-time-values*)             ; load-time-value AST -> cell data name

(defun emit-load-time-values (toplevel-ast)
  (let ((ltvs '()))
    (walk (lambda (node inside)
            (declare (ignore inside))
            (when (typep node 'ico:load-time-value-ast)
              (push node ltvs)))
          toplevel-ast)
    (dolist (ltv (nreverse ltvs))
      (let ((cell (fresh-label "kiln_ltv_")))
        (module-data cell `(:words 0))
        (module-root cell 0)
        (emit `(:store (:addr ,cell) 0 ,(lower (ico:form-ast ltv))))
        (setf (gethash ltv *load-time-values*) cell)))))

(defmethod lower ((ast ico:load-time-value-ast))
  (let ((cell (or (gethash ast *load-time-values*)
                  (fail "LOAD-TIME-VALUE not seen at top level"))))
    (copy-to-var `(:load (:addr ,cell) 0))))

;;; Allocation

(defun emit-alloc (bytes header)
  "Allocates an object; returns a raw variable holding its untagged
address. The payload is zeroed. No safepoint may occur before the address
is tagged and stored in an obj variable."
  (let ((p (new-var :raw)))
    (emit `(:call-rt ,(rt-alloc) (,p) (:ctx ,bytes ,header) ,(handler)))
    p))

(defun emit-cons (a b)
  ;; A and B are live across the allocation; as variables they are spilled
  ;; and reloaded around it (stack maps).
  (let* ((a (if (integerp a) a (copy-to-var a)))
         (b (if (integerp b) b (copy-to-var b)))
         (p (emit-alloc +cons-bytes+ +kind-cons+)))
    (emit `(:store ,p 8 ,a))
    (emit `(:store ,p 16 ,b))
    (copy-to-var `(:add ,p ,+tag-cons+))))

;;; Cells (assignment conversion): a cell is a cons whose car is the value.

(defmethod lower ((ast ico:make-cell-ast))
  (emit-cons (lower (ico:form-ast ast)) (nil-value)))

(defmethod lower ((ast ico:read-cell-ast))
  (copy-to-var `(:load ,(lower (ico:cell-ast ast)) ,+cons-car+)))

(defmethod lower ((ast ico:write-cell-ast))
  (let ((cell (lower (ico:cell-ast ast)))
        (v (copy-to-var (lower (ico:form-ast ast)))))
    (emit `(:store ,cell ,+cons-car+ ,v))
    v))

;;; Functions

(defstruct (parsed-lambda-list (:conc-name ll-))
  (required '())   ; variable definitions
  (optional '())   ; (variable supplied-p) definitions
  (rest nil)       ; variable definition
  (keys '())       ; (variable supplied-p keyword)
  (key-p nil)
  (allow-other-keys nil))

(defun parse-lambda-list (lambda-list)
  "Parameters of a lambda list after LEXIFY-LAMBDA-LIST: every optional
and key parameter has a supplied-p variable, and default forms are
evaluated in the body, so the init forms here are all NIL."
  (let ((ll (make-parsed-lambda-list)))
    (when lambda-list
      (dolist (section (ast-children lambda-list))
        (typecase section
          (ico:required-section-ast
           (setf (ll-required ll) (mapcar #'ico:name-ast (ico:parameter-asts section))))
          (ico:optional-section-ast
           (setf (ll-optional ll)
                 (mapcar (lambda (p) (list (ico:name-ast p) (ico:supplied-p-parameter-ast p)))
                         (ico:parameter-asts section))))
          (ico:rest-section-ast
           (setf (ll-rest ll) (ico:name-ast (ico:parameter-ast section))))
          (ico:key-section-ast
           (setf (ll-key-p ll) t
                 (ll-allow-other-keys ll) (and (ico:allow-other-keys-ast section) t)
                 (ll-keys ll)
                 (mapcar (lambda (p)
                           (let ((k (ico:keyword-ast p)))
                             (list (ico:name-ast p) (ico:supplied-p-parameter-ast p)
                                   (if (typep k 'ico:literal-ast) (ico:literal k) (ico:name k)))))
                         (ico:parameter-asts section))))
          (t (fail "~S in lambda lists is not supported yet"
                   (class-name (class-of section)))))))
    ll))

(defun arg-operand (args i)
  "Argument I (an integer) on function entry: ARGS hold the register
arguments; later ones are in the transfer area."
  (if (< i +reg-args+)
      (nth i args)
      `(:load :ctx ,(+ +ctx-values+ (* 8 (- i +reg-args+))))))

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
    (br `(:and (:eq (:load ,cur ,+cons-car+) ,(constant-object keyword))
               (:eq ,found ,(nil-value)))
        hit next)
    (start-block hit)
    (emit `(:set ,value (:load (:load ,cur ,+cons-cdr+) ,+cons-car+)))
    (emit `(:set ,supplied ,(t-value)))
    (emit `(:set ,found ,(t-value)))
    (jump next)
    (start-block next)
    (emit `(:set ,cur (:load (:load ,cur ,+cons-cdr+) ,+cons-cdr+)))
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
      (br `(:eq (:load ,c ,+cons-cdr+) ,(nil-value)) odd step)
      (start-block step)
      (emit `(:set ,c (:load (:load ,c ,+cons-cdr+) ,+cons-cdr+)))
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
    (let ((key (copy-to-var `(:load ,cur ,+cons-car+))))
      (dolist (k (cons :allow-other-keys keywords))
        (let ((no (new-block)))
          (br `(:eq ,key ,(constant-object k)) next no)
          (start-block no)))
      (jump unknown)
      (start-block unknown)
      (emit-error +err-unknown-keyword+ key))
    (start-block next)
    (emit `(:set ,cur (:load (:load ,cur ,+cons-cdr+) ,+cons-cdr+)))
    (jump head)
    (start-block done)))

(defun emit-entry (ll)
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
      (let ((list (emit-rest-list args npos)))
        (when (ll-rest ll)
          (bind-var (ll-rest ll) list))
        (when (ll-key-p ll)
          (emit-check-keywords list (mapcar #'third (ll-keys ll)) (ll-allow-other-keys ll))
          (loop for (p supplied keyword) in (ll-keys ll)
                do (let ((v (bind-var p (nil-value)))
                         (s (bind-var supplied (nil-value))))
                     (emit-find-key list keyword v s))))))))

(defun compile-function (name lambda-list body)
  "Builds the KIR function NAME. LAMBDA-LIST is a parsed lambda list."
  (let ((*regions* '()))
    (with-function (name)
      (let ((*self* (copy-to-var :self)))
        (emit-entry lambda-list)
        (emit-poll)
        (multiple-value-bind (v n) (lower-progn-mv body)
          (emit `(:return ,v ,n)))))))

(defun static-env-size (name-definition asts)
  "Number of env words of the function named by NAME-DEFINITION, from
the SET-STATIC-ENVIRONMENT-AST for it in ASTS (0 if there is none)."
  (dolist (ast asts 0)
    (walk (lambda (node inside)
            (declare (ignore inside))
            (when (and (typep node 'ico:set-static-environment-ast)
                       (eq (ico:definition-ast (ico:function-reference-ast node))
                           name-definition))
              (return-from static-env-size (length (ico:form-asts node)))))
          ast)))

(define-mv-lowering ico:labels-ast (ast)
  (let ((functions
          (loop for lf in (ico:binding-asts ast)
                for def = (ico:name-ast lf)
                for label = (fresh-label (format nil "kiln_f_~A_"
                                                 (mangle (princ-to-string (ico:name def)))))
                do (compile-function label
                                     (parse-lambda-list (ico:lambda-list-ast lf))
                                     (ico:form-asts lf))
                collect (list def label (static-env-size def (ico:form-asts ast))))))
    (loop for (def label n) in functions
          do (if (zerop n)
                 (let ((data (format nil "~A_fobj" label)))
                   (module-data data `(:words ,+kind-function+ (:func ,label)))
                   (bind-var def `(:addr ,data ,+tag-general+)))
                 (let ((p (emit-alloc (+ 16 (* 8 n))
                                      (logior +kind-function+ (ash n +length-shift+)))))
                   (emit `(:store ,p 8 (:addr ,label)))
                   (bind-var def `(:add ,p ,+tag-general+)))))
    (lower-progn-mv (ico:form-asts ast))))

(defmethod lower ((ast ico:set-static-environment-ast))
  (let ((values (mapcar (lambda (a) (copy-to-var (lower a))) (ico:form-asts ast)))
        (f (lower (ico:function-reference-ast ast))))
    (loop for v in values
          for i from 0
          do (emit `(:store ,f ,(+ +fobj-env+ (* 8 i)) ,v)))
    (nil-value)))

(defmethod lower ((ast ico:static-environment-ast))
  (copy-to-var *self*))

(defmethod lower ((ast ico:read-static-environment-ast))
  (let ((env (lower (ico:static-environment-ast ast)))
        (index (ico:literal (ico:index-ast ast))))
    (copy-to-var `(:load ,env ,(+ +fobj-env+ (* 8 index))))))

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
    (emit `(:set ,r (:load ,r ,+symbol-function+)))
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
  "Calls FOBJ with the argument operands VALS. Arguments beyond the
register arguments go into the context's transfer area, stored after all
arguments have been evaluated; the callee reads them before its first
safepoint (docs/08 §4)."
  (when (> (length vals) (+ +reg-args+ +values-max+))
    (fail "calls with more than ~D arguments are not supported"
          (+ +reg-args+ +values-max+)))
  (let ((v0 (new-var)) (nv (new-var :raw))
        (entry (copy-to-var `(:load ,fobj ,+fobj-entry+) :raw)))
    (loop for v in (nthcdr +reg-args+ vals)
          for i from 0
          do (emit `(:store :ctx ,(+ +ctx-values+ (* 8 i)) ,v)))
    (emit `(:call-lisp ,v0 ,nv ,entry
                       (:ctx ,fobj ,(length vals) ,@(subseq vals 0 (min (length vals) +reg-args+)))
                       ,(handler)))
    (values v0 nv)))

(defun function-cell-value (name)
  (multiple-value-bind (data index) (function-cell-data name)
    (copy-to-var `(:load (:addr ,data) ,(* 8 index)))))

(defun lower-args (asts)
  (mapcar (lambda (a) (copy-to-var (lower a))) asts))

(defparameter *type-predicates*
  '((cons . consp) (symbol . symbolp) (list . listp) (null . null) (atom . atom)
    (integer . integerp) (number . numberp) (character . characterp)
    (function . functionp) (keyword . keywordp) (string . stringp)
    (simple-string . stringp) (simple-vector . simple-vector-p)
    (fixnum . kiln.kernel::fixnump) (bignum . kiln.kernel::bignump)
    (float . floatp) (real . realp) (rational . rationalp)
    (single-float . kiln.kernel::single-float-p)
    (double-float . kiln.kernel::double-float-p))
  "Atomic types whose TYPEP is a call to a predicate (docs/09 §10).")

(defun call-ast (name arg-asts)
  (make-instance 'ico:application-ast
                 :function-name-ast (make-instance 'ico:global-function-name-reference-ast
                                                   :name name)
                 :argument-asts arg-asts))

(defun long-call-ast (name arg-asts)
  "An AST equivalent to the call of NAME (LIST, LIST*, VECTOR, NCONC or
APPEND) with ARG-ASTS, whose calls have few enough arguments: (LIST* a1
... an REST) in chunks, (COERCE list 'SIMPLE-VECTOR) for VECTOR, nested
calls for the associative NCONC and APPEND."
  (let ((chunk 60))
    (labels ((list-ast (asts tail-ast)
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
        (list (list-ast arg-asts (make-instance 'ico:literal-ast :literal nil)))
        (list* (list-ast (butlast arg-asts) (car (last arg-asts))))
        (vector (call-ast 'coerce
                          (list (list-ast arg-asts (make-instance 'ico:literal-ast :literal nil))
                                (make-instance 'ico:literal-ast :literal 'simple-vector))))))))

(defun lower-global-call (name arg-asts)
  (when (and (eq name 'typep) (= (length arg-asts) 2))
    (multiple-value-bind (type constantp) (constant-value (second arg-asts))
      (let ((predicate (and constantp (cdr (assoc type *type-predicates*)))))
        (when predicate
          (return-from lower-global-call
            (lower-global-call predicate (list (first arg-asts))))))))
  (if (and (eq name 'funcall)
           arg-asts
           (typep (first arg-asts) 'ico:global-function-name-reference-ast))
      ;; (FUNCALL #'F ...) is a call to F.
      (lower-global-call (ico:name (first arg-asts)) (rest arg-asts))
      (let ((primop (and (eq name 'kiln.sys:%primop) (primop-name arg-asts)))
            (constant-name (and (equal name '(setf fdefinition))
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
             (multiple-value-bind (data index) (function-cell-data constant-name)
               (emit `(:store (:addr ,data) ,(* 8 index) ,f)))
             f))
          (primop
           (funcall primop (lower-args (rest arg-asts))))
          ((and (> (length arg-asts) (+ +reg-args+ +values-max+))
                (member name '(list list* vector nconc append)))
           ;; Calls are limited to +REG-ARGS+ + +VALUES-MAX+ arguments:
           ;; build long lists in chunks, and vectors from them.
           (lower (long-call-ast name arg-asts)))
          (t
           (when (> (length arg-asts) (+ +reg-args+ +values-max+))
             (fail "the call to ~S has ~D arguments; at most ~D are supported"
                   name (length arg-asts) (+ +reg-args+ +values-max+)))
           (let ((primitive (gethash name *primitives*))
                 (vals (lower-args arg-asts)))
             (if primitive
                 (funcall primitive vals)
                 (emit-lisp-call (function-cell-value name) vals))))))))

(defun quoted-constant (ast)
  (values (constant-value ast)))

(defun primop-name (arg-asts)
  "The primop of a %PRIMOP call: its first argument must be a keyword."
  (let ((op (first arg-asts)))
    (unless (and (typep op 'ico:literal-ast) (keywordp (ico:literal op)))
      (fail "%PRIMOP needs a keyword as its first argument"))
    (or (gethash (ico:literal op) *primops*)
        (fail "unknown primop ~S" (ico:literal op)))))

(define-mv-lowering ico:application-ast (ast)
  (let ((fn (ico:function-name-ast ast)))
    (multiple-value-bind (v n)
        (etypecase fn
          (ico:global-function-name-reference-ast
           (lower-global-call (ico:name fn) (ico:argument-asts ast)))
          ;; A local function: the variable holds its function object (LABELS).
          (ico:variable-reference-ast
           (let ((vals (lower-args (ico:argument-asts ast))))
             (emit-lisp-call (lower fn) vals))))
      ;; Primitives that return one value return no count.
      (values v (or n 1)))))

(defmethod lower ((ast ico:global-function-name-reference-ast))
  (function-cell-value (ico:name ast)))

;;; BLOCK and RETURN-FROM

(defstruct exit-info
  func            ; KIR function that contains the block or tagbody
  regions         ; regions outside it (targets of local exits)
  exit            ; BLOCK: exit block
  result          ; BLOCK: result variable
  count           ; BLOCK: raw variable, number of values
  block)          ; TAGBODY: KIR block of the tag

(defvar *exits*)                        ; block/tag definition AST -> exit-info

(defun emit-exit-token ()
  "A fresh object identifying one activation of a block or tagbody that a
closure may exit to. The closure holds it rather than the entry's stack
address: heap objects must not point into frames (C5), and a token cannot
be confused with a later activation at the same address."
  (emit-cons (nil-value) (nil-value)))

(define-mv-lowering ico:block-with-variable-ast (ast)
  (let* ((def (ico:name-ast ast))
         (body (ico:form-asts ast))
         (nonlocal (exits-from-closure-p
                    body
                    (lambda (node)
                      (and (typep node 'ico:return-from-with-variable-ast)
                           (eq (ico:block-name-definition-ast (ico:name-ast node)) def)))))
         (exit (new-block)) (r (new-var)) (n (new-var :raw)))
    (setf (gethash def *exits*)
          (make-exit-info :func *func* :regions *regions* :exit exit :result r :count n))
    (if (not nonlocal)
        (progn
          (bind-var (ico:variable-definition-ast ast) 0)
          (multiple-value-call #'set-mv r n (lower-progn-mv body))
          (jump exit))
        (let* ((token (emit-exit-token))
               (region (establish-entry :exit-point token))
               (land (new-block)))
          (bind-var (ico:variable-definition-ast ast) token)
          (let ((*regions* (cons region *regions*)))
            (multiple-value-call #'set-mv r n (lower-progn-mv body)))
          (pop-entry region)
          (jump exit)
          (start-dispatch region land)
          ;; The runtime has unlinked the entry.
          (start-block land)
          (multiple-value-call #'set-mv r n (emit-landed-values))
          (jump exit)))
    (start-block exit)
    (values r n)))

(defmethod lower ((ast ico:return-from-with-variable-ast))
  (let ((info (gethash (ico:block-name-definition-ast (ico:name-ast ast)) *exits*)))
    (if (eq (exit-info-func info) *func*)
        (multiple-value-bind (v n) (lower-or-nil-mv (ico:form-ast ast))
          (let ((r (exit-info-result info)) (rn (exit-info-count info))
                (target (exit-info-regions info)))
            (if (loop for rs on *regions*
                      until (eq rs target)
                      thereis (eq (region-kind (first rs)) :unwind-protect))
                ;; Cleanups run on the way out: keep the values safe.
                (let ((saved (emit-save-values v n)))
                  (emit-local-exit target)
                  (multiple-value-call #'set-mv r rn (emit-restore-values saved n)))
                (progn
                  (set-mv r rn v n)
                  (emit-local-exit target)))
            (jump (exit-info-exit info))))
        (multiple-value-bind (v packed)
            (multiple-value-call #'emit-unwind-values (lower-or-nil-mv (ico:form-ast ast)))
          (let ((token (lower (ico:variable-reference-ast ast))))
            (emit `(:call-rt ,(rt-exit-to) () (:ctx ,token ,v ,packed) ,(handler))))
          (emit '(:trap))))
    (nil-value)))

;;; TAGBODY and GO

(defmethod lower ((ast ico:tagbody-with-variable-ast))
  (let* ((segments (ico:segment-asts ast))
         (defs (mapcar #'ico:tag-ast segments)) ; NIL for an untagged first segment
         (nonlocal (exits-from-closure-p
                    segments
                    (lambda (node)
                      (and (typep node 'ico:go-with-variable-ast)
                           (member (ico:tag-definition-ast (ico:tag-ast node)) defs)))))
         (blocks (mapcar (lambda (s) (declare (ignore s)) (new-block)) segments))
         (exit (new-block))
         (token (and nonlocal (emit-exit-token)))
         (region (and nonlocal (establish-entry :exit-point token)))
         (inner (if region (cons region *regions*) *regions*)))
    (bind-var (ico:variable-definition-ast ast) (or token 0))
    (loop for def in defs
          for b in blocks
          when def
            do (setf (gethash def *exits*)
                     (make-exit-info :func *func* :regions inner :block b)))
    (let ((*regions* inner))
      (when blocks (jump (first blocks)))
      (loop for segment in segments
            for (b . rest) on blocks
            do (start-block b)
               (when (ico:tag-ast segment) (emit-poll))
               (dolist (s (ico:statement-asts segment)) (lower s))
               (jump (if rest (first rest) exit))))
    (unless blocks (jump exit))
    (when region
      (let ((land (new-block)))
        (start-dispatch region land)
        ;; A GO from a closure: the runtime has unlinked the entry, but
        ;; control stays inside the tagbody, so link it again. The payload
        ;; is the index of the tag's segment, as a fixnum.
        (start-block land)
        (emit `(:store :ctx ,+ctx-dynenv+ (:slot ,(region-slot region))))
        (loop for b in blocks
              for i from 0
              do (let ((next (new-block)))
                   (br `(:eq :exn1 ,(ash i +fixnum-shift+)) b next)
                   (start-block next)))
        (emit '(:trap))))
    (start-block exit)
    (when region (pop-entry region))
    (nil-value)))

(defmethod lower ((ast ico:go-with-variable-ast))
  (let* ((def (ico:tag-definition-ast (ico:tag-ast ast)))
         (info (gethash def *exits*)))
    (if (eq (exit-info-func info) *func*)
        (progn
          (emit-local-exit (exit-info-regions info))
          (jump (exit-info-block info)))
        (let* ((segments (ico:segment-asts (ico:tagbody-ast (ico:segment-ast def))))
               (index (position (ico:segment-ast def) segments))
               (token (lower (ico:variable-reference-ast ast))))
          (emit `(:call-rt ,(rt-exit-to) () (:ctx ,token ,(ash index +fixnum-shift+) 0) ,(handler)))
          (emit '(:trap))))
    (nil-value)))

;;; CATCH, THROW, UNWIND-PROTECT

(define-mv-lowering ico:catch-ast (ast)
  (let* ((tv (lower (ico:tag-form-ast ast)))
         (r (new-var)) (n (new-var :raw)) (exit (new-block)) (land (new-block))
         (region (establish-entry :catch tv)))
    (let ((*regions* (cons region *regions*)))
      (multiple-value-call #'set-mv r n (lower-progn-mv (ico:form-asts ast))))
    (pop-entry region)
    (jump exit)
    (start-dispatch region land)
    ;; The runtime has unlinked the entry.
    (start-block land)
    (multiple-value-call #'set-mv r n (emit-landed-values))
    (jump exit)
    (start-block exit)
    (values r n)))

(defmethod lower ((ast ico:throw-ast))
  (let ((tv (copy-to-var (lower (ico:tag-form-ast ast)))))
    (multiple-value-bind (vv packed)
        (multiple-value-call #'emit-unwind-values (lower-mv (ico:form-ast ast)))
      (emit `(:call-rt ,(rt-throw) () (:ctx ,tv ,vv ,packed) ,(handler))))
    (emit '(:trap))
    (nil-value)))

(define-mv-lowering ico:unwind-protect-ast (ast)
  (let* ((cleanup (ico:form-asts ast))
         (r (new-var)) (n (new-var :raw)) (cont (new-block)) (land (new-block))
         (region (establish-entry :unwind-protect)))
    (setf (region-cleanup region) cleanup)
    (multiple-value-bind (v nv)
        (let ((*regions* (cons region *regions*)))
          (lower-mv (ico:protected-form-ast ast)))
      (pop-entry region)
      (if cleanup
          (let ((saved (emit-save-values v nv)))
            (lower-progn cleanup)
            (multiple-value-call #'set-mv r n (emit-restore-values saved nv)))
          (set-mv r n v nv)))
    (jump cont)
    (start-dispatch region land)
    ;; Entered by an unwind passing through: the entry stays linked, marked
    ;; as running its cleanup, with the pending target in it. The cleanup
    ;; runs in a region that only unlinks it on a local exit; calls in it
    ;; use the outer handler.
    (start-block land)
    (let ((*regions* (cons (make-region :kind :cleanup-running :slot (region-slot region)
                                        :handler (let ((outer (find-if #'region-handler *regions*)))
                                                   (and outer (region-handler outer)))
                                        :outer *regions*)
                           *regions*)))
      (lower-progn cleanup))
    (emit `(:call-rt ,(rt-continue-unwind) () (:ctx (:slot ,(region-slot region))) ,(handler)))
    (emit '(:trap))
    (start-block cont)
    (values r n)))

;;; Module

(defun symbol-table-cell ()
  (format nil "kiln_symtab_~A" *module-label*))

(defun emit-note-symbol-table ()
  "Pushes the module's symbol table (SYMBOL-TABLE-LITERAL, stored in a
static cell when the module is complete) onto
KILN.KERNEL::*MODULE-SYMBOL-TABLES*, then calls
KILN.KERNEL::%REGISTER-MODULE-SYMBOLS if the package system has defined
it (docs/10 §12). Nothing binds the variable while modules are loaded, so
its global value is used directly."
  (let* ((sym (copy-to-var (word-operand (symbol-word 'kiln.kernel::*module-symbol-tables*))))
         (old (new-var))
         (unbound (new-block)) (join (new-block)))
    (emit `(:set ,old (:load ,sym ,+symbol-value+)))
    (br `(:eq ,old ,+unbound+) unbound join)
    (start-block unbound)
    (emit `(:set ,old ,(nil-value)))
    (jump join)
    (start-block join)
    (let ((table (copy-to-var `(:load (:addr ,(symbol-table-cell)) 0))))
      (emit `(:store ,sym ,+symbol-value+ ,(emit-cons table old)))))
  (let ((f (function-cell-value 'kiln.kernel::%register-module-symbols))
        (call (new-block)) (join (new-block)))
    (br `(:eq (:load ,f ,+fobj-entry+) (:addr ,(undefined-function-entry))) join call)
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
  (let ((*regions* '()))
    (with-function (name)
      (let ((*self* (copy-to-var :self)))
        (emit-poll)
        (dolist (ast asts)
          (emit-load-time-values ast)
          (lower ast))
        (emit `(:return ,(nil-value) 1)))))
  (let ((fobj (format nil "~A_fobj" name)))
    (module-data fobj `(:words ,+kind-function+ (:func ,name)))
    `(:data ,fobj ,+tag-general+)))

(defun compile-toplevel-function (asts)
  "The module's init function: registers the module's symbols, then runs
the top-level forms in order, in chunks."
  (let ((chunks (loop for i from 0
                      for rest on asts by (lambda (l) (nthcdr *toplevel-chunk-size* l))
                      collect (compile-toplevel-chunk
                               (format nil "kiln_toplevel_~A_~D" *module-label* i)
                               (subseq rest 0 (min *toplevel-chunk-size* (length rest)))))))
    (let ((*regions* '()))
      (with-function ((format nil "kiln_toplevel_~A" *module-label*))
        (let ((*self* (copy-to-var :self)))
          (emit-poll)
          (emit-note-symbol-table)
          (dolist (fobj chunks)
            (emit-lisp-call (copy-to-var (word-operand fobj)) '()))
          (emit `(:return ,(nil-value) 1)))))))

;;; The module's symbol table, for the package system (docs/10 §12): a
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
  (if (eq package (find-package '#:kiln-user))
      '("CL-USER")
      (package-nicknames package)))

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
                                    (loop for u in (package-use-list p)
                                          when (member u known)
                                            collect (target-package-name u))
                                    (package-entries p symbols)))
              'simple-vector))))

(defun compile-module (asts module-name &key session defined-packages extra-symbols)
  "Compiles the simplified top-level ASTS into a KIR module. The module's
symbol table describes its symbols, the EXTRA-SYMBOLS and the symbols of
the DEFINED-PACKAGES (host packages its DEFPACKAGE forms created) for the
package system (docs/10 §12)."
  (let ((*module* (make-kmodule module-name))
        (*module-label* (mangle module-name))
        (*counter* 0)
        (*vars* (make-hash-table :test 'eq))
        (*exits* (make-hash-table :test 'eq))
        (*constants* (make-hash-table :test 'eql))
        (*constant-vars* (make-hash-table :test 'eq))
        (*module-symbols* '()))
    (let ((*load-time-values* (make-hash-table :test 'eq)))
      (compile-toplevel-function asts))
    (dolist (sym extra-symbols)
      (symbol-word sym))
    (dolist (package defined-packages)
      (do-symbols (sym package)
        (when (eq (nth-value 1 (find-symbol (symbol-name sym) package)) :external)
          (symbol-word sym))))
    (module-data (symbol-table-cell)
                 `(:words ,(constant-word (symbol-table-literal
                                           *module-symbols* session defined-packages))))
    (let ((init (format nil "kiln_toplevel_~A" *module-label*)))
      (module-data (format nil "~A_fobj" init) `(:words ,+kind-function+ (:func ,init)))
      (module-init (format nil "~A_fobj" init)))
    *module*))
