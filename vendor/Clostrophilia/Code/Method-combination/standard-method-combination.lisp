(cl:in-package #:clostrophilia)

(define-method-combination standard ()
  ((around-methods (:around))
   (before-methods (:before))
   ;; kiln: not :REQUIRED.  An effective method with only auxiliary
   ;; methods signals an error when the primary methods would be called
   ;; (see below), not when it is computed: an :AROUND method need not
   ;; call CALL-NEXT-METHOD (Predicament's SIGNAL on a symbol does not).
   (primary-methods ())
   (after-methods (:after)))
  (flet ((call-methods (methods)
           (loop for method in methods
                 collect `(call-method ,method))))
    (let ((all-but-around-form
            (if (null primary-methods)
                '(error "No applicable primary method.")
            (if (and (null before-methods)
                     (null after-methods)
                     (null (rest primary-methods)))
                `(call-method ,(first primary-methods))
                `(multiple-value-prog1
                     (progn ,@(call-methods before-methods)
                            (call-method ,(first primary-methods)
                                         ,(rest primary-methods)))
                   ,@(call-methods (reverse after-methods)))))))
      (if (null around-methods)
          all-but-around-form
          `(call-method ,(first around-methods)
                        (,@(rest around-methods)
                         (make-method ,all-but-around-form)))))))
