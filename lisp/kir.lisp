(in-package #:kiln.kir)

;;;; KIR construction and printing; the grammar is the reader's in
;;;; rust/kiln-cg/src/kir.rs.
;;;;
;;;; KIR is represented as lists. Operators are keywords (printed in lower
;;;; case); variables, blocks and slots are simple vectors (printed as v12,
;;;; b3, s4); names of module-level symbols are strings. The empty list prints
;;;; as (), the keyword :NIL as nil.

;;; Module

(defstruct (kmodule (:constructor %make-kmodule (name)))
  name
  (init nil)
  (imports '())
  (import-data '())
  (data '())
  (funcs '())
  (roots '())
  (shared '())
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

(defun module-root (data index)
  "Declares word INDEX of the data object DATA a GC root."
  (push `(:root ,data ,index) (kmodule-roots *module*)))

(defun module-shared (name)
  "Declares the data object or function NAME shared: other modules may
define it identically (symbols and what belongs to them), and kiln-cg
keeps one definition."
  (push name (kmodule-shared *module*))
  name)

(defun module-init (name)
  (setf (kmodule-init *module*) name))

;;; Function under construction

(defstruct kfunc
  name
  (debug nil)                           ; (:DEBUG word) or (:DEBUG-REF data offset)
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

(defun decimal-string (n)
  "The decimal digits of the integer N."
  (if (minusp n)
      (kir-name "-" (- n))
      (let ((digits '()))
        (loop do (multiple-value-bind (q r) (floor n 10)
                   (push (code-char (+ (char-code #\0) r)) digits)
                   (setf n q))
              while (plusp n))
        (coerce digits 'string))))

(defun kir-name (&rest parts)
  "The concatenation of PARTS: strings, symbols (their names) and integers
(in decimal), as (FORMAT NIL \"~A~A...\" ...) makes it, without FORMAT,
which is slow on kiln: names of variables, blocks and
labels are made for every one of them."
  (let* ((strings (mapcar (lambda (x)
                            (etypecase x
                              (string x)
                              (symbol (symbol-name x))
                              (integer (decimal-string x))))
                          parts))
         (result (make-string (reduce #'+ strings :key #'length)))
         (i 0))
    (dolist (string strings result)
      (dotimes (j (length string))
        (setf (char result i) (char string j))
        (incf i)))))

;;; The name of a variable, block or slot of the function: a simple vector
;;; #(LETTER NUMBER), unique in the function and printed as the letter
;;; and the number (v12, b3, s4); a variable's has two more elements, its
;;; kind (:OBJ or :RAW) and the index of the source variable it holds in
;;; the debug info, or NIL. Nothing else in KIR is a vector but a string.
;;; Interning a keyword for each name was a few percent of the time of
;;; kiln compiling itself, and making a structure costs about as much.

(defun fresh-number ()
  (incf (kfunc-counter *func*)))

(defun kvar-p (x)
  "Is X a variable?"
  (and (simple-vector-p x) (= (length x) 4)))

(defun new-var (&optional (kind :obj))
  (let ((v (vector #\v (fresh-number) kind nil)))
    (push v (kfunc-vars *func*))
    v))

(defun label-var (var index)
  "Marks the variable VAR as holding the source variable whose name has
INDEX in the function's debug info (lower.lisp)."
  (setf (svref var 3) index))

(defun var-declaration (var)
  (if (svref var 3)
      (list var (svref var 2) (svref var 3))
      (list var (svref var 2))))

(defun new-slot (size)
  (let ((s (vector #\s (fresh-number))))
    (push (list s size) (kfunc-slots *func*))
    s))

(defun new-block ()
  (let ((b (make-kblock :name (vector #\b (fresh-number)))))
    (push b (kfunc-blocks *func*))
    b))

(defun start-block (block)
  (setf (kfunc-current *func*) block))

(defun current-block-terminated-p ()
  (kblock-terminated (kfunc-current *func*)))

(defparameter *terminators* '(:jump :br :switch :return :trap))

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
                  (:vars ,@(mapcar #'var-declaration (reverse (kfunc-vars *func*))))
                  (:slots ,@(reverse (kfunc-slots *func*)))
                  ,@(and (kfunc-debug *func*) (list (kfunc-debug *func*)))
                  ,@(mapcar (lambda (b)
                              `(:block ,(kblock-name b) ,@(reverse (kblock-stmts b))))
                            blocks))
          (kmodule-funcs *module*))))

;;; Printing. Each form is built in a string, written with one
;;; WRITE-STRING: on kiln, writing a character to a stream is a generic
;;; function call and an unbuffered write.

(defvar *out*)                          ; simple string being filled
(defvar *fill*)                         ; its fill index
;;; A string that PRINT-KIR may fill, kept by PRINT-MODULE from one form
;;; to the next: a form started in a new small string, which grew by
;;; copying until the form fit, and REPLACE copies a character at a time.
(defvar *spare-out* nil)

(defun out-char (c)
  (when (= *fill* (length *out*))
    (let ((new (make-string (* 2 (length *out*)))))
      (replace new *out*)
      (setf *out* new)))
  (setf (aref *out* *fill*) c)
  (setf *fill* (+ *fill* 1)))

(defun out-string (string)
  (loop for c across string do (out-char c)))

(defun out-integer (n)
  (cond ((minusp n) (out-char #\-) (out-integer (- n)))
        ((< n 10) (out-char (code-char (+ (char-code #\0) n))))
        (t (out-integer (floor n 10))
           (out-char (code-char (+ (char-code #\0) (mod n 10)))))))

(defun out-kir (x)
  (etypecase x
    (null (out-string "()"))
    (keyword (loop for c across (symbol-name x) do (out-char (char-downcase c))))
    (simple-vector (out-char (svref x 0)) (out-integer (svref x 1)))
    (string
     (out-char #\")
     (loop for c across x
           do (when (or (eql c #\") (eql c #\\)) (out-char #\\))
              (out-char c))
     (out-char #\"))
    (integer (out-integer x))
    (cons
     (out-char #\()
     (loop for (item . rest) on x
           do (out-kir item)
              (when rest (out-char #\Space)))
     (out-char #\)))))

(defun print-kir (x stream)
  (let ((*out* (or *spare-out* (make-string 256))) (*fill* 0))
    (out-kir x)
    (write-string *out* stream :end *fill*)
    (when *spare-out*
      (setf *spare-out* *out*))))

(defun out-module (module)
  (out-string "(module ")
  (out-kir (kmodule-name module))
  (out-char #\Newline)
  (out-string "  ")
  (out-kir `(:init ,(kmodule-init module)))
  (when (kmodule-shared module)
    (out-char #\Newline)
    (out-string "  ")
    (out-kir `(:shared ,@(reverse (kmodule-shared module)))))
  (dolist (group (list (reverse (kmodule-imports module))
                       (reverse (kmodule-import-data module))
                       (reverse (kmodule-data module))
                       (reverse (kmodule-roots module))
                       (reverse (kmodule-funcs module))))
    (dolist (form group)
      (out-char #\Newline)
      (out-string "  ")
      (out-kir form)))
  (out-char #\)))

(defun module-string (module)
  "The text of MODULE, as PRINT-MODULE writes it, without the last newline."
  (let ((*out* (make-string 4096)) (*fill* 0))
    (out-module module)
    (subseq *out* 0 *fill*)))

(defun print-module (module stream)
  ;; Form by form: the text of a large module is large.
  (let ((*spare-out* (make-string 4096)))
    (print-module-forms module stream)))

(defun print-module-forms (module stream)
  (write-string "(module " stream)
  (print-kir (kmodule-name module) stream)
  (write-string (string #\Newline) stream)
  (write-string "  " stream)
  (print-kir `(:init ,(kmodule-init module)) stream)
  (when (kmodule-shared module)
    (write-string (string #\Newline) stream)
    (write-string "  " stream)
    (print-kir `(:shared ,@(reverse (kmodule-shared module))) stream))
  (dolist (group (list (reverse (kmodule-imports module))
                       (reverse (kmodule-import-data module))
                       (reverse (kmodule-data module))
                       (reverse (kmodule-roots module))
                       (reverse (kmodule-funcs module))))
    (dolist (form group)
      (write-string (string #\Newline) stream)
      (write-string "  " stream)
      (print-kir form stream)))
  (write-string ")" stream)
  (write-string (string #\Newline) stream))
