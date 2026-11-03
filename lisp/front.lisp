(in-package #:kiln.compiler)

;;;; Front end (M2): Eclector reads CSTs; top-level forms are processed
;;;; here as in COMPILE-FILE (CLHS 3.2.3.1); Common-boot turns each form to
;;;; be compiled into an Iconoclast AST, which SIMPLIFY-AST reduces to the
;;;; subset that lower.lisp translates to KIR. See docs/08-m2-front-end.md.
;;;;
;;;; Compile-time evaluation (EVAL-WHEN :COMPILE-TOPLEVEL, macro
;;;; definitions, DEFVAR proclamations) runs in the host through
;;;; Common-boot's HIR evaluator, in a Clostrum environment that holds the
;;;; compile-time definitions. Host CL functions are imported into it, so
;;;; macro expanders can call them.

(defclass client (trucler-reference:client cbe:client)
  ())

(defmethod cb:convert-with-parser-p ((client client) operator)
  (special-operator-p operator))

(defmethod cb:convert-with-ordinary-macro-p ((client client) operator)
  (cmd:macro-function-exists-p operator))

(defvar *client*)
(defvar *defined-functions*)            ; names defined by DEFUN in this file
(defvar *referenced-functions*)         ; undefined names seen by Common-boot

(defmethod cmd:defun-compile-time-action ((client client) name lambda-list environment)
  (declare (ignore lambda-list environment))
  (setf (gethash name *defined-functions*) t)
  nil)

(define-condition undefined-function-warning (style-warning)
  ((names :initarg :names :reader undefined-function-names))
  (:report (lambda (c s)
             (format s "undefined function~P: ~{~S~^, ~}"
                     (length (undefined-function-names c))
                     (undefined-function-names c)))))
(defvar *environment*)                  ; Trucler environment

(defun global-environment ()
  (trucler:global-environment *client* *environment*))

(defun proclaim-in (client genv declaration)
  (when (and (consp declaration) (eq (first declaration) 'special))
    (dolist (name (rest declaration))
      (clo:make-variable client genv name)))
  nil)

(defun import-host-functions (client genv)
  (do-external-symbols (s '#:common-lisp)
    (when (and (fboundp s) (not (macro-function s)) (not (special-operator-p s)))
      (setf (clo:fdefinition client genv s) (fdefinition s)))
    (let ((setf-name `(setf ,s)))
      (when (fboundp setf-name)
        (setf (clo:fdefinition client genv setf-name) (fdefinition setf-name)))))
  ;; Functions that consult the global environment must use the
  ;; compile-time environment, not the host's.
  (flet ((def (name function)
           (setf (clo:fdefinition client genv name) function))
         (resolve (f)
           (if (functionp f) f (clo:fdefinition client genv f))))
    (def 'macro-function
      (lambda (name &optional env)
        (declare (ignore env))
        (clo:macro-function client genv name)))
    (def '(setf macro-function)
      (lambda (function name &optional env)
        (declare (ignore env))
        (setf (clo:macro-function client genv name) function)))
    (def 'fdefinition (lambda (name) (clo:fdefinition client genv name)))
    (def 'symbol-function (lambda (name) (clo:fdefinition client genv name)))
    (def '(setf fdefinition)
      (lambda (function name) (setf (clo:fdefinition client genv name) function)))
    (def 'fboundp (lambda (name) (clo:fboundp client genv name)))
    (def 'symbol-value (lambda (name) (clo:symbol-value client genv name)))
    (def '(setf symbol-value)
      (lambda (value name) (setf (clo:symbol-value client genv name) value)))
    (def 'boundp (lambda (name) (clo:boundp client genv name)))
    (def 'proclaim (lambda (declaration) (proclaim-in client genv declaration)))
    (def 'funcall (lambda (f &rest args) (apply (resolve f) args)))
    (def 'apply (lambda (f &rest args) (apply #'apply (resolve f) args)))))

(defun make-compile-environment (client)
  (let ((env (cb:create-environment)))
    (import-host-functions client (trucler:global-environment client env))
    env))

;;; Reading

(defun read-csts (path)
  (with-open-file (in path)
    (let ((*package* (find-package '#:kiln-user))
          (*read-eval* nil))
      (loop with eof = (list nil)
            for cst = (eclector.concrete-syntax-tree:read in nil eof)
            until (eq cst eof)
            collect cst))))

;;; Top-level form processing (CLHS 3.2.3.1)

(defvar *toplevel-asts*)                ; simplified ASTs, most recent first

(defun cst-list (cst)
  "The elements of the proper-list CST."
  (loop for c = cst then (cst:rest c)
        while (cst:consp c)
        collect (cst:first c)))

(defun compile-time-eval (cst)
  (cb:eval-cst *client* cst *environment*))

(defun simplify (ast)
  (cbah::simplify-ast ast))

(defun compile-toplevel-form (cst compile-time-too)
  (when compile-time-too
    (compile-time-eval cst))
  (push (simplify (cb:cst-to-ast *client* cst *environment*)) *toplevel-asts*))

(defun macroexpand-toplevel (form)
  "Returns the expansion of FORM and true if FORM is a macro form."
  (let ((op (first form)))
    (cond ((special-operator-p op) (values nil nil))
          (t
           (let ((description (trucler:describe-function *client* *environment* op)))
             (cond ((and (typep description 'trucler:macro-description)
                         (not (eq op 'defmacro)))
                    (values (funcall (trucler:expander description) form *environment*) t))
                   ((cmd:macro-function-exists-p op)
                    (values (cmd:macroexpand-1 form *environment*) t))
                   (t (values nil nil))))))))

(defun process-eval-when (cst compile-time-too)
  (let* ((parts (cst-list (cst:rest cst)))
         (situations (cst:raw (first parts)))
         (body (rest parts))
         (ct (intersection situations '(:compile-toplevel compile)))
         (lt (intersection situations '(:load-toplevel load)))
         (ex (intersection situations '(:execute eval))))
    (cond ((and lt (or ct (and ex compile-time-too)))
           (dolist (c body) (process-toplevel c t)))
          (lt
           (dolist (c body) (process-toplevel c nil)))
          ((or ct (and ex compile-time-too))
           (dolist (c body) (compile-time-eval c))))))

(defun process-toplevel (cst compile-time-too)
  (let ((form (cst:raw cst)))
    (if (and (consp form) (symbolp (first form)))
        (case (first form)
          (progn
            (dolist (c (cst-list (cst:rest cst)))
              (process-toplevel c compile-time-too)))
          (eval-when
           (process-eval-when cst compile-time-too))
          ;; Their bodies should be processed as top-level forms too;
          ;; not done yet (docs/08 §6).
          ((locally macrolet symbol-macrolet)
           (compile-toplevel-form cst compile-time-too))
          (t
           (multiple-value-bind (expansion macrop) (macroexpand-toplevel form)
             (if macrop
                 (process-toplevel (cst:reconstruct *client* expansion cst) compile-time-too)
                 (compile-toplevel-form cst compile-time-too)))))
        (compile-toplevel-form cst compile-time-too))))

(defun front-end (path)
  "Reads and processes the top-level forms of the file PATH. Returns the
simplified ASTs of the forms to compile, in order."
  (let* ((*client* (make-instance 'client))
         (cmd:*client* *client*)
         (*environment* (make-compile-environment *client*))
         (*toplevel-asts* '())
         (*defined-functions* (make-hash-table :test 'equal))
         (*referenced-functions* (make-hash-table :test 'equal)))
    ;; Calls to functions defined later in the file are fine: report
    ;; undefined functions at the end (CLHS 3.2.2.3).
    (handler-bind ((cb:no-function-description
                     (lambda (w)
                       (setf (gethash (cb::name w) *referenced-functions*) t)
                       (muffle-warning w))))
      (dolist (cst (read-csts path))
        (process-toplevel cst nil)))
    (let ((undefined (loop for name being the hash-keys of *referenced-functions*
                           unless (or (gethash name *defined-functions*)
                                      (gethash name *primitives*))
                             collect name)))
      (when undefined
        (warn 'undefined-function-warning :names undefined)))
    (reverse *toplevel-asts*)))
