(defvar *inspect-result* nil)
(let* ((child (vector 17 23))
       (object (cons child nil))
       (*inspect-result* nil)
       (commands (format nil "0 ~S U R Q"
                         '(setf *inspect-result*
                                #+kiln kiln.sys:*inspected*
                                #+sbcl sb-ext:*inspected*)))
       (result :not-returned)
       (text (with-input-from-string (*standard-input* commands)
               (with-output-to-string (*standard-output*)
                 (setf result (multiple-value-list (inspect object)))))))
  (print (list (null result) (plusp (length text)) (eq child *inspect-result*))))
(dolist (commands '("Q" "E" "" "999 Q" "H Q"))
  (let ((result :not-returned))
    (with-input-from-string (*standard-input* commands)
      (with-output-to-string (*standard-output*)
        (setf result (multiple-value-list (inspect '(a b))))))
    (print (null result))))
#+kiln
(progn
  (defclass inspector-slot-test () ((unset) (value :initform 42)))
  (let ((text (with-input-from-string (*standard-input* "0 Q")
                (with-output-to-string (*standard-output*)
                  (inspect (make-instance 'inspector-slot-test))))))
    (print (not (null (search "[unbound]" text))))))
#-kiln (print t)
#+kiln
(let ((kiln.kernel::*inspect-length* 2)
      (*inspect-result* nil))
  (with-input-from-string (*standard-input*
                            "N 3 (setf *inspect-result* kiln.sys:*inspected*) U P Q")
    (with-output-to-string (*standard-output*) (inspect #(10 20 30 40 50))))
  (print (= *inspect-result* 40)))
#-kiln (print t)
#+kiln
(let ((cycle (list nil)))
  (setf (car cycle) cycle)
  (with-input-from-string (*standard-input* "0 U Q")
    (with-output-to-string (*standard-output*) (inspect cycle)))
  (with-input-from-string (*standard-input* "0 Q")
    (with-output-to-string (*standard-output*)
      (inspect (make-array 1 :element-type nil))))
  (print t))
#-kiln (print t)
#+kiln
(let* ((value (list :shared)) (table (make-hash-table)) (*inspect-result* nil))
  (setf (gethash :key table) value)
  (with-input-from-string (*standard-input*
                            "0 1 (setf *inspect-result* kiln.sys:*inspected*) Q")
    (with-output-to-string (*standard-output*) (inspect table)))
  (print (eq value *inspect-result*)))
#-kiln (print t)
#+kiln
(let ((*inspect-result* nil))
  (with-input-from-string (*standard-input*
                            "4 (setf *inspect-result* kiln.sys:*inspected*) Q")
    (with-output-to-string (*standard-output*) (inspect (parse-namestring "source.lisp"))))
  (print (equal *inspect-result* "lisp")))
#-kiln (print t)
#+kiln
(let ((*inspect-result* nil))
  (with-input-from-string (*standard-input*
                            "0 (setf *inspect-result* kiln.sys:*inspected*) Q")
    (with-output-to-string (*standard-output*) (inspect (find-package :cl))))
  (print (equal *inspect-result* "COMMON-LISP")))
#-kiln (print t)
#+kiln
(let ((result :not-returned))
  (with-input-from-string (*standard-input* ") (error \"probe error\") Q")
    (with-output-to-string (*standard-output*)
      (setf result (multiple-value-list (inspect 'if)))))
  (print (null result)))
#-kiln (print t)
(print (not (boundp #+kiln 'kiln.sys:*inspected* #+sbcl 'sb-ext:*inspected*)))
(let* ((object (list :outer))
       (*inspect-result* nil)
       (commands (format nil "(inspect 17) Q ~S Q"
                         '(setf *inspect-result*
                                #+kiln kiln.sys:*inspected*
                                #+sbcl sb-ext:*inspected*))))
  (with-input-from-string (*standard-input* commands)
    (with-output-to-string (*standard-output*) (inspect object)))
  (print (eq object *inspect-result*)))
