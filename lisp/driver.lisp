(in-package #:kiln)

(defparameter *kernel-files*
  (list (asdf:system-relative-pathname "kiln" "lisp/target/kernel.lisp"))
  "Target kernel sources, compiled ahead of every program until modules
can be linked separately (docs/09, M3.2).")

(defun compile-file-to-kir (input output &key (prelude *kernel-files*))
  "Compiles the source file INPUT, after the files PRELUDE, to the KIR
file OUTPUT."
  (let ((module (kiln.compiler:compile-module
                 (kiln.compiler:front-end (append prelude (list input)))
                 (pathname-name input))))
    (with-open-file (out output :direction :output :if-exists :supersede)
      (kiln.kir:print-module module out))
    output))
