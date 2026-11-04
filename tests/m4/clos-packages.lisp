;;; Packages (Parcl): the run-time packages mirror the packages the
;;; modules were read into.

(print (package-name (symbol-package 'car)))
(print (package-name (symbol-package 'foo)))
(print (package-name (symbol-package :key)))
(print (eq (find-symbol "CAR" "CL") 'car))
(print (multiple-value-list (find-symbol "CAR")))
(print (multiple-value-list (find-symbol "FOO")))
(print (multiple-value-list (find-symbol "NO-SUCH-SYMBOL")))
(print (eq (find-package "CL-USER") *package*))
(print (package-nicknames "COMMON-LISP"))
(print (mapcar #'package-name (package-use-list "CL-USER")))
(print (multiple-value-list (find-symbol "NIL" "CL")))
(print (packagep (find-package "KEYWORD")))
(print (packagep 'car))

;; Every standard symbol exists.
(let ((n 0))
  (do-external-symbols (s "CL") (setq n (+ n 1)))
  (print n))
(print (multiple-value-list (find-symbol "WITH-COMPILATION-UNIT" "CL")))

;; Keywords
(let ((k (intern "NEW-KEY" "KEYWORD")))
  (print k)
  (print (keywordp k))
  (print (eq (symbol-value k) k))
  (print (multiple-value-list (find-symbol "NEW-KEY" "KEYWORD"))))
(print (eq (intern "KEY" "KEYWORD") :key))

;; New packages
(make-package "MY-PKG" :use '("CL"))
(let ((s (intern "HELLO" "MY-PKG")))
  (print (package-name (symbol-package s)))
  (print (multiple-value-list (intern "HELLO" "MY-PKG")))
  (export s "MY-PKG")
  (print (multiple-value-list (find-symbol "HELLO" "MY-PKG")))
  (use-package "MY-PKG")
  (print (multiple-value-list (find-symbol "HELLO")))
  (print (eq (intern "HELLO") s)))
(print (multiple-value-list (find-symbol "CAR" "MY-PKG")))
(print (mapcar #'package-name (package-used-by-list "MY-PKG")))

;; A conflict: CL-USER inherits HELLO from MY-PKG.
(make-package "OTHER")
(export (intern "HELLO" "OTHER") "OTHER")
(print (handler-case (progn (use-package "OTHER") 'used)
         (error () 'conflict)))

;; Shadowing
(make-package "SHADOWER" :use '("CL"))
(shadow "CAR" "SHADOWER")
(print (eq (find-symbol "CAR" "SHADOWER") 'car))
(print (package-name (symbol-package (find-symbol "CAR" "SHADOWER"))))
(print (length (package-shadowing-symbols "SHADOWER")))

;; Unintern
(let ((s (intern "TEMP" "MY-PKG")))
  (print (unintern s "MY-PKG"))
  (print (symbol-package s))
  (print (multiple-value-list (find-symbol "TEMP" "MY-PKG"))))

;; Import
(let ((s (make-symbol "LONELY")))
  (import s "MY-PKG")
  (print (package-name (symbol-package s)))
  (print (eq (find-symbol "LONELY" "MY-PKG") s)))

;; Iteration
(let ((names '()))
  (do-symbols (s "MY-PKG")
    (when (eq (symbol-package s) (find-package "MY-PKG"))
      (push (symbol-name s) names)))
  (print (sort names #'string<)))
(with-package-iterator (next "MY-PKG" :external)
  (loop (multiple-value-bind (more symbol status) (next)
          (unless more (return))
          (print (list symbol status)))))

;; Renaming and deleting
(rename-package "OTHER" "OTHER-2" '("O2"))
(print (package-name (find-package "O2")))
(print (find-package "OTHER"))
(print (delete-package "O2"))
(print (find-package "OTHER-2"))

;; Gensyms have no package.
(print (symbol-package (gensym)))
(print (length (find-all-symbols "CAR")))
