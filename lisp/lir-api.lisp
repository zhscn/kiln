(in-package #:kiln.lir)

(defun target-fingerprint () kiln.kir::+backend-target-fingerprint+)

(defun module-program (module &optional literals)
  "Normalize a private compiler builder into a program and complete literal bindings."
  (kiln.kir::normalize-lir-module module literals))

(defun require-program (program)
  (unless (and (consp program) (eq (car program) :lir-module))
    (error "Production backend requests require an independent LIR module."))
  program)

(defun encode-program (program)
  "Encode only the production LIR payload; compatibility formats are separate."
  (kiln.kir::encode-backend-packet (require-program program) kiln.kir::+packet-lir-payload+))

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
