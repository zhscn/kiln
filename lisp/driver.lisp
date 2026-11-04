(in-package #:kiln)

(defparameter *kernel-files*
  (mapcar (lambda (name)
            (asdf:system-relative-pathname "kiln" (format nil "lisp/target/~A.lisp" name)))
          '("kernel" "early" "types" "sequences"))
  "Target kernel sources, compiled into the kernel module.")

(defun clostrophilia-file (system-directory name)
  (asdf:system-relative-pathname
   "kiln" (format nil "vendor/Clostrophilia/Code/~A/~A.lisp" system-directory name)))

(defun kiln-clos-file (name)
  (asdf:system-relative-pathname "kiln" (format nil "lisp/target/clos/~A.lisp" name)))

(defparameter *clos-files*
  (append
   (list (clostrophilia-file "Package" "packages")
         (kiln-clos-file "early"))
   (mapcar (lambda (name) (clostrophilia-file "Class-hierarchy" name))
           '("t" "function" "standard-object" "metaobject" "method" "standard-method"
             "standard-accessor-method" "standard-reader-method" "standard-writer-method"
             "slot-definition" "standard-slot-definition" "direct-slot-definition"
             "effective-slot-definition" "standard-direct-slot-definition"
             "standard-effective-slot-definition" "method-combination"
             "standard-method-combination" "specializer" "eql-specializer" "class"
             "forward-referenced-class" "real-class" "regular-class" "standard-class"
             "funcallable-standard-class" "built-in-class" "funcallable-standard-object"
             "simple-function" "generic-function" "standard-generic-function"))
   (list (kiln-clos-file "built-in-classes")
         (kiln-clos-file "braid")))
  "Sources of the CLOS module, in load order (docs/10 §7).")

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

(defun compile-clos (output &key (session (kiln.compiler:make-session)))
  "Compiles CLOS (Clostrophilia and kiln's bootstrap) to the KIR module
OUTPUT, to be loaded after the kernel. SESSION must have compiled the
kernel."
  (write-module (kiln.compiler:compile-module
                 (kiln.compiler:front-end *clos-files* session) "clos")
                output))
