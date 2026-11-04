;;;; FORMAT (docs/10 §18): kiln's client of Invistra, intrinsic: FORMAT
;;;; and FORMATTER are Invistra's. The client is also the printer's
;;;; (Invistra prints through Incless).

(in-package #:invistra)

(defclass kiln-client (incless::kiln-client client) ())

(setf incless::*client* (make-instance 'kiln-client))

(define-interface :client-form incless::*client* :client-class kiln-client :intrinsic t)

;;; Conditions print as their report when not escaping (CLHS 9.1.3).
(defmethod print-object ((condition condition) stream)
  (let ((report (clostrophilia::condition-report condition)))
    (if (or *print-escape* *print-readably* (null report))
        (call-next-method)
        (funcall report condition stream))))

;;; Cyclosis' Y-OR-N-P and YES-OR-NO-P get FORMAT through Trinsic.
(defmethod trinsic:cell-value
    ((client cyclosis::kiln-client) (name (eql 'cl:format)) (type (eql 'cl:function)))
  #'format)
