;;;; Load into SBCL (with Quicklisp already set up, e.g. from ~/.sbclrc) to
;;;; make kiln and its dependencies loadable:
;;;;
;;;;   sbcl --load tools/env.lisp --eval '(ql:quickload "kiln")'
;;;;
;;;; Pinned dependencies (deps.lock) are searched in $KILN_DEPS_DIR, default
;;;; deps/ in the repository (see tools/fetch-deps.sh); everything else comes
;;;; from the Quicklisp dist.

(let* ((root (merge-pathnames "../" (make-pathname :name nil :type nil
                                                   :defaults *load-truename*)))
       (env (uiop:getenv "KILN_DEPS_DIR"))
       (deps (if (and env (plusp (length env)))
                 (uiop:ensure-directory-pathname env)
                 (merge-pathnames "deps/" root))))
  ;; Vendored host libraries (vendor/README.md) come before deps/.
  (asdf:initialize-source-registry
   `(:source-registry
     (:directory ,(truename root))
     (:tree ,(merge-pathnames "vendor/Khazern/" (truename root)))
     (:tree ,(merge-pathnames "vendor/Common-macros/" (truename root)))
     (:tree ,(merge-pathnames "vendor/Eclector/" (truename root)))
     (:tree ,(merge-pathnames "vendor/Ecclesia/" (truename root)))
     (:tree ,(merge-pathnames "vendor/Anatomicl/" (truename root)))
     (:tree ,(merge-pathnames "vendor/Maclina/" (truename root)))
     (:tree ,(merge-pathnames "vendor/Incless/" (truename root)))
     (:tree ,(merge-pathnames "vendor/Inravina/" (truename root)))
     (:tree ,(merge-pathnames "vendor/Invistra/" (truename root)))
     (:tree ,deps)
     :inherit-configuration)))
