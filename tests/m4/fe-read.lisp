;;; Eclector's CST reader in the image: this file, read with READ and into
;;; concrete syntax trees, gives the same forms.

(defparameter *this-file* "tests/m4/fe-read.lisp")

(defun read-all (reader)
  (with-open-file (s *this-file*)
    (loop with eof = (list nil)
          for object = (funcall reader s eof)
          until (eq object eof)
          collect object)))

;;; Gensyms aside, the forms are EQUAL.
(defun similar-forms (a b)
  (cond ((and (symbolp a) (symbolp b) (null (symbol-package a)) (null (symbol-package b)))
         (string= (symbol-name a) (symbol-name b)))
        ((and (consp a) (consp b))
         (and (similar-forms (car a) (car b)) (similar-forms (cdr a) (cdr b))))
        (t (equal a b))))

(let ((forms (read-all (lambda (s eof) (read s nil eof))))
      (csts (read-all (lambda (s eof) (eclector.concrete-syntax-tree:read s nil eof)))))
  (format t "~d forms, ~d CSTs~%" (length forms) (length csts))
  (format t "~s~%" (every #'similar-forms forms (mapcar #'cst:raw csts)))
  (let ((first (first csts)))
    (format t "~s ~s~%" (cst:raw (cst:first first)) (cst:source first))
    (format t "~s~%" (cst:source (cst:second first))))
  (format t "~s~%" (mapcar (lambda (cst) (cst:consp cst)) csts)))

;;; CST utilities.
(let ((cst (cst:cst-from-expression '(let ((x 1) (y 2)) (+ x y)))))
  (format t "~s ~s~%" (cst:raw (cst:first cst)) (cst:raw (cst:rest (cst:rest cst))))
  (format t "~s~%" (cst:raw (cst:reconstruct nil '(a (b c)) cst))))
