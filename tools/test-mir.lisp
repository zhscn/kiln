;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(defun mir-test-unit (form)
  (let* ((*source-file* "mir-model") (*toplevel-source* nil)
         (forms (front-end-forms (list form))))
    (hir-to-mir (toplevel-form-ast (first forms)))))

(dolist (form '((let ((x 1)) (if (identity x) (setq x 2) (setq x 3)) x)
                (let ((x 0)) (tagbody loop (setq x (1+ x)) (if (< x 3) (go loop))) x)
                (block done (if (identity t) (return-from done (values 1 2)) (values 3 4)))
                (multiple-value-prog1 (values 1 2) (identity 3))))
  (verify-mir (mir-test-unit form)))

(let* ((unit (mir-test-unit '(if (identity t) 1 2)))
       (function (mir-at (mir-unit-functions unit) 0))
       (block (mir-at (mir-function-blocks function) 0))
       (edge (svref (mir-terminator-edges (mir-block-terminator block)) 0))
       (saved (mir-edge-arguments edge)))
  (setf (mir-edge-arguments edge) #(0))
  (assert (handler-case (progn (verify-mir unit) nil) (mir-error () t)))
  (setf (mir-edge-arguments edge) saved)
  (verify-mir unit)
  (let ((computations 0))
    (flet ((compute (f) (declare (ignore f)) (incf computations)))
      (assert (= 1 (mir-analysis function :test #'compute)))
      (assert (= 1 (mir-analysis function :test #'compute)))
      (mir-run-pass unit function #'identity :preserves '(:test))
      (assert (= 1 (mir-analysis function :test #'compute)))
      (mir-run-pass unit function #'identity)
      (assert (= 2 (mir-analysis function :test #'compute))))))

(let* ((unit (mir-test-unit '(if (identity t) 1 2)))
       (function (mir-at (mir-unit-functions unit) 0))
       (values (hir-vector (mir-function-values function)))
       (instructions (hir-vector (mir-function-instructions function)))
       (entry (mir-at (mir-function-blocks function) 0))
       (use (find 10 instructions :key #'mir-instruction-kind))
       (foreign (find-if (lambda (value) (and (plusp (mir-value-block value))
                                              (eq (mir-value-representation value) :bundle))) values)))
  (declare (ignore entry))
  (setf (mir-instruction-operands use) (vector (mir-value-id foreign)))
  (assert (handler-case (progn (verify-mir unit) nil) (mir-error () t))))

(let* ((unit (mir-test-unit '(identity 1)))
       (function (mir-at (mir-unit-functions unit) 0))
       (call (find 6 (hir-vector (mir-function-instructions function)) :key #'mir-instruction-kind)))
  (setf (mir-instruction-effects call) 0)
  (assert (handler-case (progn (verify-mir unit) nil) (mir-error () t))))

(let* ((unit (mir-test-unit '(identity 1)))
       (text (with-output-to-string (stream) (print-mir unit stream))))
  (assert (search "function 0" text)))

(dolist (form '((catch 'tag (throw 'tag 3))
                (unwind-protect (identity 1) (identity 2))
                (let ((x (identity 1))) (lambda () x))
                (function (lambda (&optional x) x))))
  (assert (handler-case (progn (mir-test-unit form) nil) (mir-unsupported () t))))

(let* ((unit (mir-test-unit '(function (lambda (x) (declare (type nil x)) x))))
       (function (mir-at (mir-unit-functions unit) 1)))
  (assert (find 11 (hir-vector (mir-function-instructions function)) :key #'mir-instruction-kind)))

(format t "MIR graph, SSA validation and analysis invalidation passed.~%")

;;; MIR facts are derived from SSA, independently of HIR annotations.
(defun mir-test-checks (form)
  (let* ((unit (mir-test-unit form))
         (function (mir-at (mir-unit-functions unit) 0))
         (types (mir-infer-types function)))
    (values (loop for instruction across (hir-vector (mir-function-instructions function))
                  when (= 11 (mir-instruction-kind instruction))
                    collect (not (null (mir-check-proven-p instruction types))))
            function unit)))

(assert (equal '(t) (mir-test-checks '(the fixnum (if (identity t) 1 2)))))
(assert (equal '(nil) (mir-test-checks '(the fixnum (if (identity t) 1 'bad)))))
(assert (equal '(nil) (mir-test-checks '(the fixnum (mir-unknown 1)))))
(assert (equal '(t) (mir-test-checks '(the null (values)))))
(assert (equal '(nil) (mir-test-checks '(the nil 1))))
(assert (equal '(nil) (mir-test-checks '(the (integer 0 1) 2))))
(assert (equal '(t) (mir-test-checks
                    '(let ((x 1))
                       (tagbody again (if (identity t) (go done)) (setq x 2) (go again) done)
                       (the fixnum x)))))
(assert (equal '(nil) (mir-test-checks
                      '(let ((x 1))
                         (tagbody again (if (identity t) (go done)) (setq x 'bad) (go again) done)
                         (the fixnum x)))))
(multiple-value-bind (checks function unit) (mir-test-checks '(the fixnum 1))
  (declare (ignore checks))
  (let ((types (mir-infer-types function)))
    (assert (eq types (mir-infer-types function)))
    (mir-run-pass unit function
                  (lambda (f)
                    (loop for instruction across (hir-vector (mir-function-instructions f))
                          when (and (= 0 (mir-instruction-kind instruction))
                                    (eql 1 (mir-instruction-data instruction)))
                            do (setf (mir-instruction-data instruction) 'bad))))
    (assert (not (eq types (mir-infer-types function))))
    (assert (loop for instruction across (hir-vector (mir-function-instructions function))
                  always (not (mir-check-proven-p instruction (mir-infer-types function)))))))
(let* ((unit (mir-test-unit '(if (identity t) 1 2)))
       (function (mir-at (mir-unit-functions unit) 0)))
  (assert (= (1- (ash 1 (hir-buffer-count (mir-function-blocks function))))
             (mir-control-flow function))))
(assert (equal '(t) (mir-test-checks
                    '(let ((x 1))
                       (tagbody (go done) skipped (setq x 'bad) done)
                       (the fixnum x)))))

(format t "MIR type propagation and declaration proofs passed.~%")

(dolist (form '((the (integer 5 5) (+ 2 3))
                (the (integer -6 -6) (- 2 8))
                (the (integer -12 -12) (* -3 4))
                (the (integer 5 5) (1+ 4))
                (the (integer 3 3) (1- 4))
                (the double-float (+ 1d0 2d0))
                (the (integer 0 7) (logand (mir-unknown) 7))
                (the null (values))
                (the (integer 8 8) (values 8 9))
                (the fixnum (identity 2))))
  (assert (equal '(t) (mir-test-checks form))))
(dolist (form '((the fixnum (+ #.+hir-fixnum-max+ 1))
                (the (integer 0 10) (+ 10 1))
                (the fixnum (mir-unknown 2))
                (the fixnum (funcall (mir-unknown) 2))))
  (assert (equal '(nil) (mir-test-checks form))))
;;; A growing cycle must reach a post-fixed point, rather than retaining the
;;; finite prefix seen during the first few iterations.
(assert (equal '(t) (mir-test-checks
                    '(let ((x 0))
                       (tagbody again (setq x (1+ x)) (if (mir-unknown) (go again)))
                       (the integer x)))))
(assert (equal '(nil) (mir-test-checks
                      '(let ((x 0))
                         (tagbody again (setq x (1+ x)) (if (mir-unknown) (go again)))
                         (the fixnum x)))))
(format t "MIR call types and interval widening passed.~%")

(assert (equal '(nil t) (mir-test-checks
                        '(the integer (the fixnum (mir-unknown))))))
(assert (equal '(nil nil t) (mir-test-checks
                            '(let ((x (mir-unknown)))
                               (the integer x)
                               (let ((y (the fixnum x))) (the integer y))))))
(let* ((unit (mir-test-unit
              '(function (lambda (x)
                           (declare (type fixnum x))
                           (the integer (+ x 1))))))
       (function (mir-at (mir-unit-functions unit) 1))
       (types (mir-infer-types function))
       (checks (remove-if-not (lambda (instruction) (= 11 (mir-instruction-kind instruction)))
                              (hir-vector (mir-function-instructions function)))))
  (assert (= 2 (length checks)))
  (assert (not (mir-check-proven-p (svref checks 0) types)))
  (assert (mir-check-proven-p (svref checks 1) types))
  (let ((value (mir-at (mir-function-values function)
                       (mir-instruction-result (svref checks 1)))))
    (setf (mir-value-representation value) :obj)
    (assert (handler-case (progn (verify-mir unit) nil) (mir-error () t)))))
(format t "MIR declaration result types passed.~%")

(assert (equal '(t nil) (mir-test-checks
                        '(let ((x (mir-unknown)))
                           (if (integerp x) (the integer x) (the integer x))))))
(assert (equal '(nil t) (mir-test-checks
                        '(let ((x (mir-unknown)))
                           (if x (the null x) (the null x))))))
(assert (equal '(t nil) (mir-test-checks
                        '(let ((x (mir-unknown)))
                           (if (null x) (the null x) (the null x))))))
(assert (equal '(t) (mir-test-checks
                    '(let ((x (mir-unknown)))
                       (if (consp x) (the cons x) nil)))))
(assert (equal '(nil) (mir-test-checks
                      '(let ((x (mir-unknown)))
                         (if (integerp x) (setq x 'changed))
                         (the integer x)))))
(assert (equal '(nil) (mir-test-checks
                      '(let ((x (mir-unknown)))
                         (if (integerp x) (progn (setq x 'changed) (the integer x)) nil)))))
(assert (equal '(nil) (mir-test-checks
                      '(let ((x (mir-unknown)))
                         (if (mir-unknown x) (the integer x) nil)))))
(format t "MIR conditional edge types passed.~%")

(dolist (form '((let ((x (the fixnum (mir-unknown))))
                 (if (< x 10) (the (integer #.+hir-fixnum-min+ 9) x)
                     (the (integer 10 #.+hir-fixnum-max+) x)))
                (let ((x (the fixnum (mir-unknown))))
                  (if (< 10 x) (the (integer 11 #.+hir-fixnum-max+) x)
                      (the (integer #.+hir-fixnum-min+ 10) x)))
                (let ((x (the fixnum (mir-unknown))))
                  (if (<= x 10) (the (integer #.+hir-fixnum-min+ 10) x)
                      (the (integer 11 #.+hir-fixnum-max+) x)))
                (let ((x (the fixnum (mir-unknown))))
                  (if (= x 10) (the (integer 10 10) x) (the fixnum x)))))
  (assert (equal '(nil t t) (mir-test-checks form))))
(assert (equal '(nil nil) (mir-test-checks
                          '(let ((x (the fixnum (mir-unknown))))
                             (if (< x (progn (setq x 99) 10))
                                 (the (integer #.+hir-fixnum-min+ 9) x) nil)))))
(format t "MIR comparison edge ranges passed.~%")

;;; Check the abstract bounds against concrete comparisons, including both
;;; truth values and intervals that overlap or have no satisfying pair.
(dolist (name '(< <= > >= =))
  (loop for low from -3 to 3 do
    (loop for high from low to 3 do
      (loop for other-low from -3 to 3 do
        (loop for other-high from other-low to 3 do
          (dolist (positive '(t nil))
            (let ((type (inferred-comparison-range
                         name (hir-integer-range low high)
                         (hir-integer-range other-low other-high) positive)))
              (loop for x from low to high do
                (loop for y from other-low to other-high
                      when (eq (not (null (funcall name x y))) positive)
                        do (assert (hir-known-subtype-p (hir-integer-range x x) type)))))))))))
(format t "Integer comparison range soundness passed.~%")
