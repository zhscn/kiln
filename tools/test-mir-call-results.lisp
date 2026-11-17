;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

;; Published queue results must equal an independent local solve against the
;; final interprocedural inputs, including recursion and unknown fallback.
(dolist (form
         '((flet ((step (x) (+ x 1))) (declare (notinline step)) (step 4))
           (labels ((walk (n) (if (zerop n) (values 1 2) (walk (1- n)))))
             (declare (notinline walk)) (walk 4))
           (labels ((left (x) (right x)) (right (x) (left x)))
             (declare (notinline left right)) (left 1))
           (let ((x 1))
             (flet ((read-x () x) (write-x (v) (setf x v)))
               (declare (notinline read-x write-x))
               (write-x 'changed) (read-x)))
           (let ((x 3))
             (flet ((use-x (&optional (y x)) (values y x)))
               (declare (notinline use-x)) (use-x)))
           (flet ((unreferenced (x) (values x))) (identity 1))))
  (let* ((forms (front-end-forms (list form)))
         (unit (hir-to-mir (toplevel-form-ast (first forms))))
         (analysis (mir-infer-calls unit)))
    (loop for function across (hir-buffer-view (mir-unit-functions unit))
          for id = (mir-function-id function) do
      (multiple-value-bind (types packets)
          (mir-compute-types function
            :summaries (mir-call-analysis-summaries analysis)
            :value-summaries (mir-call-analysis-value-summaries analysis)
            :functions (svref (mir-call-analysis-identities analysis) id)
            :inputs (svref (mir-call-analysis-inputs analysis) id)
            :captures (svref (mir-call-analysis-capture-inputs analysis) id)
            :cell-types (mir-call-analysis-cell-types analysis)
            :cell-points (svref (mir-cell-aliases-points (mir-call-analysis-cell-aliases analysis)) id))
        (assert (equalp types (svref (mir-call-analysis-types analysis) id)))
        (assert (equalp packets (svref (mir-call-analysis-packets analysis) id)))))))
(format t "Published call facts match independent solves at the final inputs.~%")
