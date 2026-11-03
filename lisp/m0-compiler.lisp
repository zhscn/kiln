(in-package #:kiln.m0)

;;;; Scaffolding compiler (M0/M1): a small Lisp subset straight to KIR.
;;;;
;;;; Supported: DEFUN (up to 3 required parameters), IF, LET, LET*, SETQ,
;;;; PROGN, BLOCK, RETURN-FROM, TAGBODY, GO, CATCH, THROW, UNWIND-PROTECT,
;;;; FUNCTION of a global function name, QUOTE of fixnums and symbols, calls
;;;; to functions defined in the same file, and the primitives
;;;; + - * < > <= >= = EQ NULL NOT CONS CAR CDR CONSP ATOM LIST FUNCALL PRINT
;;;; %GC %GC-COUNT. Lexical variables only; no closures.
;;;;
;;;; The point of M0 is to exercise the ABI (docs/06-m0-abi.md): calling
;;;; convention, context pointer, poll points, and non-local exit through
;;;; try_call. The front end is replaced in M2.

(define-condition m0-compile-error (error)
  ((message :initarg :message :reader m0-compile-error-message))
  (:report (lambda (c s) (write-string (m0-compile-error-message c) s))))

(defun fail (control &rest args)
  (error 'm0-compile-error :message (apply #'format nil control args)))

;;; Symbol names in the object file

(defun mangle (string)
  (with-output-to-string (out)
    (loop for c across string
          do (if (and (< (char-code c) 128) (alphanumericp c))
                 (write-char c out)
                 (format out "_~X_" (char-code c))))))

(defun fname (sym) (format nil "kiln_f_~A" (mangle (symbol-name sym))))
(defun fobj-name (sym) (format nil "kiln_fobj_~A" (mangle (symbol-name sym))))
(defun fcell-name (sym) (format nil "kiln_fcell_~A" (mangle (symbol-name sym))))

;;; Runtime functions

(defun rt-print () (module-import-func "kiln_rt_print" 2 1))
(defun rt-error () (module-import-func "kiln_rt_error" 3 0 :unwinds :noreturn))
(defun rt-poll () (module-import-func "kiln_rt_poll" 1 0 :unwinds))
(defun rt-throw () (module-import-func "kiln_rt_throw" 3 0 :unwinds :noreturn))
(defun rt-continue-unwind ()
  (module-import-func "kiln_rt_continue_unwind" 2 0 :unwinds :noreturn))
(defun rt-alloc () (module-import-func "kiln_rt_alloc" 3 1 :unwinds))
(defun rt-gc () (module-import-func "kiln_rt_gc" 1 1 :unwinds))
(defun rt-gc-count () (module-import-func "kiln_rt_gc_count" 1 1))

;;; Constants

(defun nil-value () `(:addr ,(module-import-data "kiln_nil") ,+tag-general+))
(defun t-value () `(:addr ,(module-import-data "kiln_t") ,+tag-general+))

