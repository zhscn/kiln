(in-package #:kiln.abi)

;;;; Must match rust/kiln-rt.

;;; Fixnum encoding.
(defconstant +fixnum-shift+ 1)

;;; Immediates: low 3 bits #b011, bits 3-7 the immediate kind, payload from
;;; bit 8.
(defconstant +immediate-mask+ #xff)
(defconstant +character-tag+ #x0b)
(defconstant +character-shift+ 8)
;;; Single-floats are immediates: low byte #x1b, IEEE bits in bits 32-63.
(defconstant +single-float-tag+ #x1b)
(defconstant +char-code-limit+ #x110000)

;;; Transfer area: arguments beyond the register arguments, and (later)
;;; values beyond the first. VALUES_MAX words, at the end of the context.
(defconstant +values-max+ 1021)

;;; Error codes for kiln_rt_error.
(defconstant +err-not-fixnum+ 1)
(defconstant +err-overflow+ 2)
(defconstant +err-wrong-nargs+ 3)
(defconstant +err-not-list+ 4)
(defconstant +err-not-function+ 5)
(defconstant +err-undefined-function+ 6)
(defconstant +err-unbound-variable+ 7)
(defconstant +err-not-symbol+ 8)
(defconstant +err-odd-keywords+ 9)
(defconstant +err-unknown-keyword+ 10)
(defconstant +err-not-character+ 11)
(defconstant +err-not-string+ 12)
(defconstant +err-not-vector+ 13)
(defconstant +err-index+ 14)
(defconstant +err-not-sequence+ 15)
(defconstant +err-not-integer+ 16)
(defconstant +err-division-by-zero+ 17)
(defconstant +err-not-number+ 18)
(defconstant +err-bad-type+ 19)
(defconstant +err-lisp-error+ 20)
(defconstant +err-undefined-setf-function+ 21)
(defconstant +err-stack-exhausted+ 22)        ; KILN.KERNEL::%STACK-EXHAUSTED       ; ERROR before the condition system
(defconstant +err-no-catch-tag+ 23)
(defconstant +err-expired-exit+ 24)

;;; Argument registers in the Lisp calling convention.
(defconstant +reg-args+ 3)
