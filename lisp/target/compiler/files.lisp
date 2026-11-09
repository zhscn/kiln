;;;; Native file compilation with Maclina's object graph container.

(in-package #:kiln.compiler)

(defun load-native-file (kir literals)
  (let ((init (kiln.sys:%primop :jit kir literals)))
    (unless init (error "Cannot generate native code for compiled file."))
    (funcall init)
    (when *load-print* (format t "~&;; ~S loaded~%" init)))
  (values))

(defun native-file-unit (input external-format print)
  (let* ((session (make-session))
         (*file-reader-package* *package*)
         (*file-reader-external-format* external-format)
         (*file-compilation-p* t)
         (*target-features* *features*)
         (*file-form-hook* (when print
                            (lambda (form)
                              (let ((*print-circle* t) (*print-length* 3) (*print-level* 3))
                                (format t "~&;   ~S~%" form)))))
         (maclina.compile-file::*coalescence*
           (make-instance 'maclina.compile-file::coalescence))
         (maclina.compile-file::*environment* nil))
    ;; Initializers precede the literals of the next top-level form, so a
    ;; package created by one form exists when later symbols are interned.
    (dolist (form (front-end (list input) session))
      (let ((name (kiln.kir::kir-name "file-" (incf *native-compile-count*))))
        (multiple-value-bind (module literals)
            (compile-module (list form) name :session session :image t)
          (maclina.compile-file::add-initializer-form
           `(load-native-file ,(kiln.kir::module-string module) ',literals)))))
    (maclina.compile-file::finish-fasl-unit)))

(defun cl:compile-file (input-file &key (output-file nil output-file-p)
                                      (verbose *compile-verbose*) (print *compile-print*)
                                      (external-format :default))
  (let* ((input (merge-pathnames input-file))
         (*compile-verbose* verbose)
         (*compile-print* print)
         (*compile-file-pathname* input)
         (*compile-file-truename* (truename input))
         (*package* *package*)
         (*readtable* *readtable*)
         (output (if output-file-p
                     (compile-file-pathname input :output-file output-file)
                     (compile-file-pathname input)))
         (warnings-p nil) (failure-p nil))
    (when verbose (format t "~&; Compiling ~A~%" input))
    (let ((unit (handler-bind ((warning (lambda (condition)
                                         (setf warnings-p t)
                                         (unless (typep condition 'style-warning)
                                           (setf failure-p t)))))
                  (with-compilation-unit ()
                    (handler-case (native-file-unit input external-format print)
                      (error (condition)
                        (format *error-output* "~&; Compilation aborted: ~A~%" condition)
                        (setf warnings-p t failure-p t)
                        nil))))))
      (unless unit (return-from cl:compile-file (values nil t t)))
      (with-open-file (stream output :direction :output :if-exists :supersede
                                     :element-type '(unsigned-byte 8))
        (maclina.compile-file::write-bytecode unit stream))
      (values (truename output) warnings-p failure-p))))
