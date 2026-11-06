(cl:in-package #:asdf-user)

(defsystem "iconoclast-ast-walker"
  :depends-on ("iconoclast" "closer-mop")
  :serial t
  :components
  ((:file "packages")
   (:file "ast-walker")
   (:file "lambda-list-walker")))

