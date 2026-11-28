(in-package #:kiln.lir)

(defun target-fingerprint () kiln.kir::+backend-target-fingerprint+)

(defun module-program (module &optional literals)
  "Normalize a private compiler builder into a program and complete literal bindings."
  (kiln.compiler::with-compilation-phase (:lir-normalize)
    (kiln.kir::normalize-lir-module module literals)))

(defun require-program (program)
  (unless (and (consp program) (eq (car program) :lir-module))
    (error "Production backend requests require an independent LIR module."))
  program)

(defun encode-program (program)
  "Encode only the production LIR payload; compatibility formats are separate."
  (kiln.compiler::with-compilation-phase (:lir-encode)
    (kiln.kir::encode-backend-packet (require-program program) kiln.kir::+packet-lir-payload+)))

#+kiln
(defun encode-image-program (program)
  (kiln.compiler::with-compilation-phase (:lir-encode)
    (let ((packet (kiln.sys:%primop :encode-byte-packet
                                  (require-program program) kiln.kir::+packet-lir-payload+)))
      (unless packet (error "Cannot encode backend program."))
      packet)))

(defun module-packet (module &optional literals)
  (multiple-value-bind (program bindings) (module-program module literals)
    (values (encode-program program) bindings)))

(defun write-module (module stream)
  (multiple-value-bind (program literals) (module-program module)
    (unless (zerop (length literals))
      (error "File module requires external literal bindings."))
    (require-program program)
    #+kiln
    (when (kiln.sys::%write-backend-packet program stream)
      (return-from write-module module))
    (kiln.kir::portable-backend-packet program kiln.kir::+packet-lir-payload+ stream))
  module)

(defparameter *runtime-signatures*
  (let ((table (make-hash-table :test 'eq)))
    (dolist (description kiln.kir::+backend-lir-runtime-operations+ table)
      (setf (gethash (first description) table) description))))

(defun runtime-signature (name)
  "Return object-argument count and safepoint effect from the Rust descriptor."
  (let ((description (gethash name *runtime-signatures*)))
    (unless description (error "Unknown backend runtime operation ~S." name))
    (values (second description) (third description))))

(define-condition backend-error (error)
  ((operation :initarg :operation :reader backend-error-operation)
   (stage :initarg :stage :reader backend-error-stage)
   (message :initarg :message :reader backend-error-message)
   (truncated-p :initarg :truncated-p :initform nil :reader backend-error-truncated-p))
  (:report (lambda (condition stream)
             (format stream "Backend ~S failed during ~S: ~A~:[~; [truncated]~]"
                     (backend-error-operation condition) (backend-error-stage condition)
                     (backend-error-message condition) (backend-error-truncated-p condition)))))

(defun require-init (result operation)
  "Return an installed init function or signal a structured backend condition."
  (if (functionp result)
      result
      (signal-backend-compilation-error result operation)))

(defun signal-backend-compilation-error (result operation)
  (labels ((protocol-error ()
             (error 'backend-error :operation operation :stage :protocol
                    :message "Malformed backend compilation result.")))
    (unless (and (typep result 'simple-vector) (<= 3 (length result))
                 (eql (svref result 0) kiln.kir::+packet-diagnostic-version+)
                 (member (svref result 2) '(0 1)))
      (protocol-error))
    (let* ((code (svref result 1))
           (stage (cond ((eql code kiln.kir::+packet-diagnostic-stage-request+) :request)
                        ((eql code kiln.kir::+packet-diagnostic-stage-program+) :program)
                        ((eql code kiln.kir::+packet-diagnostic-stage-install+) :install)
                        (t (protocol-error))))
           (count (- (length result) 3))
           (message (if (<= count kiln.kir::+packet-diagnostic-max-chars+)
                        (make-string count) (protocol-error))))
      (dotimes (index count)
        (let ((code (svref result (+ index 3))))
          (unless (and (integerp code) (<= 0 code #x10ffff) (not (<= #xd800 code #xdfff)))
            (protocol-error))
          (setf (char message index) (code-char code))))
      (error 'backend-error :operation operation :stage stage :message message
             :truncated-p (= (svref result 2) 1)))))
