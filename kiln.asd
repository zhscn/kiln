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
               "anatomicl")
  :pathname "lisp/"
  :serial t
  :components ((:file "packages")
               (:file "step-forms")
               (:file "abi")
               (:file "kir")
               (:file "ir/data")
               (:file "lower")
               (:file "values")
               (:file "primitives")
               (:file "structures")
               (:file "macro-client")
               (:file "front")
               (:file "cross")
               (:file "ir/environment")
               (:file "ir/convert")
               (:file "ir/analyze")
               (:file "ir/eval")
               (:file "ir/lower")
               (:file "driver")))
