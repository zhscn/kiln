(in-package #:kiln.compiler)

(defvar *source-file*)
(defvar *source-origin* nil)

;;;; Tree edges live in node operands; references to variables, functions,
;;;; and exits are definition edges and are never traversed as children.
;;;; Kinds: 0 constant, 1 ref, 2 set, 3 special-ref, 4 special-set,
;;;; 5 global-function, 6 function, 7 call, 8 primop, 9 if, 10 progn,
;;;; 11 let, 12 bind, 13 local-functions, 14 block, 15 return,
;;;; 16 tagbody, 17 go, 18 catch, 19 throw, 20 unwind-protect,
;;;; 21 multiple-value-call, 22 multiple-value-prog1, 23 the,
;;;; 24 load-time-value, 25 progv.
(defvar *hir-policy* 1023)

(defun hir-policy-quality (policy quality)
  (logand 3 (ash (or policy 1023)
                (- (ecase quality (:speed 0) (:safety 2) (:debug 4) (:space 6) (:compilation-speed 8))))))

(defun hir-policy-optimize-p (policy)
  (let ((speed (hir-policy-quality policy :speed)))
    (and (plusp speed) (>= speed (hir-policy-quality policy :compilation-speed)))))

(defstruct (hir-node (:constructor hir-node (kind source &optional a b c d)))
  (kind 0) (source nil) (a nil) (b nil) (c nil) (d nil) (type t) (mark 0) (policy *hir-policy*) (origin *source-origin*))

(defstruct (hir-buffer (:constructor make-hir-buffer (&optional (data (make-array 8)))))
  (data nil) (count 0))

(defun hir-push (value buffer)
  (let* ((data (hir-buffer-data buffer)) (count (hir-buffer-count buffer)))
    (when (= count (length data))
      (let ((new (make-array (max 8 (* 2 count)))))
        (dotimes (i count) (setf (svref new i) (svref data i)))
        (setf data new (hir-buffer-data buffer) new)))
    (setf (svref data count) value (hir-buffer-count buffer) (1+ count)))
  value)

(defun hir-vector (buffer)
  (subseq (hir-buffer-data buffer) 0 (hir-buffer-count buffer)))

;;; Variable flags: assigned, captured, cell, ignorable, dynamic-extent.
(defstruct hir-var
  (name nil) (owner nil) (id -1) (flags 0) (refs 0) (type t)
  (constant nil) (constant-p nil) (policy *hir-policy*))

(defstruct (hir-type-declaration (:constructor make-hir-type-declaration (original expanded)))
  original expanded)

;;; Function flags: escapes, closure, single call, direct calls, inlined, analyzed,
;;; local definitions, static environment, function aliases.
(defstruct hir-fun
  (name nil) (parent nil) (lambda-list nil) (body nil) (parameter-specials nil)
  (free #()) (exits (make-hir-buffer)) (vars (make-hir-buffer)) (binding-count 0)
  (flags 8) (calls 0) (value-refs 0) (caller nil) (call-site nil) (policy *hir-policy*)
  (source nil) (origin *source-origin*) (binding nil)
  (input-types nil) (result-type t)
  (load-time-values (make-hir-buffer)))

(defstruct (hir-function-alias (:constructor make-hir-function-alias (node owner variable initializer index)))
  (node nil) (owner nil) (variable nil) (initializer nil) (index 0)
  (target nil) (source nil) (users nil) (escaped nil) (used nil))

(defstruct hir-lambda-list
  (required #()) (optional #()) (rest nil) (keys #()) (key-p nil) (allow-other-keys nil))

;;; A parameter is #(variable init supplied-p keyword). Init forms see only
;;; earlier parameters. Special parameters use lexical argument temporaries.
(defstruct hir-exit
  (name nil) (owner nil) (group nil) (token nil) (flags 0) (index 0))

(defstruct (hir-env (:constructor make-hir-env (parent base &key vars funcs blocks tags declarations)))
  (parent nil) (base nil) (vars nil) (funcs nil) (blocks nil) (tags nil) (declarations nil) (types nil))

(declaim (inline hir-env hir-raw hir-new-var))
(defun hir-env (parent &key vars funcs blocks tags declarations)
  (make-hir-env parent (if (hir-env-p parent) (hir-env-base parent) parent)
               :vars vars :funcs funcs :blocks blocks :tags tags :declarations declarations))

(defvar *hir-lowering-epoch*)
(defvar *hir-native-environments* nil)
(defvar *hir-lifted-environments* nil)
(defvar *hir-function*)
(defvar *hir-source* nil)
(defvar *hir-file-id* 0)
(defvar *hir-source-files*)
(defvar *hir-current-source-file*)
(defvar *hir-conversion-depth* 0)
(defvar *hir-top-cst* nil)
(defvar *hir-form-sources* nil
  "Cons subforms of the top-level form being converted -> their source
position. A macro's expansion is a plain form, but the subforms that the
macro passes through are the ones the reader made: their positions are
found here.")
(defvar *macro-source* nil)

(defun hir-source-file-number (file)
  (unless (equal file *hir-current-source-file*)
    (setf *hir-current-source-file* file
          *hir-file-id*
          (or (position file (hir-buffer-data *hir-source-files*)
                        :end (hir-buffer-count *hir-source-files*) :test #'equal)
              (prog1 (hir-buffer-count *hir-source-files*) (hir-push file *hir-source-files*)))))
  *hir-file-id*)

(defun hir-source-position (file start end)
  (unless (and (typep file '(unsigned-byte 12))
               (typep start '(unsigned-byte 25))
               (typep end '(unsigned-byte 25)) (<= start end))
    (fail "HIR source location exceeds its representation: file ~S, ~S..~S" file start end))
  (logior (ash file 50) (ash start 25) end))

(defun hir-source-range (source)
  (and source (cons (ldb (byte 25 25) source) (ldb (byte 25 0) source))))

(defun hir-source-file-id (source)
  (and source (ash source -50)))

(defun hir-raw (form)
  (if (typep form 'cst:cst) (cst:raw form) form))

(defun hir-error (control &rest args)
  (let ((*print-circle* t) (*print-level* 8) (*print-length* 16))
    (error 'kiln-program-error
           :message (format nil "~A~@[ in ~A~]~@[ at ~S~]"
                            (apply #'format nil control args)
                            *source-file* (hir-source-range *hir-source*)))))

(defun hir-proper-list-p (x)
  (cond ((null x) t)
        ((not (consp x)) nil)
        (t (loop for fast = (cdr x) then (cddr fast)
                 for slow = x then (cdr slow)
                 do (when (null fast) (return t))
                    (when (or (not (consp fast)) (eq fast slow)) (return nil))
                    (when (null (cdr fast)) (return t))
                    (when (not (consp (cdr fast))) (return nil))))))

(defun hir-parts (form)
  (let ((raw (hir-raw form)))
    (unless (hir-proper-list-p raw)
      (hir-error "Expected a finite proper list, got ~S" raw))
    (if (typep form 'cst:cst)
        (loop for tail = form then (cst:rest tail)
              while (cst:consp tail) collect (cst:first tail))
        raw)))

(defun hir-adopt-var (var owner)
  (setf (hir-var-owner var) owner (hir-var-id var) (hir-fun-binding-count owner))
  (incf (hir-fun-binding-count owner))
  (hir-push var (hir-fun-vars owner)))

(defun hir-new-var (name &optional (owner *hir-function*))
  (hir-adopt-var (make-hir-var :name name) owner))

(defun hir-new-exit (name &optional group (index 0))
  (let ((exit (make-hir-exit :name name :owner *hir-function* :group group :index index)))
    (unless group
      (setf (hir-exit-group exit) exit))
    exit))

(defun hir-wrap-block (exit body)
  (if (logtest 2 (hir-exit-flags exit))
      (progn
        (setf (hir-exit-token exit) (hir-new-var (gensym "EXIT") (hir-exit-owner exit)))
        (hir-node 14 *hir-source* exit body))
      body))

(defun hir-note-ref (var &optional assigned)
  (incf (hir-var-refs var))
  (when assigned (setf (hir-var-flags var) (logior 1 (hir-var-flags var))))
  (unless (eq (hir-var-owner var) *hir-function*)
    (setf (hir-var-flags var) (logior 2 (hir-var-flags var))))
  var)

(defun hir-note-local-functions (fun)
  (loop for owner = fun then (hir-fun-parent owner)
        while (and owner (not (logtest 64 (hir-fun-flags owner))))
        do (setf (hir-fun-flags owner) (logior 64 (hir-fun-flags owner)))))

(defun hir-note-function-aliases (fun)
  (loop for owner = fun then (hir-fun-parent owner)
        while (and owner (not (logtest 256 (hir-fun-flags owner))))
        do (setf (hir-fun-flags owner) (logior 256 (hir-fun-flags owner)))))

(defun hir-note-call (fun)
  (incf (hir-fun-calls fun))
  (setf (hir-fun-caller fun) *hir-function*)
  fun)

(defun hir-own-function (node)
  "The function defined by NODE, or NIL for a reference to a local function."
  (let ((callee (and (member (hir-node-kind node) '(6 7)) (hir-node-a node))))
    (and (hir-fun-p callee) (null (hir-fun-binding callee)) callee)))

(defun hir-map-children (function node)
  "Visit tree children in evaluation order; definition edges are excluded."
  (flet ((one (child) (when child (funcall function child)))
         (many (children) (loop for child across children do (funcall function child))))
    (case (hir-node-kind node)
      ((0 1 3 5 17) nil)
      ((2 4 15 23) (one (hir-node-b node)))
      ((6 7)
       (let ((callee (hir-node-a node)))
         (cond ((hir-node-p callee) (one callee))
               ((hir-own-function node) (one (hir-fun-body callee)))))
       (when (= (hir-node-kind node) 7) (many (hir-node-b node))))
      ((8 10) (many (hir-node-a node)))
      (9 (one (hir-node-a node)) (one (hir-node-b node)) (one (hir-node-c node)))
      (11 (many (hir-node-b node)) (one (hir-node-c node)))
      (12 (one (hir-node-b node)) (one (hir-node-c node)))
      (13 (loop for fun across (hir-node-a node) do (one (hir-fun-body fun)))
          (one (hir-node-b node)))
      (14 (one (hir-node-b node)))
      (16 (loop for segment across (hir-node-a node) do (one (cdr segment))))
      ((18 19 20 22) (one (hir-node-a node)) (one (hir-node-b node)))
      (21 (one (hir-node-a node)) (many (hir-node-b node)))
      (24 (one (hir-fun-body (hir-node-a node))))
      (25 (one (hir-node-a node)) (one (hir-node-b node)) (one (hir-node-c node)))
      (otherwise (hir-error "Unknown HIR node kind ~S" (hir-node-kind node))))))
