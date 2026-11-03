(in-package #:kiln)

(defun compile-file-to-kir (input output)
  "Compiles the source file INPUT to the KIR file OUTPUT."
  (let ((module (kiln.compiler:compile-module (kiln.compiler:front-end input)
                                              (pathname-name input))))
    (with-open-file (out output :direction :output :if-exists :supersede)
      (kiln.kir:print-module module out))
    output))
