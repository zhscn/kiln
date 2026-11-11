;;; A program compiled by SBCL and by kiln (tests/m5/co-compile.lisp).

(defpackage #:co-compile-input
  (:use #:common-lisp)
  (:export #:run))

(in-package #:co-compile-input)

(defvar *count* 0)
(defparameter *names* '(alpha beta "gamma" #\d 1.5 2.5d0 1/3 123456789012345678901234567890))
(defconstant +limit+ 10)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun twice-form (form) `(progn ,form ,form)))

(defmacro twice (form) (twice-form form))

(declaim (inline square))
(defun square (x) (* x x))

(defun sum-squares (list)
  (let ((sum 0))
    (dolist (x list sum)
      (incf sum (square x)))))

(defun counter ()
  (let ((n 0))
    (lambda () (incf n))))

(defun classify (x)
  (typecase x
    (integer :integer)
    (string :string)
    (t (cond ((characterp x) :character)
             ((floatp x) :float)
             (t :other)))))

(defun divide (a b)
  (multiple-value-bind (q r) (floor a b)
    (values q r (list q r))))

(defun find-first (predicate list)
  (block search
    (mapc (lambda (x) (when (funcall predicate x) (return-from search x))) list)
    nil))

(defun safe-div (a b)
  (handler-case (/ a b)
    (division-by-zero () :infinity)))

(defun cleanup-order ()
  (let ((log '()))
    (catch 'done
      (unwind-protect (throw 'done (push :thrown log))
        (push :cleanup log)))
    (nreverse log)))

(defun collect-evens (n)
  (loop for i from 0 below n
        when (evenp i) collect i))

(defun nested (x)
  (flet ((add (y) (+ x y)))
    (labels ((down (k acc) (if (zerop k) acc (down (1- k) (add acc)))))
      (down 3 0))))

(defclass point ()
  ((x :initarg :x :accessor point-x)
   (y :initarg :y :accessor point-y)))

(defgeneric norm (p))
(defmethod norm ((p point))
  (+ (square (point-x p)) (square (point-y p))))

(defun places (list)
  (let ((v (vector 1 2 3)))
    (setf (car list) 'first
          (svref v 0) (caddr list))
    (push 'zero list)
    (values list v)))

(symbol-macrolet ((total (car *names*)))
  (defun total () total))

(macrolet ((define-getter (name index) `(defun ,name (list) (nth ,index list))))
  (define-getter second-of 1)
  (define-getter third-of 2))

(declaim (inline alias-map-keys))
(defun alias-map-keys (function table)
  (maphash (lambda (key value) (declare (ignore value)) (funcall function key)) table))

(defun alias-hash-keys (table)
  (let ((keys nil))
    (alias-map-keys (lambda (key) (push key keys)) table)
    keys))

(defun alias-calls (value)
  (let* ((function (lambda (n) (+ value n))) (other function))
    (list (funcall function 1) (funcall other 2))))

(defun run ()
  (let ((table (make-hash-table)))
    (setf (gethash 3 table) :three (gethash 1 table) :one)
    (assert (equal '(1 3) (sort (alias-hash-keys table) #'<))))
  (assert (equal '(8 9) (alias-calls 7)))
  (twice (incf *count*))
  (format t "~S ~S ~S~%" (sum-squares '(1 2 3)) (funcall (counter)) (mapcar #'classify *names*))
  (format t "~S ~S ~S~%" (multiple-value-list (divide 17 5)) (find-first #'stringp *names*)
          (safe-div 1 0))
  (format t "~S ~S ~S~%" (cleanup-order) (collect-evens +limit+) (nested 2))
  (format t "~S ~S ~S~%" (norm (make-instance 'point :x 3 :y 4)) (multiple-value-list (places (list 1 2 3)))
          (list (total) (second-of *names*) (third-of *names*) *count*)))

(run)
