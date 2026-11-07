;;;; The compiler module's last file: what the host's front
;;;; end knew of the modules compiled before it in its session. The inline
;;;; functions (front.lisp) of the kernel, CLOS, the front-end, eval and
;;;; compiler modules: HOST-INLINE-FUNCTIONS expands into them, in the host
;;;; (kiln:compile-compiler).

(in-package #:kiln.compiler)

(setf *host-inline-functions* (host-inline-functions))
