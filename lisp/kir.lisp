(in-package #:kiln.kir)

;;;; KIR construction and printing. Grammar: docs/06-m0-abi.md.
;;;;
;;;; KIR is represented as lists. Operators, variables, blocks and slots are
;;;; keywords (printed in lower case); names of module-level symbols are
;;;; strings. The empty list prints as (), the keyword :NIL as nil.

;;; Module

(defstruct (kmodule (:constructor %make-kmodule (name)))
  name
  (init nil)
  (imports '())
  (import-data '())
  (data '())
  (funcs '())
  (defined (make-hash-table :test 'equal)))

(defun make-kmodule (name)
  (%make-kmodule name))

(defvar *module*)

(defun declare-once (name)
  "Returns true the first time NAME is declared in the current module."
  (let ((table (kmodule-defined *module*)))
    (unless (gethash name table)
      (setf (gethash name table) t))))

(defun module-import-func (name params returns &rest flags)
  (when (declare-once name)
    (push `(:import-func ,name ,params ,returns ,@flags) (kmodule-imports *module*)))
  name)

(defun module-import-data (name)
  (when (declare-once name)
    (push `(:import-data ,name) (kmodule-import-data *module*)))
  name)

(defun module-data (name contents)
  "CONTENTS is (:words ...) or (:bytes \"...\")."
  (when (declare-once name)
    (push `(:data ,name ,contents) (kmodule-data *module*)))
  name)

(defun module-init (name)
  (setf (kmodule-init *module*) name))

;;; Function under construction

(defstruct kfunc
  name
  (vars '())
  (slots '())
  (blocks '())
  (current nil)
  (counter 0))

(defstruct kblock
  name
  (stmts '())
  (terminated nil))

(defvar *func*)

(defun fresh-name (prefix)
  (intern (format nil "~A~D" prefix (incf (kfunc-counter *func*))) :keyword))

(defun new-var (&optional (kind :obj))
  (let ((v (fresh-name "V")))
    (push (list v kind) (kfunc-vars *func*))
    v))

(defun new-slot (size)
  (let ((s (fresh-name "S")))
    (push (list s size) (kfunc-slots *func*))
    s))

(defun new-block ()
  (let ((b (make-kblock :name (fresh-name "B"))))
    (push b (kfunc-blocks *func*))
    b))

(defun start-block (block)
  (setf (kfunc-current *func*) block))

(defun current-block-terminated-p ()
  (kblock-terminated (kfunc-current *func*)))

(defparameter *terminators* '(:jump :br :return :trap))

(defun emit (stmt)
  "Appends STMT to the current block. Statements after a terminator are
dropped (they are unreachable)."
  (let ((b (kfunc-current *func*)))
    (unless (kblock-terminated b)
      (push stmt (kblock-stmts b))
      (when (member (first stmt) *terminators*)
        (setf (kblock-terminated b) t))))
  (values))

(defun kblock-ref (b) (kblock-name b))

(defmacro with-function ((name) &body body)
  "Builds a function named NAME in the current module; BODY runs with an
entry block current. Unterminated blocks end with a trap."
  `(let ((*func* (make-kfunc :name ,name)))
     (start-block (new-block))
     ,@body
     (finish-function)))

(defun finish-function ()
  (let ((blocks (reverse (kfunc-blocks *func*))))
    (dolist (b blocks)
      (unless (kblock-terminated b)
        (start-block b)
        (emit '(:trap))))
    (push `(:func ,(kfunc-name *func*)
                  (:vars ,@(reverse (kfunc-vars *func*)))
                  (:slots ,@(reverse (kfunc-slots *func*)))
                  ,@(mapcar (lambda (b)
                              `(:block ,(kblock-name b) ,@(reverse (kblock-stmts b))))
                            blocks))
          (kmodule-funcs *module*))))

;;; Printing

(defun print-kir (x stream)
  (etypecase x
    (null (write-string "()" stream))
    (keyword (write-string (string-downcase (symbol-name x)) stream))
    (string
     (write-char #\" stream)
     (loop for c across x
           do (when (member c '(#\" #\\)) (write-char #\\ stream))
              (write-char c stream))
     (write-char #\" stream))
    (integer (format stream "~D" x))
    (cons
     (write-char #\( stream)
     (loop for (item . rest) on x
           do (print-kir item stream)
              (when rest (write-char #\Space stream)))
     (write-char #\) stream))))

(defun print-module (module stream)
  (format stream "(module ")
  (print-kir (kmodule-name module) stream)
  (format stream "~%  ")
  (print-kir `(:init ,(kmodule-init module)) stream)
  (dolist (group (list (reverse (kmodule-imports module))
                       (reverse (kmodule-import-data module))
                       (reverse (kmodule-data module))
                       (reverse (kmodule-funcs module))))
    (dolist (form group)
      (format stream "~%  ")
      (print-kir form stream)))
  (format stream ")~%"))
