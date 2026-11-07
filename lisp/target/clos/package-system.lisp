;;;; kiln's client of Parcl, and the bootstrap of the run-time packages
;;;;.
;;;;
;;;; Every module's symbol table (lower.lisp) describes the host packages
;;;; its symbols were read into: name, nicknames, use list, and the status
;;;; of each of its symbols in them. Modules push their tables onto
;;;; KILN.KERNEL::*MODULE-SYMBOL-TABLES* when they start; once this file is
;;;; loaded, %REGISTER-MODULE-SYMBOLS turns them into package objects and
;;;; replaces each symbol's package name (a string) with its home package.
;;;; Modules loaded later call it themselves.

(in-package #:parcl)

(defclass kiln-client (parcl-low-class:client) ())

(setf *client* (make-instance 'kiln-client))

;;; Symbols

(defmethod parcl-low:make-symbol ((client kiln-client) name package)
  (let ((symbol (make-symbol name)))
    (unless (null package)
      (kiln.sys:%primop :set-symbol-package symbol package)
      (when (eq package kiln.kernel::*keyword-package*)
        (kiln.sys:%primop :set-symbol-global-value symbol symbol)))
    symbol))

(defmethod parcl-low:symbol-name ((client kiln-client) symbol)
  (symbol-name symbol))

(defmethod parcl-low:symbol-package ((client kiln-client) symbol)
  (symbol-package symbol))

(defmethod (setf parcl-low:symbol-package) (new-package (client kiln-client) symbol)
  (kiln.sys:%primop :set-symbol-package symbol new-package))

(defmethod parcl-low:symbol-names-equal ((client kiln-client) symbol1 symbol2)
  (string= (symbol-name symbol1) (symbol-name symbol2)))

;;; A symbol interned in KEYWORD is external (Parcl leaves it to the
;;; client).
(defmethod parcl-low:intern :around ((client kiln-client) package name)
  (multiple-value-bind (symbol status) (call-next-method)
    (when (and (null status) (eq package kiln.kernel::*keyword-package*))
      (parcl-low:ensure-present-symbol client package symbol :external))
    (values symbol status)))

;;; Symbol tables

(defmethod parcl-low:make-table ((client kiln-client))
  (make-hash-table :test 'equal))

(defmethod parcl-low:name-to-entry ((client kiln-client) name table)
  (gethash name table))

(defmethod (setf parcl-low:name-to-entry) (new-entry (client kiln-client) name table)
  (setf (gethash name table) new-entry))

(defmethod parcl-low:remove-entry ((client kiln-client) name table)
  (remhash name table))

;;; The package registry: names and nicknames to packages.

(defvar *packages* (make-hash-table :test 'equal))

(defmethod find-package ((designator package))
  designator)

;;; A name is first looked up among the local nicknames of the current
;;; package.
(defun lookup-package (name)
  (or (and (boundp '*package*) (packagep *package*)
           (second (assoc name (parcl-low:local-nicknames *client* *package*)
                          :test #'string=)))
      (values (gethash name *packages*))))

(defmethod find-package ((designator string))
  (lookup-package designator))

(defmethod find-package ((designator symbol))
  (lookup-package (symbol-name designator)))

(defmethod find-package ((designator character))
  (lookup-package (string designator)))

(defun package-local-nicknames (package)
  "The local nicknames of PACKAGE: conses (NICKNAME . PACKAGE)."
  (mapcar (lambda (entry) (cons (first entry) (second entry)))
          (parcl-low:local-nicknames *client* (find-package-or-error package))))

(defun find-package-or-error (designator)
  (or (find-package designator)
      (error 'package-error :package designator)))

(defmethod store-package (package name nicknames)
  (dolist (n (cons name nicknames))
    (let ((existing (gethash n *packages*)))
      (unless (or (null existing) (eq existing package))
        (error 'package-error :package n))))
  (dolist (n (cons name nicknames))
    (setf (gethash n *packages*) package)))

(defun list-all-packages ()
  (let ((result '()))
    (maphash (lambda (name package)
               (declare (ignore name))
               (pushnew package result))
             *packages*)
    result))

(defun packagep (object)
  (typep object 'package))

(defun rename-package (package new-name &optional new-nicknames)
  (let ((package (find-package-or-error package))
        (new-name (string new-name))
        (new-nicknames (mapcar #'string new-nicknames)))
    (remhash (parcl-low:name *client* package) *packages*)
    (dolist (n (parcl-low:nicknames *client* package))
      (remhash n *packages*))
    (setf (parcl-low:name *client* package) new-name
          (parcl-low:nicknames *client* package) new-nicknames)
    (store-package package new-name new-nicknames)
    package))

(defun delete-package (designator)
  (let ((package (find-package designator)))
    (cond ((null package)
           (error 'package-error :package designator))
          ((null (parcl-low:name *client* package))
           nil)
          (t
           (unless (null (parcl-low:used-by-list *client* package))
             (error 'package-error :package package))
           (dolist (used (parcl-low:use-list *client* package))
             (parcl-low:unuse-package *client* package used))
           (dolist (entry (parcl-low:symbol-entries *client* package))
             (when (eq (symbol-package (car entry)) package)
               (kiln.sys:%primop :set-symbol-package (car entry) nil)))
           (remhash (parcl-low:name *client* package) *packages*)
           (dolist (n (parcl-low:nicknames *client* package))
             (remhash n *packages*))
           (setf (parcl-low:name *client* package) nil)
           t))))

(defun unintern (symbol &optional (package-designator *package*))
  (parcl-low:unintern *client* (find-package-or-error package-designator) symbol))

;;; GENTEMP (deprecated, but cl-bench's browse uses it).
(defvar *gentemp-counter* 0)

(defun gentemp (&optional (prefix "T") (package *package*))
  (check-type prefix string)
  (loop (let ((name (format nil "~A~D" prefix (incf *gentemp-counter*))))
          (multiple-value-bind (symbol status) (find-symbol name package)
            (declare (ignore symbol))
            (unless status (return (values (intern name package))))))))

(defun find-all-symbols (name)
  (let ((name (string name))
        (result '()))
    (dolist (package (list-all-packages) result)
      (multiple-value-bind (symbol status)
          (parcl-low:find-present-symbol *client* package name)
        (unless (null status)
          (pushnew symbol result))))))

;;; Iteration

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun split-declarations (body)
    (let ((declarations '()))
      (do () ((not (and (consp (first body)) (eq (first (first body)) 'declare))))
        (push (pop body) declarations))
      (values (reverse declarations) body))))

(defun map-package-symbols (function package-designator external-only)
  (let ((package (find-package-or-error package-designator)))
    (if external-only
        (parcl-low:map-external-symbols *client* package function)
        (parcl-low:map-symbols *client* package function))))

(defmacro do-symbols ((var &optional (package '*package*) result) &body body)
  (multiple-value-bind (declarations statements) (split-declarations body)
    `(block nil
       (map-package-symbols (lambda (,var) ,@declarations (tagbody ,@statements))
                            ,package nil)
       (let ((,var nil))
         (declare (ignorable ,var))
         ,result))))

(defmacro do-external-symbols ((var &optional (package '*package*) result) &body body)
  (multiple-value-bind (declarations statements) (split-declarations body)
    `(block nil
       (map-package-symbols (lambda (,var) ,@declarations (tagbody ,@statements))
                            ,package t)
       (let ((,var nil))
         (declare (ignorable ,var))
         ,result))))

(defmacro do-all-symbols ((var &optional result) &body body)
  (multiple-value-bind (declarations statements) (split-declarations body)
    `(block nil
       (dolist (package (list-all-packages))
         (map-package-symbols (lambda (,var) ,@declarations (tagbody ,@statements))
                              package nil))
       (let ((,var nil))
         (declare (ignorable ,var))
         ,result))))

(defun package-iterator-items (package-list symbol-types)
  "A list of (symbol status package) for WITH-PACKAGE-ITERATOR."
  (let ((items '()))
    (dolist (package (if (listp package-list) package-list (list package-list)))
      (let ((package (find-package-or-error package)))
        (dolist (entry (parcl-low:symbol-entries *client* package))
          (let ((status (if (member (cdr entry) '(:external :external-shadowing))
                            :external
                            :internal)))
            (when (member status symbol-types)
              (push (list (car entry) status package) items))))
        (when (member :inherited symbol-types)
          (dolist (used (parcl-low:use-list *client* package))
            (parcl-low:map-external-symbols
             *client* used
             (lambda (symbol)
               (multiple-value-bind (found status)
                   (parcl-low:find-symbol *client* package (symbol-name symbol))
                 (when (and (eq found symbol) (eq status :inherited))
                   (push (list symbol :inherited package) items)))))))))
    (reverse items)))

(defun package-iterator-next (cell)
  (let ((item (pop (car cell))))
    (if (null item)
        nil
        (values t (first item) (second item) (third item)))))

(defmacro with-package-iterator ((name package-list &rest symbol-types) &body body)
  (let ((cell (gensym "ITERATOR")))
    `(let ((,cell (list (package-iterator-items ,package-list ',symbol-types))))
       (macrolet ((,name () (list 'package-iterator-next ',cell)))
         ,@body))))

;;; Bootstrap: the module symbol tables

(defun ensure-package (name)
  (or (find-package name)
      (let ((package (parcl-low:make-package *client* name)))
        (store-package package name '())
        package)))

(defun entry-status (code)
  (case (logand code 3)
    (0 :internal)
    (1 :external)
    (2 :internal-shadowing)
    (3 :external-shadowing)))

(defun register-symbol (package symbol code)
  (let* ((name (symbol-name symbol))
         (table (parcl-low-class::symbol-table package))
         (entry (gethash name table))
         (status (entry-status code)))
    (cond ((null entry)
           (parcl-low-class::add-entry *client* name (cons symbol status) package))
          ((eq (car entry) symbol)
           (setf (cdr entry) status)))
    (when (logbitp 2 code)
      (kiln.sys:%primop :set-symbol-package symbol package))))

(defun lookup-local-nickname (nickname package)
  (second (assoc (string nickname) (parcl-low:local-nicknames *client* package)
                 :test #'string=)))

(defun register-symbol-table (table)
  (let ((uses '()))
    (dotimes (i (length table))
      (let* ((description (svref table i))
             (package (ensure-package (svref description 0)))
             (entries (svref description 3)))
        (let ((nicknames (parcl-low:nicknames *client* package)))
          (dolist (nickname (svref description 1))
            (unless (member nickname nicknames :test #'string=)
              (store-package package (parcl-low:name *client* package) (list nickname))
              (push nickname nicknames)))
          (setf (parcl-low:nicknames *client* package) nicknames))
        (push (list package (svref description 2) (svref description 4)) uses)
        (do ((j 0 (+ j 2)))
            ((>= j (length entries)))
          (register-symbol package (svref entries j) (svref entries (1+ j))))))
    ;; Use lists and local nicknames, once every package of the table
    ;; exists.
    (dolist (use uses)
      (let ((package (first use)))
        (do ((nicknames (third use) (cddr nicknames)))
            ((null nicknames))
          (let ((actual (find-package (second nicknames))))
            ;; Written directly, as the use lists (the host has checked
            ;; them; Parcl's functions are not usable this early).
            (when (and actual (not (lookup-local-nickname (first nicknames) package)))
              (push (list (first nicknames) actual)
                    (parcl-low:local-nicknames *client* package))
              (push package (parcl-low:locally-nicknamed-by *client* actual)))))
        (dolist (name (second use))
          (let ((used (find-package name)))
            (unless (or (null used)
                        (member used (parcl-low:use-list *client* package)))
              (setf (parcl-low:use-list *client* package)
                    (append (parcl-low:use-list *client* package) (list used)))
              (push package (parcl-low:used-by-list *client* used)))))))))

(defun kiln.kernel::%register-module-symbols ()
  (let ((tables (reverse kiln.kernel::*module-symbol-tables*)))
    (setf kiln.kernel::*module-symbol-tables* '())
    (dolist (table tables)
      (register-symbol-table table))))

(kiln.kernel::%register-module-symbols)

;;; NIL and T are not in any symbol table (the runtime defines them).
(let ((cl (find-package "COMMON-LISP")))
  (register-symbol cl nil 5)
  (register-symbol cl t 5))

(setf kiln.kernel::*keyword-package* (ensure-package "KEYWORD"))

;;; COMMON-LISP-USER is the package that the host describes for the
;;; programs it compiles (KILN-USER, lisp/lower.lisp): with the nickname
;;; CL-USER, using CL and KILN.SYS.
(register-symbol-table
 (vector (vector "COMMON-LISP-USER" '("CL-USER") '("COMMON-LISP" "KILN.SYS") (vector) '())))
(setf *package* (find-package "COMMON-LISP-USER"))

;;; DEFPACKAGE and IN-PACKAGE at run time. Compiled modules
;;; get their packages from their symbol tables; these are for code that
;;; runs DEFPACKAGE (also inside a function: the front end expands it
;;; into the same %DEFPACKAGE call) and for macroexpansion at run time.
;;; The macro functions are set at load time only, as LOOP's.

(defun option-arguments (key options)
  (loop for (name . arguments) in options
        when (eq name key) append arguments))

(defun kiln.kernel::%defpackage (name options)
  "Creates or updates the package NAME as DEFPACKAGE with OPTIONS does, in
the order of CLHS: shadows, shadowing imports, use list, imports and
interned symbols, exports; then local nicknames."
  (let* ((name (string name))
         (package (or (find-package name) (make-package name :use '()))))
    (rename-package package name (mapcar #'string (option-arguments :nicknames options)))
    (shadow (mapcar #'string (option-arguments :shadow options)) package)
    (loop for (key from . names) in options
          when (eq key :shadowing-import-from)
            do (let ((from (find-package-or-error from)))
                 (shadowing-import
                  (mapcar (lambda (n)
                            (multiple-value-bind (symbol status) (find-symbol (string n) from)
                              (unless status
                                (error 'package-error :package from))
                              symbol))
                          names)
                  package)))
    (use-package (mapcar #'find-package-or-error (option-arguments :use options)) package)
    (loop for (key from . names) in options
          when (eq key :import-from)
            do (let ((from (find-package-or-error from)))
                 (import (mapcar (lambda (n)
                                   (multiple-value-bind (symbol status) (find-symbol (string n) from)
                                     (unless status
                                       (error 'package-error :package from))
                                     symbol))
                                 names)
                         package)))
    (dolist (n (option-arguments :intern options))
      (intern (string n) package))
    (export (mapcar (lambda (n) (intern (string n) package))
                    (option-arguments :export options))
            package)
    (loop for (nickname actual) in (option-arguments :local-nicknames options)
          do (let ((actual (find-package-or-error actual)))
               (unless (eq (lookup-local-nickname nickname package) actual)
                 (parcl:add-package-local-nickname nickname actual package))))
    package))

(setf (macro-function 'defpackage)
      (lambda (form environment)
        (declare (ignore environment))
        `(eval-when (:compile-toplevel :load-toplevel :execute)
           (kiln.kernel::%defpackage ',(second form) ',(cddr form)))))

(setf (macro-function 'in-package)
      (lambda (form environment)
        (declare (ignore environment))
        `(eval-when (:compile-toplevel :load-toplevel :execute)
           (setq *package* (find-package-or-error ',(second form))))))
