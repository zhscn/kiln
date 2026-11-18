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
  ;; Executing a module with load-time cells again would change old closures.
  (replayable-p t)
  (init nil)
  (imports '())
  (import-data '())
  (data '())
  (functions '())
  (roots '())
  (shared '())
  (defined (make-hash-table :test 'equal))
  (function-captures (make-hash-table :test 'equal))
  (capture-shapes-complete-p nil))

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

(defun module-builtin (kind scope)
  "Requests a backend entry by its fixed role and compilation scope."
  (when (declare-once (list :builtin kind))
    (push `(:builtin ,kind ,scope) (kmodule-data *module*)))
  kind)

(defun module-object-cell (name initial)
  "Defines a mutable object cell initialized from INITIAL."
  (when (declare-once name)
    (push `(:object-cell ,name ,initial) (kmodule-data *module*)))
  name)

(defun module-literal-table (count)
  (push `(:literal-table ,count) (kmodule-data *module*)))

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
  (direct-regions-p nil)
  (region-entries nil)
  (region-landings nil)
  (current nil)
  (counter 0))

(defstruct emitted-region
  slot kind parents block tag)

(defstruct emitted-landing
  slot handler target forward outer-handler)

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

(defun emit (stmt)
  "Appends STMT to the current block. Statements after a terminator are
dropped (they are unreachable)."
  (let ((b (kfunc-current *func*)))
    (unless (kblock-terminated b)
      (push stmt (kblock-stmts b))
      (case (first stmt)
        ((:jump :br :switch :return :tail-call-lisp :tail-invoke :forward-incoming :signal-error :fatal-error :unwind-values :continue-unwind :trap)
         (setf (kblock-terminated b) t)))))
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
  (let ((blocks (nreverse (kfunc-blocks *func*))))
    (dolist (block blocks)
      (unless (kblock-terminated block)
        (start-block block)
        (emit '(:trap)))
      (setf (kblock-stmts block) (nreverse (kblock-stmts block))))
    (setf (kfunc-blocks *func*) blocks
          (kfunc-vars *func*) (nreverse (kfunc-vars *func*))
          (kfunc-slots *func*) (nreverse (kfunc-slots *func*))
          (kfunc-current *func*) nil)
    (push *func* (kmodule-functions *module*))))

(defun kfunc-form (function)
  (unless (kfunc-p function) (return-from kfunc-form function))
  (let ((dispatches (when (kfunc-region-landings function) (make-hash-table :test 'eq))))
    (dolist (entry (kfunc-region-landings function))
      (setf (gethash (emitted-landing-handler entry) dispatches)
            (list `(:br (:unwind-target-p ,(emitted-landing-slot entry))
                        ,(emitted-landing-target entry) ,(emitted-landing-forward entry)))
            (gethash (emitted-landing-forward entry) dispatches)
            (list (if (eq (emitted-landing-outer-handler entry) :nil)
                      '(:trap)
                      (list :jump (emitted-landing-outer-handler entry))))))
    `(:func ,(kfunc-name function)
      (:vars ,@(mapcar #'var-declaration (kfunc-vars function)))
      (:slots ,@(kfunc-slots function))
      ,@(and (kfunc-debug function) (list (kfunc-debug function)))
      ,@(mapcar (lambda (block)
                  (let ((name (kblock-name block)))
                    (list* :block name (or (and dispatches (gethash name dispatches))
                                           (kblock-stmts block)))))
                (kfunc-blocks function)))))

(defun kmodule-funcs (module)
  "Materialize compatibility function forms for diagnostics and tests."
  (mapcar #'kfunc-form (kmodule-functions module)))

(defun (setf kmodule-funcs) (forms module)
  (setf (kmodule-functions module) forms))

(defstruct static-symbol
  name package name-label package-word undefined-label undefined-setf-label)

(defun static-symbol-form (label symbol)
  `(:static-symbol (:object-data ,(static-symbol-name-label symbol) :general)
                   ,(static-symbol-package-word symbol)
                   (:object-data ,(static-symbol-undefined-label symbol) :general)
                   ,(if (equal (static-symbol-package symbol) "KEYWORD")
                        `(:object-data ,label :general)
                        '(:unbound))
                   (:object-data "kiln_nil" :general)
                   (:object-data ,(static-symbol-undefined-setf-label symbol) :general)))

(defun kmodule-data-forms (module)
  (loop for form in (kmodule-data module)
        for object = (and (eq (first form) :data) (third form))
        collect (cond ((stringp object)
                       (list :data (second form) (cons :static-string (map 'list #'char-code object))))
                      ((static-symbol-p object)
                       (list :data (second form) (static-symbol-form (second form) object)))
                      (t form))))

(defun source-function-debug (function)
  (if (kfunc-p function)
      (kfunc-debug function)
      (or (assoc :debug (cddr function)) (assoc :debug-literal (cddr function)))))

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
  #+kiln (when (kiln.sys::%write-kir x stream) (return-from print-kir x))
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
                       (reverse (kmodule-data-forms module))
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
  (let ((groups (list (list `(:init ,(kmodule-init module)))
                      (and (kmodule-shared module)
                           (list `(:shared ,@(nreverse (kmodule-shared module)))))
                      (nreverse (kmodule-imports module))
                      (nreverse (kmodule-import-data module))
                      (nreverse (kmodule-data-forms module))
                      (nreverse (kmodule-roots module))
                      (nreverse (kmodule-funcs module)))))
    #+kiln
    (when (kiln.sys::%write-kir (cons (kmodule-name module) groups) stream)
      (return-from print-module-forms))
    (write-string "(module " stream)
    (print-kir (kmodule-name module) stream)
    (dolist (group groups)
      (dolist (form group)
        (write-string (string #\Newline) stream)
        (write-string "  " stream)
        (print-kir form stream)))
    (write-string ")" stream)
    (write-string (string #\Newline) stream)))
