;;;; Standalone protocol fixture: no compiler dependencies or host init file.
(defpackage #:kiln.kir (:use #:cl))
(load "lisp/kir.lisp")
(load "lisp/lir-schema.lisp")
(load "lisp/backend-target.lisp")
(load "lisp/backend-packet.lisp")

(defun write-packet-fixture (path)
  (let ((bytes (kiln.kir::encode-backend-packet
                `(:module "λ\"\\" (:init "init")
                  (:data "init" (:words ,(- (ash 1 63)) ,(1- (ash 1 63))))
                  (:func "f" (:vars (,#(#\v 12 :obj nil) :obj)) (:slots)
                   (:block ,#(#\b 3) (:return ,#(#\v 12 :obj nil) 1)))))))
    (with-open-file (out path :direction :output :if-exists :supersede
                             :element-type '(unsigned-byte 8))
      (map nil (lambda (byte) (write-byte byte out)) bytes))))
