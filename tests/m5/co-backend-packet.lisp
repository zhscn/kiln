;;; Native and portable encoders share the same deterministic wire schema.
(defun show (x) (write-line (prin1-to-string x)))
(dolist (form (list
              '(:module "λ\"\\" (:init "i") (:data "i" (:words 2 (:func "f"))))
              (list :words (- (ash 1 63)) (1- (ash 1 63)))
              (list :vars (list (vector #\v 12 :obj nil) :obj) (vector #\b 3))
              '(:Λ :é cl:car cl:t nil "λ")))
  (show (equalp (kiln.kir::encode-backend-packet form)
                (kiln.kir::portable-backend-packet form))))
(let* ((literal (list 1 2))
       (function (compile nil `(lambda () ',literal))))
  (kiln.sys:%gc)
  (show (eq (funcall function) literal)))
