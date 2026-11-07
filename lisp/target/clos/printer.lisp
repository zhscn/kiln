;;;; The printer: kiln's client of Incless, intrinsic: WRITE,
;;;; PRIN1, PRINC, PRINT-OBJECT, PRINT-UNREADABLE-OBJECT and the
;;;; ...-TO-STRING functions are Incless'. (PRINT itself is still compiled
;;;; inline to the runtime's printer.)

(in-package #:incless)

(defclass kiln-client (client) ())

(defvar *client* (make-instance 'kiln-client))

(defmethod class-slot-names ((client kiln-client) class)
  (mapcar #'clostrophilia:slot-definition-name (clostrophilia:class-slots class)))

;;; An object's identity: its identity hash (stable across collections).
(defmethod write-identity ((client kiln-client) object stream)
  (write-char #\@ stream)
  (let ((*print-base* 16) (*print-radix* t))
    (write-object client (kiln.sys:%primop :identity-hash object) stream)))

(define-interface :client-form *client* :client-class kiln-client :intrinsic t)
