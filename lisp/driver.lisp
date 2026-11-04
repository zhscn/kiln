(in-package #:kiln)

(defparameter *kernel-files*
  (mapcar (lambda (name)
            (asdf:system-relative-pathname "kiln" (format nil "lisp/target/~A.lisp" name)))
          '("kernel" "types" "sequences"))
  "Target kernel sources, compiled into the kernel module.")

(defun write-module (module output)
  (with-open-file (out output :direction :output :if-exists :supersede)
    (kiln.kir:print-module module out))
  output)

(defun compile-kernel (output &key (session (kiln.compiler:make-session)))
  "Compiles the kernel to the KIR module OUTPUT. Programs compiled later
in SESSION see its macros and definitions."
  (write-module (kiln.compiler:compile-module
                 (kiln.compiler:front-end *kernel-files* session) "kernel")
                output))

(defun compile-file-to-kir (input output &key (session (kiln.compiler:make-session)))
  "Compiles the source file INPUT to the KIR module OUTPUT. Run it with the
kernel module first: kiln-cg jit kernel.kir OUTPUT."
  (write-module (kiln.compiler:compile-module
                 (kiln.compiler:front-end (list input) session)
                 (pathname-name input))
                output))
