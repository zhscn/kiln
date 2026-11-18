(in-package #:kiln.compiler)

(defvar *compiler-pipeline* :mir
  "Native compilation pipeline. The supported middle end is :MIR.")

;;;; LIR emission for the MIR consumer: modules, calls,
;;;; allocation, dynamic environments and constants. Top-level forms run
;;;; in source order from the module initialization function.

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

(defun emit-runtime-op (operation arguments)
  "Submits a runtime service with evaluated object operands."
  (unless (= (length arguments) (kiln.lir:runtime-signature operation))
    (fail "Wrong argument count for runtime operation ~S" operation))
  (let ((result (new-var)) (arguments (mapcar #'copy-to-var arguments)))
    (emit `(:runtime-op ,result ,operation ,arguments ,(handler) ,@(call-loc)))
    result))

;;; Constants and static data
;;;
;;; Operands are KIR expressions; data words are KIR data words. A constant
;;; is built as a data word, then turned into an operand.
;;;
;;; Image compilation preserves object identity through an indexed literal
;;; table supplied by the loader. References carry indices; the backend owns
;;; the table layout, roots, and installation.

(defvar *image-literals* nil
  "When compiling into the running image: a hash table from literal objects
to their indices in the literal words; else NIL.")

(defvar *image-literal-objects*)        ; the literals, newest first
(defvar *image-literal-count*)

(defun literal-word (x)
  `(:literal ,(or (gethash x *image-literals*)
                  (setf (gethash x *image-literals*)
                        (prog1 *image-literal-count*
                          (push x *image-literal-objects*)
                          (incf *image-literal-count*))))))

(defun word-operand (word)
  (cond ((integerp word) word)
        ((eq (first word) :literal)
         `(:literal-ref ,(second word)))
        ((eq (first word) :fixnum) `(:fixnum-tag ,(second word)))
        ((eq (first word) :character) `(:character-tag ,(second word)))
        ((eq (first word) :single-float) `(:single-float-tag ,(second word)))
        ((eq (first word) :object-data)
         `(:object-address ,@(rest word)))
        (t (fail "invalid constant descriptor ~S" word))))

(defun emit-literal-words ()
  "Defines the literal words of a module compiled into the running image;
returns the literals, a vector."
  (kiln.kir::module-literal-table *image-literal-count*)
  (coerce (nreverse *image-literal-objects*) 'simple-vector))

(defun nil-word () `(:object-data ,(module-import-data "kiln_nil") :general))
(defun t-word () `(:object-data ,(module-import-data "kiln_t") :general))
(defun nil-value () (word-operand (nil-word)))
(defun t-value () (word-operand (t-word)))
(defun boolean-value (condition)
  (copy-to-var `(:select ,condition ,(t-value) ,(nil-value))))

(defun require-builtin (kind)
  (kiln.kir::module-builtin kind (if *image-literals* :image :file)))

(defun undefined-function-test (function)
  "Tests whether FUNCTION is an undefined function-cell placeholder."
  (require-builtin :undefined-function)
  (require-builtin :undefined-setf-function)
  `(:undefined-function-p ,function))

(defun function-cell-place (name)
  "The symbol operand and field ID of the global function cell of NAME."
  (multiple-value-bind (symbol field)
      (cond ((symbolp name) (values name kiln.kir::+packet-field-symbol-function+))
            ((and (consp name) (eq (first name) 'setf) (symbolp (second name))
                  (second name) (not (eq (second name) t)))
             (values (second name) kiln.kir::+packet-field-symbol-setf-function+))
            (t (fail "invalid function name ~S" name)))
    (if *image-literals*
        (values (constant-object symbol) field)
        (values `(:object-address ,(symbol-data symbol) :general) field))))

(defun string-data (label string)
  "Defines LABEL as a static string object holding STRING (once)."
  (module-data label (copy-seq string))
  label)

(defun package-name-word (package)
  "Until package objects exist (M3.3), a symbol's package slot holds the
name of its package as a string."
  (if package
      (let ((name (target-package-name package)))
        `(:object-data ,(module-shared (string-data (format nil "kiln_pkg_~A" (mangle name)) name))
                       :general))
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
      (let* ((symbol-name (module-symbol-name sym))
             (package (symbol-package sym))
             (name (string-data (kiln.kir::kir-name "kiln_name_" label) symbol-name))
            (undef (kiln.kir::kir-name "kiln_undef_" label))
            (undef-setf (kiln.kir::kir-name "kiln_undef_setf_" label)))
        (module-data undef `(:static-builtin ,(require-builtin :undefined-function) (:object-data ,obj :general)))
        (module-data undef-setf `(:static-builtin ,(require-builtin :undefined-setf-function) (:object-data ,obj :general)))
        (module-data obj (kiln.kir::make-static-symbol
                          :name symbol-name :package (and package (target-package-name package))
                          :name-label name :package-word (package-name-word package)
                          :undefined-label undef :undefined-setf-label undef-setf))
        (module-shared name)
        (module-shared undef)
        (module-shared undef-setf)
        (module-shared obj)
        (push sym *module-symbols*)
        ;; The package slot holds the package object once packages exist.
        ;; The TLS index (a fixnum) is not a GC root, but it changes as
        ;; the other words do: a heap image saves the static roots.
        (kiln.kir::module-symbol-roots obj)))
    obj))

(defun symbol-word (sym)
  (cond ((null sym) (nil-word))
        ((eq sym t) (t-word))
        (*image-literals* (literal-word sym))
        (t `(:object-data ,(symbol-data sym) :general))))

(defconstant +most-positive-fixnum+ kiln.kir::+backend-fixnum-max+)
(defconstant +most-negative-fixnum+ kiln.kir::+backend-fixnum-min+)

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
         `(:fixnum ,x)
         (or (gethash x *constants*)
             (let ((label (fresh-label "kiln_bignum_")))
               (module-data label `(:static-integer ,(kiln.kir::decimal-string x)))
               (setf (gethash x *constants*) `(:object-data ,label :general))))))
    (symbol (symbol-word x))
    (single-float
     `(:single-float ,(single-float-bits x)))
    (double-float
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_double_")))
           (module-data label `(:static-double ,(signed-word
                                         (logior (ash (double-float-high-bits x) 32)
                                                 (double-float-low-bits x)))))
           (setf (gethash x *constants*) `(:object-data ,label :general)))))
    (ratio
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_ratio_")))
           (module-data label `(:static-ratio ,(constant-word (numerator x))
                                       ,(constant-word (denominator x))))
           (setf (gethash x *constants*) `(:object-data ,label :general)))))
    (complex
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_complex_")))
           (module-data label `(:static-complex ,(constant-word (realpart x))
                                       ,(constant-word (imagpart x))))
           (setf (gethash x *constants*) `(:object-data ,label :general)))))
    (character
     `(:character ,(char-code x)))
    (string
     (or (gethash x *constants*)
         (setf (gethash x *constants*)
               (or (gethash x *string-constants*)
                   (setf (gethash x *string-constants*)
                         `(:object-data ,(string-data (fresh-label "kiln_string_") x) :general))))))
    (simple-vector
     (or (gethash x *constants*)
         (let ((label (fresh-label "kiln_vector_")))
           (setf (gethash x *constants*) `(:object-data ,label :general))
           (module-data label `(:static-vector ,@(map 'list #'constant-word x)))
           `(:object-data ,label :general))))
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
                         `(:object-data ,(fresh-label "kiln_const_") :cons)))))
           (setf (gethash x *pending-conses*) nil)
           (let* ((car-word (constant-word (car x)))
                  (cdr-word (constant-word (cdr x)))
                  (cyclic (gethash x *pending-conses*))
                  (key (list car-word cdr-word)))
             (remhash x *pending-conses*)
             (setf (gethash x *constants*)
                   (or (and (not cyclic) (gethash key *cons-words*))
                       (let ((word (or cyclic `(:object-data ,(fresh-label "kiln_const_") :cons))))
                         (module-data (second word) `(:static-cons ,car-word ,cdr-word))
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

(defun lir-builder-representation-p (operand representation)
  (and (kiln.kir::kvar-p operand)
       (eq (svref operand 2) (if (eq representation :word) :raw representation))))

(defun copy-to-var (operand &optional (kind :obj))
  (let* ((variable (new-var kind))
         (signature (and (consp operand)
                         (gethash (first operand) kiln.kir::*lir-operation-signatures*))))
    (cond ((and signature
                (lir-builder-representation-p variable (second signature))
                (= (length (rest operand)) (length (first signature)))
                (every #'lir-builder-representation-p (rest operand) (first signature)))
           (emit (list :lir-set variable operand)))
          (t (kiln.kir::emit-lir-assignment variable operand)))
    variable))

(defun emit-fatal-error (code obj)
  "Reports error CODE about the Lisp value OBJ and ends the program."
  (emit `(:fatal-error ,code ,obj ,@(call-loc))))

(defun emit-error (code obj)
  "Signals error CODE about OBJ through the current runtime error definition."
  (let ((obj (copy-to-var obj)))
    (emit `(:signal-error ,code ,obj ,(handler) ,@(call-loc)))))

(defun emit-poll (&key stack)
  "Polls for pending runtime work and stack exhaustion."
  (emit `(:poll ,(if stack :entry :loop) ,(handler))))

(defun pop-entry (region)
  (if (eq (region-kind region) :stack-roots)
      (emit `(:stack-roots-leave ,(region-slot region)))
      (emit `(:dynamic-leave ,(region-slot region)))))

(defun emit-region-entry (region statement)
  (let ((function kiln.kir::*func*))
    (when (kiln.kir::kfunc-direct-regions-p function)
      (push (kiln.kir::make-emitted-region
             :slot (region-slot region) :kind (region-kind region)
             :parents (mapcar #'region-slot *regions*)
             :block (bname (kiln.kir::kfunc-current function))
             :tag (fourth statement))
            (kiln.kir::kfunc-region-entries function))))
  (emit statement))

(defun establish-entry (kind &optional (tag 0))
  "Links a new dynamic-environment entry into the context. Returns its
region; code inside it runs with the region pushed on *REGIONS*."
  (let* ((slot (new-slot `(:dynamic-entry ,kind)))
         (region (make-region :kind kind :slot slot
                              :handler (if (member kind '(:bind :progv)) nil (new-block))
                              :outer *regions*)))
    (emit-region-entry region `(:dynamic-enter ,slot ,kind ,tag))
    region))

(defun start-dispatch (region land)
  "Records the landing and the handler chain used by diagnostic KIR."
  (let* ((dispatch (region-handler region))
         (outer (new-block))
         (function kiln.kir::*func*)
         (handler (let ((*regions* (region-outer region))) (handler))))
    (if (kiln.kir::kfunc-direct-regions-p function)
        (progn
          (push (kiln.kir::make-emitted-landing
                 :slot (region-slot region) :handler (bname dispatch)
                 :target (bname land) :forward (bname outer) :outer-handler handler)
                (kiln.kir::kfunc-region-landings function))
          (setf (kiln.kir::kblock-terminated dispatch) t
                (kiln.kir::kblock-terminated outer) t))
        (progn
          (start-block dispatch)
          (br `(:unwind-target-p ,(region-slot region)) land outer)
          (start-block outer)
          (if (eq handler :nil)
              (emit '(:trap))
              (emit `(:jump ,handler)))))))

(defun emit-nonlocal-values (kind target primary count)
  "Passes the current values to a nonlocal target."
  (emit `(:unwind-values ,kind ,target ,primary ,count ,(handler) ,@(call-loc))))

(defun emit-landed-values ()
  "Decodes the values carried by the current nonlocal landing."
  (let ((primary (new-var)) (count (new-var :raw)))
    (emit `(:landed-values ,primary ,count))
    (values primary count)))

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
  ast file source definition form (origin *source-origin*) (symbols nil))

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
              `(:debug-literal ,(second word))
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

;;; Special variables. The backend selects TLS slots and the global fallback.

(defun emit-symbol-value (sym)
  "Current value of the symbol operand SYM, possibly UNBOUND."
  (let ((sym (copy-to-var sym)) (v (new-var)))
    (emit `(:special-ref ,v ,sym))
    v))

(defun emit-set-symbol-value (sym value)
  (let ((sym (copy-to-var sym)) (value (copy-to-var value)))
    (emit `(:special-set ,sym ,value))))

(defun emit-check-bound (v sym)
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:eq ,v (:unbound-value)) bad ok)
    (start-block bad)
    (emit-error +err-unbound-variable+ sym)
    (start-block ok)))

(defun constant-symbol-p (name)
  (or (null name) (eq name t) (keywordp name)))

(defun emit-unbind (region)
  "Restores the value saved in the binding entry of REGION."
  (emit `(:special-unbind ,(region-slot region))))

(defun emit-tls-index (sym)
  "Raw variable holding the TLS index of the symbol operand SYM, assigned
if needed (not a safepoint)."
  (let ((sym (copy-to-var sym)) (index (new-var :raw)))
    (emit `(:ensure-tls-index ,index ,sym))
    index))

(defun emit-unbind-progv (region)
  "Restores the bindings saved in the progv entry of REGION. No calls."
  (emit `(:progv-restore ,(region-slot region))))


;;; Integer arithmetic

(defun emit-fixnum-arithmetic (name a b bounded &optional error-on-overflow)
  (if bounded
      (copy-to-var (case name
                     (+ `(:fixnum-add ,a ,b)) (- `(:fixnum-sub ,a ,b))
                     (* `(:fixnum-mul ,a ,b))))
      ;; Input types do not prove that the result fits. Keep the overflow
      ;; edge and its arbitrary-precision result.
      (let ((r (new-var)) (ovf (new-var :raw)) (slow (new-block)) (done (new-block)))
        (emit (case name
                (+ `(:fixnum-add-ovf ,r ,ovf ,a ,b))
                (- `(:fixnum-sub-ovf ,r ,ovf ,a ,b))
                (* `(:fixnum-mul-ovf ,r ,ovf ,a ,b))))
        (br ovf slow done)
        (start-block slow)
        (emit `(:set ,r ,(emit-slow-call
                         (case name (+ 'kiln.kernel::two-arg-+)
                                    (- 'kiln.kernel::two-arg--)
                                    (* 'kiln.kernel::two-arg-*)) a b)))
        (when error-on-overflow
          (emit-slow-call 'kiln.kernel::%declared-type-error r (constant-object 'fixnum)))
        (jump done) (start-block done) r)))

;;; Allocation

(defun emit-fixed-object (class fields)
  "Allocate an object with already evaluated, stable field operands."
  (let ((result (new-var)))
    (emit `(:alloc-fixed ,result ,class ,fields ,(handler)))
    result))

(defun emit-box-double-bits (bits)
  (let ((bits (copy-to-var bits :raw)))
    (emit-fixed-object kiln.kir::+packet-class-double+ (list bits))))

(defun establish-stack-object (class reference-count)
  "Allocate fixed storage and register only its contiguous Lisp reference fields.
All words are initialized before the object can be observed at a safepoint.
Return the storage slot and its root region, if any."
  (let ((slot (new-slot `(:stack-object ,class ,reference-count))))
    (emit `(:stack-object-init ,slot ,class ,reference-count))
    (values slot
            (when (plusp reference-count)
              (let ((region (make-region :kind :stack-roots
                                         :slot (new-slot '(:stack-roots-entry))
                                         :handler nil :outer *regions*)))
                (emit-region-entry region `(:stack-roots-enter ,(region-slot region) ,slot ,class ,reference-count))
                region)))))

(defun emit-vector-object (class length initial-value)
  "Allocate and fill a vector using evaluated length and initial value."
  (let ((result (new-var)))
    (emit `(:alloc-vector ,result ,class ,length ,initial-value ,(handler)))
    result))

(defun emit-cons (a b)
  ;; A and B are live across the allocation; as variables they are spilled
  ;; and reloaded around it (stack maps).
  (let ((a (if (integerp a) a (copy-to-var a)))
        (b (if (integerp b) b (copy-to-var b))))
    (emit-fixed-object kiln.kir::+packet-class-cons+ (list a b))))

;;; Cells (assignment conversion): a cell is a cons whose car is the value.


;;; Functions

(defun emit-nargs-check (count min max)
  "Checks the incoming argument COUNT; MAX is NIL for no upper limit."
  (let ((bad (new-block)) (ok (new-block)))
    (br (cond ((and max (= min max)) `(:ne ,count ,min))
              (max `(:or (:lt ,count ,min) (:gt ,count ,max)))
              (t `(:lt ,count ,min)))
        bad ok)
    (start-block bad)
    (emit-error +err-wrong-nargs+ `(:fixnum-tag ,count))
    (start-block ok)))

(defun emit-check-function (f)
  (let ((bad (new-block)) (ok (new-block)))
    (br (emit-kind-test f kiln.kir::+packet-class-function+) ok bad)
    (start-block bad)
    (emit-error +err-not-function+ f)
    (start-block ok)))

(defun emit-function-designator (f)
  "Returns a variable holding the function designated by F: F itself if
it is a function, the global function of F if it is a symbol."
  (let ((r (copy-to-var f))
        (not-function (new-block)) (symbol (new-block))
        (bad (new-block)) (ok (new-block)))
    (br (emit-kind-test r kiln.kir::+packet-class-function+) ok not-function)
    (start-block not-function)
    (br (emit-kind-test r kiln.kir::+packet-class-symbol+) symbol bad)
    (start-block symbol)
    (emit `(:set ,r (:field-load ,kiln.kir::+packet-field-symbol-function+ ,r)))
    (jump ok)
    (start-block bad)
    (emit-error +err-not-function+ r)
    (start-block ok)
    r))

(defun emit-check-symbol (s)
  (let ((bad (new-block)) (ok (new-block)))
    (br (emit-kind-test s kiln.kir::+packet-class-symbol+) ok bad)
    (start-block bad)
    (emit-error +err-not-symbol+ s)
    (start-block ok)))

(defun emit-lisp-call (fobj vals)
  "Calls FOBJ after evaluating all operands; the backend arranges the ABI."
  (when (> (length vals) kiln.kir::+backend-argument-limit+)
    (fail "calls with more than ~D arguments are not supported"
          kiln.kir::+backend-argument-limit+))
  (let* ((callee (if (kiln.kir::kvar-p fobj) fobj (copy-to-var fobj)))
         (arguments (mapcar (lambda (v)
                              (if (or (integerp v) (kiln.kir::kvar-p v)) v (copy-to-var v)))
                            vals))
         (v0 (new-var)) (nv (new-var :raw)))
    (emit `(:invoke ,v0 ,nv ,callee ,arguments ,(handler) ,@(call-loc)))
    (values v0 nv)))

(defun function-cell-value (name)
  (multiple-value-bind (base field) (function-cell-place name)
    (copy-to-var `(:field-load ,field ,base))))

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
  (let ((cond `(:test-class ,kiln.kir::+packet-class-fixnum+ ,val)))
    (when (> low +most-negative-fixnum+)
      (setf cond `(:and ,cond (:ge ,val (:fixnum-tag ,low)))))
    (when (< high +most-positive-fixnum+)
      (setf cond `(:and ,cond (:le ,val (:fixnum-tag ,high)))))
    cond))

(defun inline-typep-specifier-p (type)
  (cond ((member type '(t nil boolean unsigned-byte signed-byte)) t)
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

(defun emit-unbounded-byte-typep (value unsigned)
  "Test integer membership and, for UNSIGNED-BYTE, a nonnegative sign."
  (let ((integer (funcall (gethash 'integerp *primitives*) (list value))))
    (if (not unsigned) integer
        (let ((result (new-var)) (check (new-block)) (done (new-block)))
          (emit `(:set ,result ,(nil-value)))
          (br `(:ne ,integer ,(nil-value)) check done)
          (start-block check)
          (emit `(:set ,result ,(funcall (gethash '>= *primitives*) (list value (constant-object 0)))))
          (jump done)
          (start-block done)
          result))))

(defun emit-inline-typep (val type)
  (multiple-value-bind (low high fixnum-range-p) (type-fixnum-bounds type)
    (cond (fixnum-range-p
           (boolean-value (emit-fixnum-range-test val low high)))
          ((eq type t) (t-value))
          ((eq type nil) (nil-value))
          ((member type '(unsigned-byte signed-byte))
           (emit-unbounded-byte-typep val (eq type 'unsigned-byte)))
          ((eq type 'boolean)
           (boolean-value `(:or (:eq ,val ,(nil-value)) (:eq ,val ,(t-value)))))
          ((symbolp type)
           (let* ((predicate (cdr (assoc type *type-predicates*)))
                  (primitive (gethash predicate *primitives*)))
             (if primitive
                 (funcall primitive (list val))
                 (emit-lisp-call (function-cell-value predicate) (list val)))))
          ((eq (first type) 'eql)
           (if (eq-comparable-value-p (second type))
               (boolean-value `(:eq ,val ,(constant-object (second type))))
               (funcall (gethash 'eql *primitives*)
                        (list val (constant-object (second type))))))
          ((eq (first type) 'member)
           (let ((items (rest type)))
             (cond ((null items) (nil-value))
                   ((every #'eq-comparable-value-p items)
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

(defun eq-comparable-value-p (value)
  "Whether EQL with VALUE has the same result as EQ."
  (and (not (and (integerp value)
                 (not (<= +most-negative-fixnum+ value +most-positive-fixnum+))))
       (not (typep value '(or ratio double-float complex)))))

(defun emit-cached-typep (object type)
  "Emit a type test with a writable stamp/result and type-version cache."
  (let ((label (fresh-label "kiln_typep_cache_")))
    (module-data label `(:static-mutable-cons ,(nil-word) ,(nil-word)))
    (emit-lisp-call (function-cell-value 'kiln.kernel::%typep-cached)
                    (list object (constant-object type) `(:object-address ,label :cons)))))

(defun emit-typep-test (object type)
  "Test an evaluated object against a known specifier, retaining runtime guards."
  (cond ((inline-typep-specifier-p type) (emit-inline-typep object type))
        ((cached-typep-specifier-p type) (emit-cached-typep object type))
        (t (emit-slow-call 'typep object (constant-object type)))))

(defun emit-cached-slot-value (object slot-name)
  "Read a named slot through a cache guarded by the object's class stamp."
  (let ((label (fresh-label "kiln_slot_value_cache_")))
    (module-data label `(:static-mutable-cons ,(nil-word) ,(nil-word)))
    (emit-lisp-call (function-cell-value 'kiln.kernel::%slot-value-cached)
                    (list object (constant-object slot-name) `(:object-address ,label :cons)))))

(defun emit-cached-set-slot-value (value object slot-name)
  "Write a named slot through a cache guarded by the object's class stamp."
  (let ((label (fresh-label "kiln_set_slot_value_cache_")))
    (module-data label `(:static-mutable-cons ,(nil-word) ,(nil-word)))
    (emit-lisp-call (function-cell-value 'kiln.kernel::%set-slot-value-cached)
                    (list value object (constant-object slot-name) `(:object-address ,label :cons)))))

(defun call-site-root ()
  "A mutable cache cons whose object-valued car is a static GC root."
  (let ((label (fresh-label "kiln_call_site_")))
    (module-data label `(:static-mutable-cons ,(nil-word) ,(nil-word)))
    `(:object-address ,label :cons)))

(defun call-site-specialization-p ()
  ;; The construction protocol itself (kernel, CLOS) calls MAKE-INSTANCE plainly.
  (not (member (kmodule-name *module*) '("kernel" "clos") :test #'string=)))

(defun emit-constructor-call (name vals class-name keys)
  (let* ((helper (function-cell-value 'kiln.kernel::%constructor-target))
         (fallback (new-block)) (specialized (new-block)) (done (new-block))
         (result (new-var)) (count (new-var :raw)))
    (br (undefined-function-test helper) fallback specialized)
    (start-block fallback)
    (multiple-value-call #'emit-move-values result count
      (emit-lisp-call (function-cell-value name) vals))
    (jump done)
    (start-block specialized)
    (let ((function (copy-to-var
                     (emit-lisp-call helper (list (call-site-root)
                                                  (constant-object class-name)
                                                  (constant-object keys))))))
      (multiple-value-call #'emit-move-values result count
        (emit-lisp-call function
                        (loop for value in (cddr vals) by #'cddr collect value))))
    (jump done)
    (start-block done)
    (values result count)))

(defun emit-set-constant-fdefinition (name function)
  "Install a checked function before the kernel's definition setter exists."
  (emit-check-function function)
  (multiple-value-bind (base field) (function-cell-place name)
    (emit `(:field-store ,field ,base ,function)))
  ;; Early kernel definitions precede the notification function.
  (let* ((notify (function-cell-value 'kiln.kernel::note-function-change))
         (changed (new-block))
         (done (new-block)))
    (br (undefined-function-test notify) done changed)
    (start-block changed)
    (emit-lisp-call notify (list (constant-object name)))
    (jump done)
    (start-block done))
  function)

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
    (br `(:eq ,old (:unbound-value)) unbound join)
    (start-block unbound)
    (emit `(:set ,old ,(nil-value)))
    (jump join)
    (start-block join)
    (let ((table (copy-to-var `(:cell-ref ,(symbol-table-cell)))))
      (emit `(:field-store ,kiln.kir::+packet-field-symbol-value+ ,sym ,(emit-cons table old)))))
  (let ((f (function-cell-value 'kiln.kernel::%register-module-symbols))
        (call (new-block)) (join (new-block)))
    (br (undefined-function-test f) join call)
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
            (mir-lower-toplevel (toplevel-form-ast form))))
        (emit `(:return ,(nil-value) 1)))
      (let ((*toplevel* (and (= (length files) 1) (first files)
                             (make-toplevel-form nil (first files) nil nil nil))))
        (set-function-debug '(:top-level-form) nil))))
  (let ((fobj (kiln.kir::kir-name name "_fobj")))
    (module-data fobj `(:static-function ,name))
    `(:object-data ,fobj :general)))

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

(defun compile-module (asts module-name &key session defined-packages extra-symbols image (pipeline *compiler-pipeline*))
  "Compiles the top-level forms ASTS (TOPLEVEL-FORMs) into a KIR module. The module's
symbol table describes its symbols, the EXTRA-SYMBOLS and the symbols of
the DEFINED-PACKAGES (host packages its DEFPACKAGE forms created) for the
package system.
IMAGE true: the module is to be loaded into the running image; its
literals are the image's objects, and it has no symbol table.
Returns the module and the vector of its literals."
  (unless (eq pipeline :mir) (fail "Unknown compiler pipeline ~S" pipeline))
  (let ((*compiler-pipeline* pipeline)
        (*module* (let ((module (make-kmodule module-name)))
                    (setf (kiln.kir::kmodule-capture-shapes-complete-p module) t)
                    module))
        (*image-literals* (and image (make-hash-table :test 'eq)))
        (*image-literal-objects* '())
        (*image-literal-count* 0)
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
        (module-data (kiln.kir::kir-name init "_fobj") `(:static-function ,init))
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
    (kiln.kir::module-object-cell (symbol-table-cell)
      (constant-word (symbol-table-literal *module-symbols* session defined-packages)))
    (let ((init (format nil "kiln_toplevel_~A" *module-label*)))
      (module-data (format nil "~A_fobj" init) `(:static-function ,init))
      (module-init (format nil "~A_fobj" init)))
    *module*))
