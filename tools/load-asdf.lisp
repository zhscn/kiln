;;;; Load the vendored ASDF bundle produced by vendor/ASDF/make-asdf.sh.
(in-package #:cl-user)

(let ((kiln.kernel::*compile-function* nil)
      (kiln.kernel::*eval-function* nil))
  (load (merge-pathnames "../vendor/ASDF/build/asdf.lisp" *load-truename*)))

;; The image already supplies kiln's Closer-MOP compatibility definitions.
(funcall (find-symbol "REGISTER-IMMUTABLE-SYSTEM" "ASDF") "closer-mop" :version "1.0.0")
