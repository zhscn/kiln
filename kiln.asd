;;;; kiln: host-side (SBCL) compiler.

(defsystem "kiln"
  :description "kiln Common Lisp implementation: host-side compiler"
  :license "BSD-2-Clause"
  :pathname "lisp/"
  :serial t
  :components ((:file "packages")
               (:file "abi")
               (:file "kir")
               (:file "m0-compiler")
               (:file "driver")))
