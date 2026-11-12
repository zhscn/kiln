(defvar kfas :source)
(let ((path "build/test/co-fasl-prefix-source.lisp"))
  (unwind-protect
       (progn
         (with-open-file (out path :direction :output :if-exists :supersede)
           (write-string "KFAS" out))
         (print (load path :verbose nil :print nil))
         (with-open-file (out path :direction :output :if-exists :supersede
                                  :element-type '(unsigned-byte 8))
           (dolist (byte '(137 75 70 65 83 99)) (write-byte byte out)))
         (print (handler-case (progn (load path :verbose nil :print nil) nil)
                  (error () t))))
    (when (probe-file path) (delete-file path))))
