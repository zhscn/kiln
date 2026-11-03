(in-package #:kiln.abi)

;;;; Must match rust/kiln-rt. See docs/06-m0-abi.md.

;;; Values: fixnum when the low bit is 0 (value = word >> 1); cons pointer
;;; when the low 3 bits are #b001; other object pointer when #b101.
(defconstant +fixnum-shift+ 1)
(defconstant +tag-mask+ 7)
(defconstant +tag-cons+ 1)
(defconstant +tag-general+ 5)

;;; Every object starts with a header word: kind in bits 0-7, payload length
;;; in words above that for variable-length kinds.
(defconstant +kind-mask+ #xff)
(defconstant +kind-symbol+ 1)
(defconstant +kind-function+ 2)
(defconstant +kind-cons+ 3)
(defconstant +kind-simple-vector+ 4)

;;; Symbol layout: [header, name pointer, name length, function, value,
;;; TLS index].
;;; Offsets from a tagged pointer.
(defconstant +symbol-function+ (- 24 +tag-general+))
(defconstant +symbol-value+ (- 32 +tag-general+))
(defconstant +symbol-tls-index+ (- 40 +tag-general+))
;;; Unbound value marker (an immediate the GC ignores).
(defconstant +unbound+ #x13)

;;; Function object layout: [header (env length << 8), entry, env...].
(defconstant +length-shift+ 8)
(defconstant +fobj-env+ (- 16 +tag-general+))

;;; Cons layout: [header, car, cdr].
(defconstant +cons-bytes+ 24)
(defconstant +cons-car+ (- 8 +tag-cons+))
(defconstant +cons-cdr+ (- 16 +tag-cons+))

;;; Context field offsets.
(defconstant +ctx-poll-flag+ 0)
(defconstant +ctx-dynenv+ 8)
;;; Transfer area: arguments beyond the register arguments, and (later)
;;; values beyond the first. VALUES_MAX words.
(defconstant +ctx-values+ 56)
;;; Pointer to the context's TLS table of special variable values.
(defconstant +ctx-tls+ 48)
;;; Empty TLS slot: the symbol is not bound in this context.
(defconstant +no-tls-value+ #x23)
(defconstant +values-max+ 64)
;;; Number of words of the transfer area that are GC roots (normally 0).
(defconstant +ctx-values-live+ 568)

;;; Dynamic-environment entries (stack-allocated in the establishing frame).
(defconstant +dyn-catch+ 1)
(defconstant +dyn-unwind-protect+ 2)
(defconstant +dyn-exit-point+ 5)
(defconstant +dyn-bind+ 6)
(defconstant +dynentry-size+ 48)
(defconstant +dyn-kind+ 0)
(defconstant +dyn-prev+ 8)
(defconstant +dyn-fp+ 16)
(defconstant +dyn-tag+ 24)
(defconstant +dyn-pend-target+ 32)
(defconstant +dyn-pend-value+ 40)

;;; Offset of the entry address from a tagged function object pointer.
(defconstant +fobj-entry+ (- 8 +tag-general+))

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

;;; Argument registers in the Lisp calling convention.
(defconstant +reg-args+ 3)
