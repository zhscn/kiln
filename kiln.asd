;;;; kiln: host-side (SBCL) compiler.

(defsystem "kiln"
  :description "kiln Common Lisp implementation: host-side compiler"
  :license "BSD-2-Clause"
  :depends-on ("eclector-concrete-syntax-tree"
               "khazern-extrinsic"
               "common-macro-definitions"
               "concrete-syntax-tree"
               "clostrum-basic"
               "clostrum-trucler"
               "trucler-reference"
               "ecclesia"
               "invistra"
               "anatomicl")
  :pathname "lisp/"
  :serial t
  :components ((:file "packages")
               (:file "step-forms")
               (:file "abi")
               (:file "kir")
               (:file "lir-schema")
               (:file "backend-target")
               (:file "backend-packet")
               (:file "lir")
               (:file "lir-function")
               (:file "lir-values")
               (:file "lir-closures")
               (:file "lir-stack")
               (:file "lir-regions")
               (:file "hir/data")
               (:file "lower")
               (:file "values")
               (:file "primitives")
               (:file "structures")
               (:file "macro-client")
               (:file "source-forms")
               (:file "front")
               (:file "cross")
               (:file "hir/environment")
               (:file "hir/convert")
               (:file "hir/analyze")
               (:file "hir/types")
               (:file "hir/escape")
               (:file "hir/eval")
               (:file "hir/lower")
               (:file "driver")))
