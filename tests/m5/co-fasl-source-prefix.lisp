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
                  (error () t)))
         (with-open-file (out path :direction :output :if-exists :supersede
                                  :element-type '(unsigned-byte 8))
           (dolist (byte '(137 75 70 65 83 2 0 1)) (write-byte byte out))
           (kiln.kernel::fasl-write-data '(:initialize (setq kfas :legacy)) out))
         (print (and (load path :verbose nil :print nil) (eq kfas :legacy)))
         (with-open-file (out path :direction :output :if-exists :supersede
                                  :element-type '(unsigned-byte 8))
           (dolist (byte '(137 75 70 65 83 3 0 1 18)) (write-byte byte out))
           (kiln.kernel::fasl-write-data '((setq kfas :opcode)) out))
         (print (and (load path :verbose nil :print nil) (eq kfas :opcode)))
         (with-open-file (out path :direction :output :if-exists :supersede
                                  :element-type '(unsigned-byte 8))
           (dolist (byte '(137 75 70 65 83 4 0 1 255)) (write-byte byte out)))
         (print (handler-case (progn (load path :verbose nil :print nil) nil)
                  (error () t)))
         (with-open-file (out path :direction :output :if-exists :supersede
                                  :element-type '(unsigned-byte 8))
           (dolist (byte '(137 75 70 65 83 4 1 1 12 0)) (write-byte byte out)))
         (print (handler-case (progn (load path :verbose nil :print nil) nil)
                  (end-of-file () t))))
    (when (probe-file path) (delete-file path))))
