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
(defvar *primitive-arity* (make-hash-table :test 'equal)
  "Function name -> number of parameters of its wrapper function.")
(defvar *primitive-functions*)          ; name -> wrapper function object operand


(defun fresh-label (prefix)
  (format nil "~A~D" prefix (incf *counter*)))

;;; Runtime functions

(defun rt-print () (module-import-func "kiln_rt_print" 2 1))
(defun rt-error () (module-import-func "kiln_rt_error" 3 0 :unwinds :noreturn))
(defun rt-poll () (module-import-func "kiln_rt_poll" 1 0 :unwinds))
(defun rt-throw () (module-import-func "kiln_rt_throw" 3 0 :unwinds :noreturn))
(defun rt-exit-to () (module-import-func "kiln_rt_exit_to" 3 0 :unwinds :noreturn))
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
      (let ((*regions* '()))
        (with-function (name)
          (emit-error +err-undefined-function+ `(:load :self ,+fobj-env+)))))
    name))

(defun function-cell-data (name)
  "Data object and word index of the global function cell of NAME."
  (cond ((symbolp name)
         (values (symbol-data name) 3))
        ((and (consp name) (eq (first name) 'setf) (symbolp (second name)))
         (let ((label (format nil "kiln_setf_~A" (symbol-label (second name)))))
           (unless (gethash label (kiln.kir::kmodule-defined *module*))
             (let ((undef (format nil "kiln_undef_setf_~A" (symbol-label (second name)))))
               (module-data undef `(:words ,(logior +kind-function+ (ash 1 +length-shift+))
                                           (:func ,(undefined-function-entry))
                                           ,(symbol-word (second name))))
               (module-data label `(:words (:data ,undef ,+tag-general+)))
               (module-root label 0)))
           (values label 0)))
        (t (fail "invalid function name ~S" name))))

(defun symbol-data (sym)
  "Name of the static data object of the symbol SYM (not NIL or T)."
  (let* ((label (symbol-label sym))
         (obj (format nil "kiln_sym_~A" label)))
    (unless (gethash obj (kiln.kir::kmodule-defined *module*))
      (let ((name (symbol-name sym))
            (str (format nil "kiln_str_~A" label))
            (undef (format nil "kiln_undef_~A" label)))
        (module-data str `(:bytes ,name))
        (module-data undef `(:words ,(logior +kind-function+ (ash 1 +length-shift+))
                                    (:func ,(undefined-function-entry))
                                    (:data ,obj ,+tag-general+)))
        (module-data obj `(:words ,+kind-symbol+ (:data ,str) ,(length name)
                                  (:data ,undef ,+tag-general+)
                                  ,(if (keywordp sym) `(:data ,obj ,+tag-general+) +unbound+)
                                  0))
        (module-root obj 3)
        (module-root obj 4)))
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
     (unless (<= +most-negative-fixnum+ x +most-positive-fixnum+)
       (fail "integer ~D is outside the fixnum range (no bignums yet)" x))
     (ash x +fixnum-shift+))
    (symbol (symbol-word x))
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

(defun emit-error (code obj)
  (emit `(:call-rt ,(rt-error) () (:ctx ,code ,obj) ,(handler)))
  (emit '(:trap)))

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
             (when (eq (region-kind r) :bind)
               (emit-unbind r))
             (pop-entry r)
             (when (eq (region-kind r) :unwind-protect)
               (let ((*regions* (region-outer r)))
                 (lower-progn (region-cleanup r)))))))

(defun establish-entry (kind &optional (tag 0))
  "Links a new dynamic-environment entry into the context. Returns its
region; code inside it runs with the region pushed on *REGIONS*."
  (let* ((slot (new-slot +dynentry-size+))
         (region (make-region :kind kind :slot slot
                              :handler (if (eq kind :bind) nil (new-block))
                              :outer *regions*)))
    (emit `(:store (:slot ,slot) ,+dyn-kind+ ,(ecase kind
                                                 (:catch +dyn-catch+)
                                                 (:unwind-protect +dyn-unwind-protect+)
                                                 (:exit-point +dyn-exit-point+)
                                                 (:bind +dyn-bind+))))
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
    (br `(:eq :exn0 (:slot ,(region-slot region))) land outer)
    (start-block outer)
    (let ((h (let ((*regions* (region-outer region))) (handler))))
      (if (eq h :nil)
          (emit '(:trap))
          (emit `(:jump ,h))))))

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

(defun lower-progn (asts)
  (if (null asts)
      (nil-value)
      (let (v)
        (dolist (a asts v)
          (setf v (lower a))))))

(defun lower-or-nil (ast)
  (if ast (lower ast) (nil-value)))

(defmethod lower ((ast ico:progn-ast)) (lower-progn (ico:form-asts ast)))
(defmethod lower ((ast ico:locally-ast)) (lower-progn (ico:form-asts ast)))
(defmethod lower ((ast ico:the-ast)) (lower (ico:form-ast ast)))

(defmethod lower ((ast ico:eval-when-ast))
  ;; Not at top level: only :EXECUTE matters.
  (if (intersection (mapcar (lambda (s)
                              (let ((n (ico:name s))) (if (typep n 'cst:cst) (cst:raw n) n)))
                            (ico:situation-asts ast))
                    '(:execute eval))
      (lower-progn (ico:form-asts ast))
      (nil-value)))

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

(defmethod lower ((ast ico:let-temporary-ast))
  (let ((binding (ico:binding-ast ast)))
    (bind-var (ico:variable-name-ast binding) (lower (ico:form-ast binding)))
    (lower-progn (ico:form-asts ast))))

(defmethod lower ((ast ico:simple-setq-ast))
  (let ((v (lower (ico:value-ast ast)))
        (var (var-of (ico:definition-ast (ico:variable-name-ast ast)))))
    (emit `(:set ,var ,v))
    (copy-to-var var)))

(defmethod lower ((ast ico:if-ast))
  (let ((tv (lower (ico:test-ast ast)))
        (r (new-var))
        (then-b (new-block)) (else-b (new-block)) (join (new-block)))
    (br `(:ne ,tv ,(nil-value)) then-b else-b)
    (start-block then-b)
    (emit `(:set ,r ,(lower (ico:then-ast ast))))
    (jump join)
    (start-block else-b)
    (emit `(:set ,r ,(lower-or-nil (ico:else-ast ast))))
    (jump join)
    (start-block join)
    r))

;;; Special variables: TLS-index scheme (C1, rust/kiln-rt/src/special.rs).
;;; A symbol's value in a context is its slot in the context's TLS table if
;;; that holds a value, else its global value. Slot 0 is always empty, so a
;;; symbol that was never bound (index 0) needs no test.

(defun rt-tls-index () (module-import-func "kiln_rt_tls_index" 2 1))

(defun emit-tls-slot (sym)
  "Raw address of the TLS slot of the symbol operand SYM (index 0 if it
has never been bound). The table does not move."
  (copy-to-var `(:add (:load :ctx ,+ctx-tls+) (:shl (:load ,sym ,+symbol-tls-index+) 3)) :raw))

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
    (emit `(:store (:add (:load :ctx ,+ctx-tls+) (:shl (:load ,s ,+dyn-pend-target+) 3))
                   0 (:load ,s ,+dyn-pend-value+)))))

(defmethod lower ((ast ico:special-variable-bind-ast))
  (let* ((binding (ico:binding-ast ast))
         (name (ico:name (ico:variable-name-ast binding)))
         (v (copy-to-var (lower (ico:form-ast binding))))
         (sym (constant-object name))
         (index (copy-to-var `(:load ,sym ,+symbol-tls-index+) :raw))
         (assign (new-block)) (have (new-block)))
    ;; Assign an index on first binding (not a safepoint).
    (br `(:eq ,index 0) assign have)
    (start-block assign)
    (emit `(:call-rt ,(rt-tls-index) (,index) (:ctx ,sym) :nil))
    (jump have)
    (start-block have)
    (let* ((addr (copy-to-var `(:add (:load :ctx ,+ctx-tls+) (:shl ,index 3)) :raw))
           (region (establish-entry :bind sym))
           (s `(:slot ,(region-slot region)))
           (r (new-var)))
      ;; No safepoint between linking the entry and filling it in.
      (emit `(:store ,s ,+dyn-pend-target+ ,index))
      (emit `(:store ,s ,+dyn-pend-value+ (:load ,addr 0)))
      (emit `(:store ,addr 0 ,v))
      (let ((*regions* (cons region *regions*)))
        (emit `(:set ,r ,(lower-progn (ico:form-asts ast)))))
      (emit-unbind region)
      (pop-entry region)
      r)))

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

(defun lambda-list-parameters (lambda-list)
  "Definitions of the required parameters of LAMBDA-LIST."
  (when lambda-list
    (dolist (child (ast-children lambda-list))
      (unless (typep child 'ico:required-section-ast)
        (fail "~S in lambda lists is not supported yet" (class-name (class-of child)))))
    (let ((section (ico:required-section-ast lambda-list)))
      (when section
        (mapcar #'ico:name-ast (ico:parameter-asts section))))))

(defun compile-function (name params body)
  "Builds the KIR function NAME. PARAMS are variable definitions."
  (when (> (length params) (+ +reg-args+ +values-max+))
    (fail "functions with more than ~D parameters are not supported"
          (+ +reg-args+ +values-max+)))
  (let ((*regions* '()))
    (with-function (name)
      (let ((*self* (copy-to-var :self)))
        ;; Read the arguments first: the transfer area is only valid until
        ;; the first safepoint. Reading it before the count check is
        ;; harmless.
        (loop for p in params
              for i from 0
              do (bind-var p (if (< i +reg-args+)
                                 (nth i '(:a0 :a1 :a2))
                                 `(:load :ctx ,(+ +ctx-values+ (* 8 (- i +reg-args+)))))))
        (let ((bad (new-block)) (ok (new-block)))
          (br `(:ne :nargs ,(length params)) bad ok)
          (start-block bad)
          (emit-error +err-wrong-nargs+ `(:shl :nargs ,+fixnum-shift+))
          (start-block ok))
        (emit-poll)
        (emit `(:return ,(lower-progn body) 1))))))

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

(defmethod lower ((ast ico:labels-ast))
  (let ((functions
          (loop for lf in (ico:binding-asts ast)
                for def = (ico:name-ast lf)
                for label = (fresh-label (format nil "kiln_f_~A_"
                                                 (mangle (princ-to-string (ico:name def)))))
                do (compile-function label
                                     (lambda-list-parameters (ico:lambda-list-ast lf))
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
    (lower-progn (ico:form-asts ast))))

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
    (br `(:eq (:and (:load ,f ,(- +tag-general+)) ,+kind-mask+) ,+kind-function+) ok bad)
    (start-block bad)
    (emit-error +err-not-function+ f)
    (start-block ok)))

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
    v0))

(defun function-cell-value (name)
  (multiple-value-bind (data index) (function-cell-data name)
    (copy-to-var `(:load (:addr ,data) ,(* 8 index)))))

(defun lower-args (asts)
  (mapcar (lambda (a) (copy-to-var (lower a))) asts))

(defun lower-global-call (name arg-asts)
  (if (and (eq name 'funcall)
           arg-asts
           (typep (first arg-asts) 'ico:global-function-name-reference-ast))
      ;; (FUNCALL #'F ...) is a call to F.
      (lower-global-call (ico:name (first arg-asts)) (rest arg-asts))
      (let ((primitive (gethash name *primitives*))
            (vals (lower-args arg-asts)))
        (if primitive
            (funcall primitive vals)
            (emit-lisp-call (function-cell-value name) vals)))))

(defmethod lower ((ast ico:application-ast))
  (let ((fn (ico:function-name-ast ast)))
    (etypecase fn
      (ico:global-function-name-reference-ast
       (lower-global-call (ico:name fn) (ico:argument-asts ast)))
      ;; A local function: the variable holds its function object (LABELS).
      (ico:variable-reference-ast
       (let ((vals (lower-args (ico:argument-asts ast))))
         (emit-lisp-call (lower fn) vals))))))

(defmethod lower ((ast ico:global-function-name-reference-ast))
  (let ((name (ico:name ast)))
    (if (gethash name *primitives*)
        (primitive-function-object name)
        (function-cell-value name))))

;;; BLOCK and RETURN-FROM

(defstruct exit-info
  func            ; KIR function that contains the block or tagbody
  regions         ; regions outside it (targets of local exits)
  exit            ; BLOCK: exit block
  result          ; BLOCK: result variable
  block)          ; TAGBODY: KIR block of the tag

(defvar *exits*)                        ; block/tag definition AST -> exit-info

(defun emit-exit-token ()
  "A fresh object identifying one activation of a block or tagbody that a
closure may exit to. The closure holds it rather than the entry's stack
address: heap objects must not point into frames (C5), and a token cannot
be confused with a later activation at the same address."
  (emit-cons (nil-value) (nil-value)))

(defmethod lower ((ast ico:block-with-variable-ast))
  (let* ((def (ico:name-ast ast))
         (body (ico:form-asts ast))
         (nonlocal (exits-from-closure-p
                    body
                    (lambda (node)
                      (and (typep node 'ico:return-from-with-variable-ast)
                           (eq (ico:block-name-definition-ast (ico:name-ast node)) def)))))
         (exit (new-block)) (r (new-var)))
    (setf (gethash def *exits*)
          (make-exit-info :func *func* :regions *regions* :exit exit :result r))
    (if (not nonlocal)
        (progn
          (bind-var (ico:variable-definition-ast ast) 0)
          (emit `(:set ,r ,(lower-progn body)))
          (jump exit))
        (let* ((token (emit-exit-token))
               (region (establish-entry :exit-point token))
               (land (new-block)))
          (bind-var (ico:variable-definition-ast ast) token)
          (let ((*regions* (cons region *regions*)))
            (emit `(:set ,r ,(lower-progn body))))
          (pop-entry region)
          (jump exit)
          (start-dispatch region land)
          ;; The runtime has unlinked the entry.
          (start-block land)
          (emit `(:set ,r :exn1))
          (jump exit)))
    (start-block exit)
    r))

(defmethod lower ((ast ico:return-from-with-variable-ast))
  (let* ((info (gethash (ico:block-name-definition-ast (ico:name-ast ast)) *exits*))
         (v (copy-to-var (lower-or-nil (ico:form-ast ast)))))
    (if (eq (exit-info-func info) *func*)
        (progn
          (emit `(:set ,(exit-info-result info) ,v))
          (emit-local-exit (exit-info-regions info))
          (jump (exit-info-exit info)))
        (let ((token (lower (ico:variable-reference-ast ast))))
          (emit `(:call-rt ,(rt-exit-to) () (:ctx ,token ,v) ,(handler)))
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
          (emit `(:call-rt ,(rt-exit-to) () (:ctx ,token ,(ash index +fixnum-shift+)) ,(handler)))
          (emit '(:trap))))
    (nil-value)))

;;; CATCH, THROW, UNWIND-PROTECT

(defmethod lower ((ast ico:catch-ast))
  (let* ((tv (lower (ico:tag-form-ast ast)))
         (r (new-var)) (exit (new-block)) (land (new-block))
         (region (establish-entry :catch tv)))
    (let ((*regions* (cons region *regions*)))
      (emit `(:set ,r ,(lower-progn (ico:form-asts ast)))))
    (pop-entry region)
    (jump exit)
    (start-dispatch region land)
    ;; The runtime has unlinked the entry.
    (start-block land)
    (emit `(:set ,r :exn1))
    (jump exit)
    (start-block exit)
    r))

(defmethod lower ((ast ico:throw-ast))
  (let* ((tv (copy-to-var (lower (ico:tag-form-ast ast))))
         (vv (lower (ico:form-ast ast))))
    (emit `(:call-rt ,(rt-throw) () (:ctx ,tv ,vv) ,(handler)))
    (emit '(:trap))
    (nil-value)))

(defmethod lower ((ast ico:unwind-protect-ast))
  (let* ((cleanup (ico:form-asts ast))
         (r (new-var)) (cont (new-block)) (land (new-block))
         (region (establish-entry :unwind-protect)))
    (setf (region-cleanup region) cleanup)
    (let ((*regions* (cons region *regions*)))
      (emit `(:set ,r ,(lower (ico:protected-form-ast ast)))))
    (pop-entry region)
    (lower-progn cleanup)
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
    r))

;;; Module

(defun compile-module (asts module-name)
  "Compiles the simplified top-level ASTS into a KIR module."
  (let ((*module* (make-kmodule module-name))
        (*counter* 0)
        (*vars* (make-hash-table :test 'eq))
        (*exits* (make-hash-table :test 'eq))
        (*constants* (make-hash-table :test 'eq))
        (*primitive-functions* (make-hash-table :test 'equal)))
    (compile-function "kiln_toplevel" '() asts)
    (module-data "kiln_toplevel_fobj" `(:words ,+kind-function+ (:func "kiln_toplevel")))
    (module-init "kiln_toplevel_fobj")
    *module*))
