;;;; Native file compilation and indexed object graph records.

(in-package #:kiln.compiler)

(defun finish-file-initializer (initializer)
  (import-source-definitions)
  (when *load-print* (format t "~&;; ~S loaded~%" initializer))
  (values))

(defun load-native-file (packet literals)
  (let ((init (with-compilation-phase (:backend)
                        (kiln.lir:require-init (kiln.sys:%primop :compile-packet packet literals) :compile-packet))))
    (funcall init)
    (finish-file-initializer init)))

(defun load-file-proclamation (declaration)
  (proclaim declaration)
  (finish-file-initializer declaration))

(defun prepare-file-code (packets)
  (let* ((entries (make-array (* 2 (length packets))))
         (result (with-compilation-phase (:backend)
                   (kiln.sys:%primop :prepare-file-code packets entries))))
    (when result
      (kiln.lir::signal-backend-compilation-error result :prepare-file-code))
    entries))

(defun run-file-code (entries index literals)
  (let* ((offset (* 2 index))
         (binder (svref entries offset)))
    (unless (and (typep literals 'simple-vector)
                 (= (length literals) (svref entries (1+ offset))))
      (error "FASL literal vector does not match its initializer."))
    (let ((init (funcall binder literals)))
      (funcall init)
      (finish-file-initializer init))))

(defun file-proclamation-argument (body)
  ;; A quoted declaration already contains everything the load-time call needs.
  (when (and (= (hir-node-kind body) 7) (eq (hir-node-a body) 'proclaim)
             (= (length (hir-node-b body)) 1))
    (let ((argument (svref (hir-node-b body) 0)))
      (when (= (hir-node-kind argument) 0) argument))))

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
         (kiln.kernel::*fasl-ids* (make-compiler-eq-table))
         (kiln.kernel::*fasl-ready* (make-array 128 :initial-element nil))
         (kiln.kernel::*fasl-creating* (make-hash-table :test 'eq))
         (kiln.kernel::*fasl-count* 0)
         (kiln.kernel::*fasl-records* nil)
         (kiln.kernel::*fasl-pending* nil))
    ;; Initializers precede the literals of the next top-level form, so a
    ;; package created by one form exists when later symbols are interned.
    (dolist (form (front-end (list input) session))
      (let* ((body (hir-fun-body (toplevel-form-ast form)))
             (proclamation (file-proclamation-argument body)))
        (cond
          ((and (= (hir-node-kind body) 0) (symbolp (hir-node-a body)))
           ;; The front end has handled compile-time effects. Keep the
           ;; symbol's load-time interning in order with the initializers.
           (when (hir-node-a body)
             (kiln.kernel::fasl-intern (hir-node-a body))))
          (proclamation
           (kiln.kernel::fasl-add-proclamation (hir-node-a proclamation)))
          (t
           (let ((name (kiln.kir::kir-name "file-" (incf *native-compile-count*))))
             (multiple-value-bind (module literals)
                 (compile-module (list form) name :session session :image t)
               (multiple-value-bind (program bindings) (kiln.lir:module-program module literals)
                 (kiln.kernel::fasl-add-module (kiln.lir::encode-image-program program)
                                              bindings))))))))
    (list kiln.kernel::*fasl-count* (nreverse kiln.kernel::*fasl-records*))))

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
                      (kiln.kernel::fasl-creation-cycle (condition)
                        (error condition))
                      (error (condition)
                        (format *error-output* "~&; Compilation aborted: ~A~%" condition)
                        (setf warnings-p t failure-p t)
                        nil))))))
      (unless unit (return-from cl:compile-file (values nil t t)))
      (with-open-file (stream output :direction :output :if-exists :supersede
                                     :element-type '(unsigned-byte 8))
        (kiln.kernel::write-native-fasl unit stream))
      (values (truename output) warnings-p failure-p))))
