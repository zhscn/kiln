;;;; Run with the compiler loaded.
(in-package #:kiln.compiler)

(let ((table (make-compiler-eq-table))
      (keys (make-array 257)))
  (dotimes (index (length keys))
    (let ((key (list :key)))
      (setf (svref keys index) key
            (compiler-eq-ref table key) index)))
  (setf (compiler-eq-ref table nil) nil)
  (setf (compiler-eq-ref table (svref keys 0)) :updated)
  #+kiln (kiln.sys:%gc)
  (assert (equal (multiple-value-list (compiler-eq-ref table nil)) '(nil t)))
  (assert (equal (multiple-value-list (compiler-eq-ref table (list :key))) '(nil nil)))
  (assert (eq (compiler-eq-ref table (svref keys 0)) :updated))
  (loop for index from 1 below (length keys)
        do (assert (eql (compiler-eq-ref table (svref keys index)) index))))
(format t "Compiler EQ table preserves identity and values across growth.~%")
