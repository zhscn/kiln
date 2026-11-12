;;;; Runtime evaluation, compilation and file loading.

(in-package #:kiln.kernel)

(defvar *load-verbose* nil)
(defvar *load-print* nil)
(defvar *load-pathname* nil)
(defvar *load-truename* nil)

(defvar *eval-function* nil
  "Optional native evaluator; before it is installed, EVAL uses HIR.")

(defvar *interpreting* nil)

(defun interpreted-eval (form)
  (if *interpreting*
      (interpreted-eval-1 form)
      (let ((*interpreting* t) (unknown nil))
        (multiple-value-prog1
            (handler-bind ((kiln.compiler::undefined-function-warning
                             (lambda (condition)
                               (dolist (name (kiln.compiler::undefined-function-names condition))
                                 (pushnew name unknown :test #'equal))
                               (muffle-warning condition))))
              (interpreted-eval-1 form))
          (let ((missing (remove-if #'fboundp unknown)))
            (when missing (warn 'kiln.compiler::undefined-function-warning :names missing)))))))

(defun interpreted-eval-1 (form)
  (loop
    (cond ((and (consp form) (eq (car form) 'progn))
           (return (let ((result (list nil)))
                     (dolist (subform (cdr form))
                       (setf result (multiple-value-list (interpreted-eval subform))))
                     (values-list result))))
          ((and (consp form) (eq (car form) 'eval-when))
           (return (when (intersection (second form) '(:execute eval))
                     (interpreted-eval (cons 'progn (cddr form))))))
          (t
           (multiple-value-bind (expansion expanded) (macroexpand-1 form)
             (if expanded (setf form expansion)
                 (return (kiln.compiler::interpret-form form))))))))

(defun eval (form)
  (if *eval-function* (funcall *eval-function* form) (interpreted-eval form)))

(defvar *compile-function* nil
  "Optional native lambda compiler; before it is installed, COMPILE builds HIR closures.")

(defun compile-lambda (definition)
  (if *compile-function*
      (funcall *compile-function* definition)
      (interpreted-eval (list 'function definition))))

(defun compile (name &optional definition)
  (let ((function (cond ((functionp definition) definition)
                        (definition (compile-lambda definition))
                        (t (let ((f (fdefinition name)))
                             (if (functionp f) f (compile-lambda f)))))))
    (when name
      (if (and (symbolp name) (macro-function name) (null definition))
          (setf (macro-function name) function)
          (setf (fdefinition name) function)))
    (values (or name function) nil nil)))

(defun load (filespec &key (verbose *load-verbose*) (print *load-print*)
                           (if-does-not-exist t) (external-format :default))
  (labels ((load-stream (stream pathname truename binaryp)
             (let ((*package* *package*)
                   (*readtable* *readtable*)
                   (*load-pathname* pathname)
                   (*load-truename* truename)
                   (*load-print* print))
               (when (and verbose (not pathname))
                 (format t "~&; loading from stream~%"))
               (if binaryp
                   (load-native-fasl stream :verbose verbose)
                   (loop with eof = (list nil)
                         for form = (read stream nil eof)
                         until (eq form eof)
                         do (let ((values (multiple-value-list (eval form))))
                              (when print
                                (format t "~&~{~S~^ ~}~%" values))))))
             t)
           (fasl-stream-p (stream)
             (let ((magic 0))
               (dotimes (i 4)
                 (let ((byte (read-byte stream nil nil)))
                   (unless byte (return-from fasl-stream-p nil))
                   (setf magic (logior (ash magic 8) byte))))
               (= magic #x4b464153))))
    (if (streamp filespec)
        (load-stream filespec nil nil
                     (subtypep (stream-element-type filespec) '(unsigned-byte 8)))
        (let* ((merged (merge-pathnames filespec))
               (truename nil))
          (with-open-file (stream merged :element-type '(unsigned-byte 8)
                                        :if-does-not-exist (if if-does-not-exist :error nil))
            (unless stream (return-from load nil))
            (setf truename (truename merged))
            (when verbose (format t "~&; loading ~A~%" merged))
            (when (fasl-stream-p stream)
              (file-position stream 0)
              (return-from load (load-stream stream merged truename t))))
          (with-open-file (stream merged :external-format external-format)
            (load-stream stream merged truename nil))))))
