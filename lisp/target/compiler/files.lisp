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

(defconstant +file-artifact-limit+ 256)
(defconstant +file-artifact-packet-bytes+ (* 8 1024 1024))

(defstruct (file-literal-reference (:constructor file-literal-reference (index)))
  (index 0 :type fixnum))

(defun copy-file-literal-template (bindings indices program-objects)
  (compilation-reusable-bindings
   bindings indices
   (lambda (object)
     (multiple-value-bind (index present) (compiler-eq-ref program-objects object)
       (when present (file-literal-reference index))))))

(defun bind-file-literal-template (entry program-values)
  (compilation-reusable-bindings
   (svref entry 2) (svref entry 3)
   (lambda (object)
     (when (file-literal-reference-p object)
       (svref (hir-buffer-data program-values) (file-literal-reference-index object))))))

(defun add-native-file-artifact (form session ordinal previous artifacts remaining)
  (let ((slot (and artifacts (< ordinal +file-artifact-limit+) ordinal)))
    (multiple-value-bind (key program-objects program-values)
        (when (and slot (plusp remaining)) (compilation-hir-key form t))
      (let ((old (and key previous (svref previous slot))))
        (labels ((retain (entry)
                   (let ((size (kiln.sys:%primop :length (svref entry 1))))
                     (when (<= size remaining)
                       (setf (svref artifacts slot) entry)
                       (decf remaining size)))))
          (cond
            ((and old (compilation-hir-key-match-p key (svref old 0))
                  (eql (svref key 0) *lowering-version*))
             (kiln.kernel::fasl-add-module (svref old 1) (bind-file-literal-template old program-values))
             (retain old))
            (t
             ;; The ordinal keeps packet names distinct within a batch
             ;; and stable across compilations of the same file.
             (multiple-value-bind (module literals)
                 (compile-module (list form) (kiln.kir::kir-name "file-" ordinal) :session session :image t)
               (multiple-value-bind (program bindings) (kiln.lir:module-program module literals)
                 (let ((packet (kiln.lir::encode-image-program program)))
                   (when (and key (kiln.kir::kmodule-replayable-p module)
                              (eql (svref key 0) *lowering-version*)
                              (<= (kiln.sys:%primop :length packet) remaining))
                     (let ((indices (append (compilation-debug-literals module)
                                            (loop for i from (length literals) below (length bindings) collect i))))
                       (let ((template (copy-file-literal-template bindings indices program-objects)))
                         (when template (retain (vector key packet template indices))))))
                   (kiln.kernel::fasl-add-module packet bindings))))))))
    remaining)))

(defun native-file-unit (input external-format print)
  (let* ((previous (and *file-compilation-artifacts*
                        (equal input (first *file-compilation-artifacts*))
                        (eq *package* (second *file-compilation-artifacts*))
                        (eq *readtable* (third *file-compilation-artifacts*))
                        (fourth *file-compilation-artifacts*)))
         (artifacts (and (plusp kiln.sys:*compilation-cache-limit*)
                         (null *compiler-stage-observer*)
                         (make-array +file-artifact-limit+ :initial-element nil)))
         (ordinal 0)
         (remaining +file-artifact-packet-bytes+)
         (session (make-session))
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
           (setf remaining (add-native-file-artifact form session ordinal previous artifacts remaining))
           (incf ordinal)))))
    (values (list kiln.kernel::*fasl-count* (nreverse kiln.kernel::*fasl-records*))
            (when artifacts (list input *package* *readtable* artifacts)))))

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
    (multiple-value-bind (unit artifacts)
        (handler-bind ((warning (lambda (condition)
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
                nil))))
      (unless unit (return-from cl:compile-file (values nil t t)))
      (with-open-file (stream output :direction :output :if-exists :supersede
                                     :element-type '(unsigned-byte 8))
        (kiln.kernel::write-native-fasl unit stream))
      (setf *file-compilation-artifacts* artifacts)
      (values (truename output) warnings-p failure-p))))
