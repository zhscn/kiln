(in-package #:kiln.compiler)

(defvar *source-file*)

;;;; Tree edges live in node operands; references to variables, functions,
;;;; and exits are definition edges and are never traversed as children.
;;;; Kinds: 0 constant, 1 ref, 2 set, 3 special-ref, 4 special-set,
;;;; 5 global-function, 6 function, 7 call, 8 primop, 9 if, 10 progn,
;;;; 11 let, 12 bind, 13 local-functions, 14 block, 15 return,
;;;; 16 tagbody, 17 go, 18 catch, 19 throw, 20 unwind-protect,
;;;; 21 multiple-value-call, 22 multiple-value-prog1, 23 the,
;;;; 24 load-time-value, 25 progv.
(defstruct (ir-node (:constructor ir-node (kind source &optional a b c d)))
  (kind 0) (source nil) (a nil) (b nil) (c nil) (d nil) (type t) (mark 0))

(defstruct (ir-buffer (:constructor make-ir-buffer (&optional (data (make-array 8)))))
  (data nil) (count 0))

(defun ir-push (value buffer)
  (let* ((data (ir-buffer-data buffer)) (count (ir-buffer-count buffer)))
    (when (= count (length data))
      (let ((new (make-array (max 8 (* 2 count)))))
        (dotimes (i count) (setf (svref new i) (svref data i)))
        (setf data new (ir-buffer-data buffer) new)))
    (setf (svref data count) value (ir-buffer-count buffer) (1+ count)))
  value)

(defun ir-vector (buffer)
  (subseq (ir-buffer-data buffer) 0 (ir-buffer-count buffer)))

;;; Variable flags: assigned, captured, cell, ignorable, dynamic-extent.
(defstruct ir-var
  (name nil) (owner nil) (flags 0) (refs 0) (type t)
  (lowering nil) (constant nil) (constant-p nil))

;;; Function flags: escapes, closure, single call, direct calls, inlined, analyzed.
(defstruct ir-fun
  (name nil) (parent nil) (lambda-list nil) (body nil) (parameter-specials nil)
  (free #()) (exits (make-ir-buffer)) (vars (make-ir-buffer))
  (flags 8) (calls 0) (value-refs 0) (caller nil) (call-site nil) (policy nil)
  (source nil) (binding nil) (label nil) (lowering-epoch nil)
  (load-time-values (make-ir-buffer)))

(defstruct ir-lambda-list
  (required #()) (optional #()) (rest nil) (keys #()) (key-p nil) (allow-other-keys nil))

;;; A parameter is #(variable init supplied-p keyword). Init forms see only
;;; earlier parameters. Special parameters use lexical argument temporaries.
(defstruct ir-exit
  (name nil) (owner nil) (group nil) (token nil) (flags 0) (index 0) (lowering nil))

(defstruct (ir-env (:constructor ir-env (parent &key vars funcs blocks tags declarations)))
  (parent nil) (vars nil) (funcs nil) (blocks nil) (tags nil) (declarations nil))

(defvar *ir-lowering-epoch*)
(defvar *ir-function*)
(defvar *ir-source* nil)
(defvar *ir-file-id* 0)
(defvar *ir-source-files*)
(defvar *ir-current-source-file*)
(defvar *ir-conversion-depth* 0)

(defun ir-source-file-number (file)
  (unless (equal file *ir-current-source-file*)
    (setf *ir-current-source-file* file
          *ir-file-id*
          (or (position file (ir-buffer-data *ir-source-files*)
                        :end (ir-buffer-count *ir-source-files*) :test #'equal)
              (prog1 (ir-buffer-count *ir-source-files*) (ir-push file *ir-source-files*)))))
  *ir-file-id*)

(defun ir-source-position (file start end)
  (unless (and (typep file '(unsigned-byte 12))
               (typep start '(unsigned-byte 25))
               (typep end '(unsigned-byte 25)) (<= start end))
    (fail "IR source location exceeds its representation: file ~S, ~S..~S" file start end))
  (logior (ash file 50) (ash start 25) end))

(defun ir-source-range (source)
  (and source (cons (ldb (byte 25 25) source) (ldb (byte 25 0) source))))

(defun ir-source-file-id (source)
  (and source (ash source -50)))

(defun ir-raw (form)
  (if (typep form 'cst:cst) (cst:raw form) form))

(defun ir-error (control &rest args)
  (let ((*print-circle* t) (*print-level* 8) (*print-length* 16))
    (fail "~A~@[ in ~A~]~@[ at ~S~]" (apply #'format nil control args)
          *source-file* (ir-source-range *ir-source*))))

(defun ir-parts (form)
  (let ((raw (ir-raw form)))
    (unless (handler-case (and (listp raw) (list-length raw) t) (type-error () nil))
      (ir-error "Expected a finite proper list, got ~S" raw))
    (if (typep form 'cst:cst)
        (loop for tail = form then (cst:rest tail)
              while (cst:consp tail) collect (cst:first tail))
        raw)))

(defun ir-new-var (name &optional (owner *ir-function*))
  (let ((var (make-ir-var :name name :owner owner)))
    (ir-push var (ir-fun-vars owner))))

(defun ir-new-exit (name &optional group (index 0))
  (let ((exit (make-ir-exit :name name :owner *ir-function* :group group :index index)))
    (unless group
      (setf (ir-exit-group exit) exit
            (ir-exit-token exit) (ir-new-var (gensym "EXIT"))))
    exit))

(defun ir-note-ref (var &optional assigned)
  (incf (ir-var-refs var))
  (when assigned (setf (ir-var-flags var) (logior 1 (ir-var-flags var))))
  (unless (eq (ir-var-owner var) *ir-function*)
    (setf (ir-var-flags var) (logior 2 (ir-var-flags var))))
  var)

(defun ir-note-call (fun)
  (incf (ir-fun-calls fun))
  (setf (ir-fun-caller fun) *ir-function*)
  fun)

(defun ir-own-function (node)
  "The function defined by NODE, or NIL for a reference to a local function."
  (let ((callee (and (member (ir-node-kind node) '(6 7)) (ir-node-a node))))
    (and (ir-fun-p callee) (null (ir-fun-binding callee)) callee)))

(defun ir-map-children (function node)
  "Visit tree children in evaluation order; definition edges are excluded."
  (flet ((one (child) (when child (funcall function child)))
         (many (children) (loop for child across children do (funcall function child))))
    (case (ir-node-kind node)
      ((0 1 3 5 17) nil)
      ((2 4 15 23) (one (ir-node-b node)))
      ((6 7)
       (let ((callee (ir-node-a node)))
         (cond ((ir-node-p callee) (one callee))
               ((ir-own-function node) (one (ir-fun-body callee)))))
       (when (= (ir-node-kind node) 7) (many (ir-node-b node))))
      ((8 10) (many (ir-node-a node)))
      (9 (one (ir-node-a node)) (one (ir-node-b node)) (one (ir-node-c node)))
      (11 (many (ir-node-b node)) (one (ir-node-c node)))
      (12 (one (ir-node-b node)) (one (ir-node-c node)))
      (13 (loop for fun across (ir-node-a node) do (one (ir-fun-body fun)))
          (one (ir-node-b node)))
      (14 (one (ir-node-b node)))
      (16 (loop for segment across (ir-node-a node) do (one (cdr segment))))
      ((18 19 20 22) (one (ir-node-a node)) (one (ir-node-b node)))
      (21 (one (ir-node-a node)) (many (ir-node-b node)))
      (24 (one (ir-fun-body (ir-node-a node))))
      (25 (one (ir-node-a node)) (one (ir-node-b node)) (one (ir-node-c node)))
      (otherwise (ir-error "Unknown IR node kind ~S" (ir-node-kind node))))))
