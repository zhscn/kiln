;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(defun mir-test-parallel-copies (sources kind &optional expected-temporaries)
  (let* ((*func* (kiln.kir::make-kfunc))
         (variables (map 'simple-vector (lambda (source) (declare (ignore source)) (new-var kind)) sources))
         (values (make-hash-table :test 'eq))
         (copies (loop for source across sources for destination across variables
                       collect (cons destination (if (integerp source) (svref variables source) 99))))
         (expected (map 'simple-vector (lambda (copy) (position (cdr copy) variables :test #'eq)) copies))
         (original (symbol-function 'emit)) (operations nil))
    (loop for variable across variables for index from 0 do (setf (gethash variable values) index))
    (unwind-protect
         (progn
           (setf (symbol-function 'emit) (lambda (operation) (push operation operations)))
           (mir-lir-parallel-copies copies))
      (setf (symbol-function 'emit) original))
    (dolist (operation (nreverse operations))
      (assert (member (first operation) '(:set :lir-copy)))
      (when (eq (first operation) :lir-copy)
        (assert (and (kiln.kir::kvar-p (third operation))
                     (eq (svref (second operation) 2) (svref (third operation) 2)))))
      (setf (gethash (second operation) values)
            (if (kiln.kir::kvar-p (third operation)) (gethash (third operation) values) (third operation))))
    (loop for variable across variables for value across expected
          do (assert (= (gethash variable values) (or value 99))))
    (when expected-temporaries
      (assert (= (+ (length sources) expected-temporaries) (length (kiln.kir::kfunc-vars *func*)))))))

(dolist (kind '(:obj :raw :f64))
  (dotimes (a 4) (dotimes (b 4) (dotimes (c 4)
    (mir-test-parallel-copies (map 'simple-vector (lambda (index) (if (= index 3) :constant index))
                                 (vector a b c)) kind))))
  (mir-test-parallel-copies #(1 2 :constant) kind 0)
  (mir-test-parallel-copies #(1 2 0) kind 1)
  (mir-test-parallel-copies #(1 0 3 2) kind 2)
  (mir-test-parallel-copies #(1 0 0 0) kind 1)
  (mir-test-parallel-copies (coerce (loop for i below 32 collect (mod (1+ i) 32)) 'simple-vector) kind 1)
  (mir-test-parallel-copies (coerce (loop for i below 32 collect (logxor i 1)) 'simple-vector) kind 16)
  (mir-test-parallel-copies (coerce (loop for i below 32 collect (if (= i 31) :constant (1+ i))) 'simple-vector) kind 0))
(format t "Parallel copies preserve simultaneous assignments and allocate temporaries only for cycles.~%")
