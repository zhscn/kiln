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

;;; File output takes the native path and maintains the stream position.
(let* ((program '(:module "packet-file" (:init "init")
                  (:data "init" (:words 2 (:func "f")))
                  (:func "f" (:vars) (:slots) (:block :entry (:return 0 1)))))
       (expected (kiln.kir::portable-backend-packet program))
       (path "build/test/backend-packet-output.lir"))
  (unwind-protect
       (progn
         (with-open-file (out path :direction :output :if-exists :supersede
                                  :element-type '(unsigned-byte 8))
           (show (and (kiln.sys::%write-backend-packet program out)
                      (= (file-position out) (length expected)))))
         (with-open-file (in path :element-type '(unsigned-byte 8))
           (let ((actual (make-array (file-length in))))
             (read-sequence actual in)
             (show (equalp expected actual)))))
    (when (probe-file path) (delete-file path))))
