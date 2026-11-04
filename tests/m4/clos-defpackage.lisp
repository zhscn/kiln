;;; DEFPACKAGE and IN-PACKAGE at run time; package-local nicknames.

(defun external-names (package)
  (let ((names '()))
    (do-external-symbols (s package) (push (symbol-name s) names))
    (sort names #'string<)))

(defun define-rt-a ()
  (defpackage "RT-A"
    (:use "COMMON-LISP")
    (:nicknames "RTA")
    (:export "FOO" "BAR")))
(define-rt-a)
(format t "~s ~s ~s~%" (package-name (find-package "RTA")) (package-nicknames "RT-A")
        (external-names "RT-A"))
(format t "~s~%" (package-name (symbol-package (find-symbol "FOO" "RT-A"))))
(format t "~s~%" (eq (find-symbol "CAR" "RT-A") 'car))

;;; Defining it again updates it.
(defun define-rt-a-again ()
  (defpackage "RT-A"
    (:use "COMMON-LISP")
    (:nicknames "RTA" "RT-AA")
    (:export "FOO" "BAR" "BAZ")))
(define-rt-a-again)
(format t "~s ~s~%" (package-nicknames "RT-A") (external-names "RT-A"))

(defun define-rt-b ()
  (defpackage "RT-B"
    (:use "COMMON-LISP" "RT-A")
    (:shadow "CAR")
    (:shadowing-import-from "RT-A" "BAR")
    (:import-from "COMMON-LISP-USER" "DEFINE-RT-B")
    (:intern "INNER")
    (:export "QUUX")
    (:local-nicknames ("A" "RT-A") ("L" "COMMON-LISP"))))
(define-rt-b)
(let ((b (find-package "RT-B")))
  (format t "~s~%" (mapcar #'package-name (package-use-list b)))
  (format t "~s ~s~%" (eq (find-symbol "CAR" b) 'car)
          (mapcar #'symbol-name (package-shadowing-symbols b)))
  (format t "~s~%" (multiple-value-list (find-symbol "FOO" b)))
  (format t "~s~%" (multiple-value-list (find-symbol "INNER" b)))
  (format t "~s~%" (eq (find-symbol "DEFINE-RT-B" b) 'define-rt-b))
  (format t "~s~%" (sort (mapcar #'car (parcl::package-local-nicknames b)) #'string<))
  ;; Local nicknames apply when RT-B is the current package.
  (format t "~s~%" (find-package "A"))
  (let ((*package* b))
    (format t "~s ~s~%" (package-name (find-package "A")) (package-name (find-package "L")))
    (let ((symbol (read-from-string "a:foo")))
      (format t "~s ~s~%" (symbol-name symbol) (package-name (symbol-package symbol))))))

;;; IN-PACKAGE in a function changes *PACKAGE*.
(defun go-to-b ()
  (in-package "RT-B")
  (package-name *package*))
(let ((*package* *package*))
  (format t "~s~%" (go-to-b)))
(format t "~s~%" (package-name *package*))

;;; The macros exist at run time.
(format t "~s~%" (macroexpand-1 '(in-package "RT-A")))
(format t "~s~%" (macroexpand-1 '(defpackage "RT-C" (:use "CL"))))
(handler-case (progn (funcall (lambda () (in-package "NO-SUCH-PACKAGE"))) (format t "no error~%"))
  (package-error (c) (format t "~a~%" (type-of c))))