(defun symbol-object (sym)
  (cond ((null sym) (nil-value))
        ((eq sym t) (t-value))
        (t
         (let* ((name (symbol-name sym))
                (str (format nil "kiln_str_~A" (mangle name)))
                (obj (format nil "kiln_sym_~A" (mangle name))))
           (module-data str `(:bytes ,name))
           (module-data obj `(:words ,+kind-symbol+ (:data ,str) ,(length name)))
           `(:addr ,obj ,+tag-general+)))))

(defconstant +most-positive-fixnum+ (1- (ash 1 62)))
(defconstant +most-negative-fixnum+ (- (ash 1 62)))

(defun constant-object (x)
  (typecase x
    (integer
     (unless (<= +most-negative-fixnum+ x +most-positive-fixnum+)
       (fail "integer ~D is outside the fixnum range (no bignums in M0)" x))
     (ash x +fixnum-shift+))
    (symbol (symbol-object x))
    (t (fail "constants of type ~S are not supported in M0" (type-of x)))))

;;; Lexical environment

(defstruct region
  kind            ; :catch, :unwind-protect, or :cleanup-running
  slot            ; stack slot holding the dynamic-environment entry
  handler         ; block that dispatches exceptional entry into this frame
  cleanup         ; unwind-protect cleanup forms
  outer-env)      ; environment outside the region

(defstruct (env (:copier copy-env))
  (vars '())      ; alist symbol -> KIR variable
  (blocks '())    ; alist name -> (exit-block result-var regions)
  (tags '())      ; alist tag -> (block regions)
  (regions '()))  ; innermost first

(defun handler (env)
  (let ((r (first (env-regions env))))
    (if (and r (region-handler r)) (kiln.kir::kblock-name (region-handler r)) :nil)))

(defun bname (b) (kiln.kir::kblock-name b))

(defun jump (b) (emit `(:jump ,(bname b))))

(defun br (cond then else) (emit `(:br ,cond ,(bname then) ,(bname else))))

(defun copy-to-var (operand &optional (kind :obj))
  (let ((v (new-var kind)))
    (emit `(:set ,v ,operand))
    v))

;;; Errors and polls

(defun emit-error (code obj env)
  (emit `(:call-rt ,(rt-error) () (:ctx ,code ,obj) ,(handler env)))
  (emit '(:trap)))

(defun emit-poll (env)
  (let ((slow (new-block)) (cont (new-block)))
    (br `(:load :ctx ,+ctx-poll-flag+) slow cont)
    (start-block slow)
    (emit `(:call-rt ,(rt-poll) () (:ctx) ,(handler env)))
    (jump cont)
    (start-block cont)))

(defun emit-check-fixnums (a b env)
  (let ((bad (new-block)) (ok (new-block)))
    (br `(:and (:or ,a ,b) 1) bad ok)
    (start-block bad)
    (emit-error +err-not-fixnum+ `(:select (:and ,a 1) ,a ,b) env)
    (start-block ok)))

;;; Leaving regions on a local exit (RETURN-FROM, GO)

(defun pop-entry (region)
  (emit `(:store :ctx ,+ctx-dynenv+ (:load (:slot ,(region-slot region)) ,+dyn-prev+))))

(defun emit-local-exit (env target-regions)
  (loop for regions on (env-regions env)
        until (eq regions target-regions)
        do (let ((r (first regions)))
             (pop-entry r)
             (when (eq (region-kind r) :unwind-protect)
               (compile-progn (region-cleanup r) (region-outer-env r))))))

;;; Compiler

(defvar *functions*)          ; symbol -> number of parameters
(defvar *called*)             ; symbol -> t

(defun compile-form (form env)
  "Emits code for FORM; returns an operand holding its value."
  (cond ((and (symbolp form) (not (keywordp form)) form (not (eq form t)))
         (let ((v (cdr (assoc form (env-vars env)))))
           (unless v (fail "unbound variable ~S (only lexical variables in M0)" form))
           (copy-to-var v)))
        ((atom form) (constant-object form))
        (t (compile-compound (first form) (rest form) env))))

(defun compile-progn (forms env)
  (if (null forms)
      (nil-value)
      (let (v)
        (dolist (f forms v)
          (setf v (compile-form f env))))))

(defun compile-compound (op args env)
  (case op
    (quote (constant-object (first args)))
    (progn (compile-progn args env))
    (if (compile-if args env))
    (let (compile-let args env nil))
    (let* (compile-let args env t))
    (setq (compile-setq args env))
    (block (compile-block args env))
    (return-from (compile-return-from args env))
    (tagbody (compile-tagbody args env))
    (go (compile-go args env))
    (catch (compile-catch args env))
    (throw (compile-throw args env))
    (unwind-protect (compile-unwind-protect args env))
    ((+ - *) (compile-arith op args env))
    ((< > <= >= =) (compile-compare op args env))
    (eq (destructuring-bind (a b) args
          (let ((a (compile-form a env)) (b (compile-form b env)))
            (copy-to-var `(:select (:eq ,a ,b) ,(t-value) ,(nil-value))))))
    ((null not) (destructuring-bind (a) args
                  (let ((a (compile-form a env)))
                    (copy-to-var `(:select (:eq ,a ,(nil-value)) ,(t-value) ,(nil-value))))))
    (cons (destructuring-bind (a b) args
            (compile-cons (compile-form a env) (compile-form b env) env)))
    (car (destructuring-bind (a) args (compile-car-cdr (compile-form a env) +cons-car+ env)))
    (cdr (destructuring-bind (a) args (compile-car-cdr (compile-form a env) +cons-cdr+ env)))
    ((consp atom)
     (destructuring-bind (a) args
       (let ((a (compile-form a env))
             (yes (t-value)) (no (nil-value)))
         (when (eq op 'atom) (rotatef yes no))
         (copy-to-var `(:select (:eq (:and ,a ,+tag-mask+) ,+tag-cons+) ,yes ,no)))))
    (list (compile-form (if args `(cons ,(first args) (list ,@(rest args))) nil) env))
    (function (compile-function-ref args))
    (funcall (compile-funcall args env))
    (%gc (let ((r (new-var)))
           (emit `(:call-rt ,(rt-gc) (,r) (:ctx) ,(handler env)))
           r))
    (%gc-count (let ((r (new-var)))
                 (emit `(:call-rt ,(rt-gc-count) (,r) (:ctx) :nil))
                 r))
    (print (destructuring-bind (a) args
             (let ((a (compile-form a env)) (r (new-var)))
               (emit `(:call-rt ,(rt-print) (,r) (:ctx ,a) :nil))
               r)))
    (t (if (and (symbolp op) (gethash op *functions*))
           (compile-call op args env)
           (fail "unsupported operator ~S" op)))))

(defun compile-if (args env)
  (destructuring-bind (test then &optional else) args
    (let ((tv (compile-form test env))
          (r (new-var))
          (then-b (new-block)) (else-b (new-block)) (join (new-block)))
      (br `(:ne ,tv ,(nil-value)) then-b else-b)
      (start-block then-b)
      (emit `(:set ,r ,(compile-form then env)))
      (jump join)
      (start-block else-b)
      (emit `(:set ,r ,(compile-form else env)))
      (jump join)
      (start-block join)
      r)))

(defun compile-let (args env sequential)
  (destructuring-bind (bindings &rest body) args
    (let ((new-env (copy-env env))
          (pairs '()))
      (dolist (b bindings)
        (multiple-value-bind (name init)
            (if (consp b) (values (first b) (second b)) (values b nil))
          (let ((v (new-var)))
            (emit `(:set ,v ,(compile-form init (if sequential new-env env))))
            (if sequential
                (push (cons name v) (env-vars new-env))
                (push (cons name v) pairs)))))
      (setf (env-vars new-env) (append pairs (env-vars new-env)))
      (compile-progn body new-env))))

(defun compile-setq (args env)
  (let ((result (nil-value)))
    (loop for (name form) on args by #'cddr
          do (let ((v (cdr (assoc name (env-vars env)))))
               (unless v (fail "SETQ of unknown variable ~S" name))
               (emit `(:set ,v ,(compile-form form env)))
               (setf result (copy-to-var v))))
    result))

(defun compile-block (args env)
  (destructuring-bind (name &rest body) args
    (let* ((exit (new-block)) (r (new-var))
           (new-env (copy-env env)))
      (push (list name exit r (env-regions env)) (env-blocks new-env))
      (emit `(:set ,r ,(compile-progn body new-env)))
      (jump exit)
      (start-block exit)
      r)))

(defun compile-return-from (args env)
  (destructuring-bind (name &optional value) args
    (let ((entry (assoc name (env-blocks env))))
      (unless entry (fail "RETURN-FROM unknown block ~S" name))
      (destructuring-bind (exit r regions) (rest entry)
        (let ((v (compile-form value env)))
          (emit `(:set ,r ,v))
          (emit-local-exit env regions)
          (jump exit)
          (nil-value))))))

(defun compile-tagbody (args env)
  (let ((new-env (copy-env env)))
    (dolist (item args)
      (when (atom item)
        (push (list item (new-block) (env-regions env)) (env-tags new-env))))
    (dolist (item args)
      (if (atom item)
          (let ((b (second (assoc item (env-tags new-env)))))
            (jump b)
            (start-block b)
            (emit-poll new-env))
          (compile-form item new-env)))
    (nil-value)))

(defun compile-go (args env)
  (let ((entry (assoc (first args) (env-tags env))))
    (unless entry (fail "GO to unknown tag ~S" (first args)))
    (destructuring-bind (b regions) (rest entry)
      (emit-local-exit env regions)
      (jump b)
      (nil-value))))

(defun establish-entry (kind tag env)
  "Emits code that links a new dynamic-environment entry into the context.
Returns the region and the environment for code inside it."
  (let* ((slot (new-slot +dynentry-size+))
         (region (make-region :kind kind :slot slot :handler (new-block)
                              :outer-env env))
         (inner (copy-env env)))
    (emit `(:store (:slot ,slot) ,+dyn-kind+ ,(if (eq kind :catch) +dyn-catch+ +dyn-unwind-protect+)))
    (emit `(:store (:slot ,slot) ,+dyn-prev+ (:load :ctx ,+ctx-dynenv+)))
    (emit `(:store (:slot ,slot) ,+dyn-fp+ (:fp)))
    ;; Tag and pending value are GC roots: always initialize them.
    (emit `(:store (:slot ,slot) ,+dyn-tag+ ,(or tag 0)))
    (emit `(:store (:slot ,slot) ,+dyn-pend-target+ 0))
    (emit `(:store (:slot ,slot) ,+dyn-pend-value+ 0))
    (emit `(:store :ctx ,+ctx-dynenv+ (:slot ,slot)))
    (push region (env-regions inner))
    (values region inner)))

(defun start-dispatch (region env land)
  "Emits the handler block of REGION: payload exn0 names the target entry.
Entries of this frame other than REGION's are dispatched outward."
  (start-block (region-handler region))
  (let ((outer (new-block)))
    (br `(:eq :exn0 (:slot ,(region-slot region))) land outer)
    (start-block outer)
    (let ((h (handler env)))
      (if (eq h :nil)
          (emit '(:trap))
          (emit `(:jump ,h))))))

(defun compile-catch (args env)
  (destructuring-bind (tag &rest body) args
    (let ((tv (compile-form tag env))
          (r (new-var)) (exit (new-block)) (land (new-block)))
      (multiple-value-bind (region inner) (establish-entry :catch tv env)
        (emit `(:set ,r ,(compile-progn body inner)))
        (pop-entry region)
        (jump exit)
        (start-dispatch region env land)
        ;; The runtime has already unlinked the entry.
        (start-block land)
        (emit `(:set ,r :exn1))
        (jump exit)
        (start-block exit)
        r))))

(defun compile-throw (args env)
  (destructuring-bind (tag value) args
    (let* ((tv (compile-form tag env))
           (vv (compile-form value env)))
      (emit `(:call-rt ,(rt-throw) () (:ctx ,tv ,vv) ,(handler env)))
      (emit '(:trap))
      (nil-value))))

(defun compile-unwind-protect (args env)
  (destructuring-bind (protected &rest cleanup) args
    (let ((r (new-var)) (cont (new-block)) (land (new-block)))
      (multiple-value-bind (region inner) (establish-entry :unwind-protect nil env)
        (setf (region-cleanup region) cleanup)
        (emit `(:set ,r ,(compile-form protected inner)))
        (pop-entry region)
        (compile-progn cleanup env)
        (jump cont)
        (start-dispatch region env land)
        ;; Entered by an unwind passing through: the entry stays linked,
        ;; marked as running its cleanup, with the pending target in it.
        ;; The cleanup runs in a region that only unlinks it on a local exit;
        ;; calls in it use the outer handler.
        (start-block land)
        (let ((running-env (copy-env env)))
          (push (make-region :kind :cleanup-running :slot (region-slot region)
                             :handler (let ((outer (first (env-regions env))))
                                        (and outer (region-handler outer))))
                (env-regions running-env))
          (compile-progn cleanup running-env))
        (emit `(:call-rt ,(rt-continue-unwind) () (:ctx (:slot ,(region-slot region)))
                         ,(handler env)))
        (emit '(:trap))
        (start-block cont)
        r))))

(defun compile-arith (op args env)
  (unless (= (length args) 2)
    (fail "~S takes exactly 2 arguments in M0" op))
  (let* ((a (compile-form (first args) env))
         (b (compile-form (second args) env))
         (r (new-var)) (ovf (new-var :raw))
         (bad (new-block)) (ok (new-block)))
    (emit-check-fixnums a b env)
    (ecase op
      (+ (emit `(:add-ovf ,r ,ovf ,a ,b)))
      (- (emit `(:sub-ovf ,r ,ovf ,a ,b)))
      (* (emit `(:mul-ovf ,r ,ovf (:sar ,a ,+fixnum-shift+) ,b))))
    (br ovf bad ok)
    (start-block bad)
    (emit-error +err-overflow+ a env)
    (start-block ok)
    r))

(defun compile-compare (op args env)
  (unless (= (length args) 2)
    (fail "~S takes exactly 2 arguments in M0" op))
  (let* ((a (compile-form (first args) env))
         (b (compile-form (second args) env)))
    (emit-check-fixnums a b env)
    (copy-to-var `(:select (,(ecase op (< :lt) (> :gt) (<= :le) (>= :ge) (= :eq)) ,a ,b)
                           ,(t-value) ,(nil-value)))))

(defun compile-cons (a b env)
  ;; A and B are live across the allocation, a GC safepoint: if they are
  ;; variables they are spilled and reloaded around it (stack maps).
  (let ((a (if (integerp a) a (copy-to-var a)))
        (b (if (integerp b) b (copy-to-var b)))
        (p (new-var :raw)))
    (emit `(:call-rt ,(rt-alloc) (,p) (:ctx ,+cons-bytes+ ,+kind-cons+) ,(handler env)))
    ;; No safepoint between here and tagging P.
    (emit `(:store ,p 8 ,a))
    (emit `(:store ,p 16 ,b))
    (copy-to-var `(:add ,p ,+tag-cons+))))

(defun compile-car-cdr (x offset env)
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
    (emit-error +err-not-list+ x env)
    (start-block join)
    r))

(defun compile-function-ref (args)
  (let ((name (first args)))
    (unless (and (symbolp name) (gethash name *functions*))
      (fail "FUNCTION of ~S: only global functions defined in this file" name))
    (setf (gethash name *called*) t)
    (copy-to-var `(:load (:addr ,(fcell-name name)) 0))))

(defun emit-lisp-call (fobj entry vals env)
  (when (> (length vals) +reg-args+)
    (fail "calls with more than ~D arguments are not supported yet" +reg-args+))
  (let ((v0 (new-var)) (nv (new-var :raw)))
    (emit `(:call-lisp ,v0 ,nv ,entry (:ctx ,fobj ,(length vals) ,@vals) ,(handler env)))
    v0))

(defun compile-funcall (args env)
  (let* ((f (copy-to-var (compile-form (first args) env)))
         (vals (mapcar (lambda (a) (compile-form a env)) (rest args)))
         (general (new-block)) (bad (new-block)) (ok (new-block)))
    (br `(:eq (:and ,f ,+tag-mask+) ,+tag-general+) general bad)
    (start-block general)
    (br `(:eq (:and (:load ,f ,(- +tag-general+)) ,+kind-mask+) ,+kind-function+) ok bad)
    (start-block bad)
    (emit-error +err-not-function+ f env)
    (start-block ok)
    (emit-lisp-call f (copy-to-var `(:load ,f ,+fobj-entry+) :raw) vals env)))

(defun compile-call (op args env)
  (let ((n (gethash op *functions*)))
    (unless (= n (length args))
      (fail "~S called with ~D arguments, takes ~D" op (length args) n)))
  (setf (gethash op *called*) t)
  (let* ((vals (mapcar (lambda (a) (compile-form a env)) args))
         (fobj (copy-to-var `(:load (:addr ,(fcell-name op)) 0))))
    (emit-lisp-call fobj (copy-to-var `(:load ,fobj ,+fobj-entry+) :raw) vals env)))

(defun compile-function (name params body)
  (let ((env (make-env)) (n (length params)))
    (with-function (name)
      (emit-poll env)
      (let ((bad (new-block)) (ok (new-block)))
        (br `(:ne :nargs ,n) bad ok)
        (start-block bad)
        (emit-error +err-wrong-nargs+ `(:shl :nargs ,+fixnum-shift+) env)
        (start-block ok))
      (loop for p in params
            for reg in '(:a0 :a1 :a2)
            do (push (cons p (copy-to-var reg)) (env-vars env)))
      (emit `(:return ,(compile-progn body env) 1)))))

(defun define-function-object (sym)
  (module-data (fobj-name sym) `(:words ,+kind-function+ (:func ,(fname sym))))
  (module-data (fcell-name sym) `(:words (:data ,(fobj-name sym) ,+tag-general+))))

(defun check-lambda-list (name params)
  (when (> (length params) +reg-args+)
    (fail "~S: more than ~D parameters are not supported yet" name +reg-args+))
  (dolist (p params)
    (when (or (not (symbolp p)) (member p lambda-list-keywords))
      (fail "~S: only required parameters are supported in M0" name))))

(defun compile-forms (forms module-name)
  "Compiles top-level FORMS into a KIR module."
  (let ((*module* (make-kmodule module-name))
        (*functions* (make-hash-table))
        (*called* (make-hash-table))
        (toplevel '()))
    (dolist (f forms)
      (if (and (consp f) (eq (first f) 'defun))
          (destructuring-bind (name params &rest body) (rest f)
            (declare (ignore body))
            (check-lambda-list name params)
            (setf (gethash name *functions*) (length params)))
          (push f toplevel)))
    (dolist (f forms)
      (when (and (consp f) (eq (first f) 'defun))
        (destructuring-bind (name params &rest body) (rest f)
          (define-function-object name)
          (compile-function (fname name) params
                            `((block ,name ,@body))))))
    (compile-function "kiln_toplevel" '() (reverse toplevel))
    (module-data "kiln_toplevel_fobj" `(:words ,+kind-function+ (:func "kiln_toplevel")))
    (module-init "kiln_toplevel_fobj")
    *module*))
