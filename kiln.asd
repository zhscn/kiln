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
               (:file "hir/consumer")
               (:file "lower")
               (:file "values")
               (:file "primitives")
               (:file "structures")
               (:file "macro-client")
               (:file "source-forms")
               (:file "compilation-context")
               (:file "environment-query")
               (:file "toplevel")
               (:file "front")
               (:file "cross")
               (:file "hir/environment")
               (:file "hir/convert")
               (:file "type-inference")
               (:file "hir/analyze")
               (:file "hir/types")
               (:file "hir/escape")
               (:file "hir/eval")
               (:file "hir/lower")
               (:file "mir/data")
               (:file "mir/verify")
               (:file "mir/build")
               (:file "mir/values")
               (:file "mir/types")
               (:file "mir/calls")
               (:file "mir/escape")
               (:file "mir/predicates")
               (:file "mir/scalar")
               (:file "mir/lower")
               (:file "mir/dump")
               (:file "driver")))
