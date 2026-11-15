;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(defun mir-flow-test-unit (form)
  (let* ((*source-file* "mir-function-flow-model") (*toplevel-source* nil)
         (forms (front-end-forms (list `(locally (declare (optimize (debug 0))) ,form))))
         (*toplevel* (first forms)))
    (hir-to-mir (toplevel-form-ast *toplevel*))))

(defun mir-flow-test-function (unit name)
  (or (find name (hir-vector (mir-unit-functions unit)) :key #'mir-function-name)
      (error "Missing test function ~S" name)))

(defun mir-flow-test-input (unit name)
  (svref (mir-function-flow-inputs (mir-infer-function-flow unit))
         (mir-function-id (mir-flow-test-function unit name))))

(let* ((unit (mir-flow-test-unit
              '(flet ((inc (x) (+ x 1)) (dec (x) (- x 1)) (use (f x) (funcall f x)))
                 (declare (notinline inc dec use)) (identity #'dec) (use #'inc 3))))
       (inc (mir-function-id (mir-flow-test-function unit 'inc)))
       (dec (mir-function-id (mir-flow-test-function unit 'dec)))
       (use (mir-flow-test-function unit 'use))
       (root (svref (hir-vector (mir-unit-functions unit)) 0))
       (flow (mir-infer-function-flow unit))
       (calls (mir-infer-calls unit)))
  (assert (eql inc (svref (mir-flow-test-input unit 'use) 0)))
  (assert (member inc (svref (mir-function-flow-outgoing flow) (mir-function-id use))))
  (assert (eq flow (mir-infer-function-flow unit)))
  (assert (eq (mir-call-analysis-identities calls) (mir-function-flow-identities flow)))
  (mir-run-pass unit root
    (lambda (function)
      (let ((changed 0))
        (loop for instruction across (hir-vector (mir-function-instructions function))
              when (and (= 5 (mir-instruction-kind instruction))
                        (eql inc (mir-instruction-data instruction))) do
                (setf (mir-instruction-data instruction) dec)
                (incf changed))
        (assert (plusp changed)))))
  (assert (not (eq flow (mir-infer-function-flow unit))))
  (assert (not (eq calls (mir-infer-calls unit))))
  (assert (eql dec (svref (mir-flow-test-input unit 'use) 0))))

(dolist (body '((progn (use #'inc 3) (use #'dec 3))
                (progn (print #'use) (use #'inc 3))
                (multiple-value-call #'use (values #'inc 3))))
  (let ((unit (mir-flow-test-unit
               `(flet ((inc (x) (+ x 1)) (dec (x) (- x 1)) (use (f x) (funcall f x)))
                  (declare (notinline inc dec use)) ,body))))
    (assert (eq :unknown (svref (mir-flow-test-input unit 'use) 0)))))

(let* ((unit (mir-flow-test-unit
              '(labels ((inc (x) (+ x 1)) (give () #'inc))
                 (declare (notinline inc give)) (funcall (give) 3))))
       (flow (mir-infer-function-flow unit))
       (inc (mir-function-id (mir-flow-test-function unit 'inc)))
       (give (mir-function-id (mir-flow-test-function unit 'give))))
  (assert (eql inc (svref (mir-function-flow-summaries flow) give)))
  (assert (member inc (svref (mir-function-flow-outgoing flow) 0)))
  (assert (logbitp inc (mir-function-flow-external flow))))

(let* ((unit (mir-flow-test-unit
              '(labels ((walk (n) (if (zerop n) 1 (dispatch #'walk (1- n))))
                        (dispatch (f n) (funcall f n)))
                 (walk 3))))
       (flow (mir-infer-function-flow unit))
       (walk (mir-function-id (mir-flow-test-function unit 'walk)))
       (dispatch (mir-function-id (mir-flow-test-function unit 'dispatch)))
       (before (map 'list (lambda (function) (hir-buffer-count (mir-function-instructions function)))
                    (hir-vector (mir-unit-functions unit)))))
  (assert (eql walk (svref (mir-flow-test-input unit 'dispatch) 0)))
  (assert (logbitp walk (mir-function-flow-recursive flow)))
  (assert (logbitp dispatch (mir-function-flow-recursive flow)))
  (mir-inline-local-functions unit)
  (assert (equal before (map 'list (lambda (function) (hir-buffer-count (mir-function-instructions function)))
                             (hir-vector (mir-unit-functions unit))))))

(let* ((unit (mir-flow-test-unit
              '(labels ((a (f) (b f)) (b (f) (a f))) (declare (notinline a b)) nil)))
       (flow (mir-infer-function-flow unit)))
  (loop for inputs across (mir-function-flow-inputs flow) do
    (assert (every (lambda (value) (eq value :unknown)) inputs)))
  (assert (every (lambda (value) (eq value :unknown)) (mir-function-flow-summaries flow))))

(format t "MIR function flow preserves closed inputs, primary results, escape boundaries, recursive groups and cache revisions.~%")

(let* ((unit (mir-flow-test-unit
              '(flet ((inc (x) (+ x 1)) (use (f x) (funcall f x)))
                 (declare (notinline use)) (use #'inc 3))))
       (use (mir-flow-test-function unit 'use)))
  (assert (find 7 (hir-vector (mir-function-instructions use)) :key #'mir-instruction-kind))
  (mir-inline-local-functions unit)
  (assert (not (find 7 (hir-vector (mir-function-instructions use)) :key #'mir-instruction-kind)))
  (verify-mir unit))
(format t "MIR function inputs expose callback bodies to CFG inlining.~%")

(let* ((unit (mir-flow-test-unit
              '(flet ((inc (x) (+ x 1)) (dec (x) (- x 1)) (use (f x) (funcall f x)))
                 (declare (notinline inc dec use)) (use #'dec) (use #'inc 3))))
       (inc (mir-function-id (mir-flow-test-function unit 'inc))))
  (assert (eql inc (svref (mir-flow-test-input unit 'use) 0))))

(let* ((unit (mir-flow-test-unit
              '(labels ((inc (x) (+ x 1)) (give (bad) (if bad 17 #'inc)))
                 (declare (notinline inc give)) (funcall (give nil) 3))))
       (give (mir-function-id (mir-flow-test-function unit 'give))))
  (assert (eq :unknown (svref (mir-function-flow-summaries (mir-infer-function-flow unit)) give))))
(format t "MIR function flow excludes invalid entries and rejects mixed primary targets.~%")
