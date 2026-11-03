;;;; kiln: host-side (SBCL) compiler.

(defsystem "kiln"
  :description "kiln Common Lisp implementation: host-side compiler"
  :license "BSD-2-Clause"
  :depends-on ("eclector-concrete-syntax-tree"
               "common-boot"
               "common-boot-ast-to-hir"
               "common-boot-hir-evaluator")
  :pathname "lisp/"
  :serial t
  :components ((:file "packages")
               (:file "abi")
               (:file "kir")
               (:file "lower")
               (:file "values")
               (:file "primitives")
               (:file "front")
               (:file "driver")))
