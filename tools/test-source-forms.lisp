;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let* ((symbol (make-symbol "private"))
       (cycle (list symbol))
       (array (make-array 2 :element-type '(unsigned-byte 8) :initial-contents '(17 23)))
       (graph (vector cycle cycle symbol symbol "λ中文" 123456789012345678901234567890 3/7 array)))
  (setf (cdr cycle) cycle)
  (let* ((restored (decode-source-form (encode-source-form graph)))
         (cell (svref restored 0)))
    (assert (eq cell (svref restored 1)))
    (assert (eq cell (cdr cell)))
    (assert (eq (car cell) (svref restored 2)))
    (assert (eq (svref restored 2) (svref restored 3)))
    (assert (null (symbol-package (svref restored 2))))
    (assert (equalp (subseq restored 4 7) (subseq graph 4 7)))
    (assert (eq array (svref restored 7)))))

(dolist (bits '(0 #x80000000 #x7f800000 #xff800000 #x7fc00123))
  (let* ((value (sb-kernel:make-single-float
                 (if (logbitp 31 bits) (- bits #x100000000) bits)))
         (restored (decode-source-form (encode-source-form value))))
    (assert (= bits (single-float-bits restored)))))

(dolist (bits '(0 #x80000000 #x7ff00000 #xfff00000 #x7ff80000))
  (let* ((value (sb-kernel:make-double-float
                 (if (logbitp 31 bits) (- bits #x100000000) bits) 291))
         (restored (decode-source-form (encode-source-form value))))
    (assert (= bits (double-float-high-bits restored)))
    (assert (= 291 (double-float-low-bits restored)))))

(assert (source-form-equal-p (list (make-symbol "same")) (list (make-symbol "same"))))
(let ((symbol (make-symbol "same")))
  (assert (not (source-form-equal-p (list symbol symbol)
                                   (list (make-symbol "same") (make-symbol "same"))))))
(assert (equalp (encode-source-form (list (make-symbol "OBJECT0")) t)
                (encode-source-form (list (make-symbol "OBJECT37")) t)))
(format t "Source graph codec passed.~%")
