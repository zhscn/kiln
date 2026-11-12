;;;; Compiler initialization: what the host's front
;;;; end knew of the modules compiled before it in its session. The inline
;;;; functions (front.lisp) of the kernel, CLOS, the front-end, eval and
;;;; compiler modules: HOST-INLINE-FUNCTIONS expands into them, in the host
;;;; (kiln:compile-compiler).

(in-package #:kiln.compiler)

(setf *host-inline-functions* (host-inline-functions))

(when *image-inline-functions*
  (dolist (entry *host-inline-functions*)
    (unless (nth-value 1 (gethash (car entry) *image-inline-functions*))
      (setf (gethash (car entry) *image-inline-functions*) (cdr entry)))))
