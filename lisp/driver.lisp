(in-package #:kiln)

(defun read-forms (path)
  (with-open-file (in path)
    (let ((*package* (find-package '#:kiln-user))
          (*read-eval* nil))
      (loop with eof = (list nil)
            for form = (read in nil eof)
            until (eq form eof)
            collect form))))

(defun compile-file-to-kir (input output)
  "Compiles the M0 source file INPUT to the KIR file OUTPUT."
  (let ((module (kiln.m0:compile-forms (read-forms input)
                                       (pathname-name input))))
    (with-open-file (out output :direction :output :if-exists :supersede)
      (kiln.kir:print-module module out))
    output))
