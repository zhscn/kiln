;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

;; Reverse-numbered chains require changes to travel against block order.
(dolist (size '(1 8 128))
  (let* ((function (make-mir-function))
         (blocks (mir-function-blocks function))
         (constant (mir-add-value function :obj 0 0)))
    (dotimes (id (1+ size)) (hir-push (make-mir-block :id id) blocks))
    (dotimes (offset size)
      (let* ((id (1+ offset)) (block (mir-at blocks id))
             (parameter (mir-add-value function :obj id -1)))
        (setf (mir-block-parameters block) (vector parameter)
              (mir-block-terminator block)
              (if (= id 1)
                  (make-mir-terminator :kind 2 :operands (vector parameter))
                  (make-mir-terminator :kind 0 :edges
                    (vector (make-mir-edge :target (1- id) :arguments (vector parameter))))))))
    (setf (mir-block-terminator (mir-at blocks 0))
          (make-mir-terminator :kind 0 :edges
            (vector (make-mir-edge :target size :arguments (vector constant)))))
    (multiple-value-bind (aliases live) (mir-block-parameter-plan function)
      (assert (svref live constant))
      (loop for block across (subseq (hir-vector blocks) 1)
            do (assert (= constant (svref aliases (svref (mir-block-parameters block) 0))))))))
(format t "Block parameter aliases resolve against reverse dependency order.~%")
