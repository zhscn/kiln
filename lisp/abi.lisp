(in-package #:kiln.abi)

;;;; Must match rust/kiln-rt. See docs/06-m0-abi.md.

;;; Values: fixnum when the low bit is 0 (value = word >> 1);
;;; general object pointer when the low 3 bits are #b101.
(defconstant +fixnum-shift+ 1)
(defconstant +tag-general+ 5)

;;; Header word of a general object.
(defconstant +kind-symbol+ 1)
(defconstant +kind-function+ 2)

;;; Context field offsets.
(defconstant +ctx-poll-flag+ 0)
(defconstant +ctx-dynenv+ 8)

;;; Dynamic-environment entries (stack-allocated in the establishing frame).
(defconstant +dyn-catch+ 1)
(defconstant +dyn-unwind-protect+ 2)
(defconstant +dynentry-size+ 48)
(defconstant +dyn-kind+ 0)
(defconstant +dyn-prev+ 8)
(defconstant +dyn-fp+ 16)
(defconstant +dyn-tag+ 24)

;;; Offset of the entry address from a tagged function object pointer.
(defconstant +fobj-entry+ (- 8 +tag-general+))

;;; Error codes for kiln_rt_error.
(defconstant +err-not-fixnum+ 1)
(defconstant +err-overflow+ 2)
(defconstant +err-wrong-nargs+ 3)

;;; Argument registers in the Lisp calling convention.
(defconstant +reg-args+ 4)
