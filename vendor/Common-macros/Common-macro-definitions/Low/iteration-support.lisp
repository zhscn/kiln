(cl:in-package #:common-macro-definitions)

;;; Check that iteration body is a proper list.
(defun body-must-be-proper-list (body)
  (unless (ecc:proper-list-p body)
    (error 'malformed-body
           :body body)))

(defun check-variable-clauses (variable-clauses)
  (unless (ecc:proper-list-p variable-clauses)
    (error 'malformed-variable-clauses
           :clauses variable-clauses))
  (mapc
   (lambda (clause)
     (unless (or (symbolp clause)
                 (and (consp clause)
                      (symbolp (car clause))
                      (or (null (cdr clause))
                          (null (cddr clause))
                          (null (cdddr clause)))))
       (error 'malformed-variable-clause
              :found clause)))
   variable-clauses))

(defun extract-bindings (variable-clauses)
  (mapcar
   (lambda (clause)
     (cond ((symbolp clause) clause)
           ((null (cdr clause)) (car clause))
           (t (list (car clause) (cadr clause)))))
   variable-clauses))

(defun extract-updates (variable-clauses)
  (if (null variable-clauses) '()
      (let ((clause (car variable-clauses)))
        (if (and (consp clause)
                 (not (null (cddr clause))))
            (list* (car clause)
                   (caddr clause)
                   (extract-updates (cdr variable-clauses)))
            (extract-updates (cdr variable-clauses))))))

;;; This implementation does not use any iteration construct, nor any
;;; operations on sequences (other than the ones we define ourself
;;; here).  Implementations can therefore load this file very early on
;;; in the bootstrap process.  It allows for operations on sequences
;;; and the loop macro to be defined in terms of the macros defined
;;; here.

(defun do-dostar-expander
    (let-type setq-type variable-clauses end-test body)
  ;; Do some syntax checking.
  (check-variable-clauses variable-clauses)
  (body-must-be-proper-list body)
  (unless (and (ecc:proper-list-p end-test)
               (not (null end-test)))
    (error 'malformed-end-test
           :found end-test))
  (multiple-value-bind (declarations forms)
      (ecc:separate-ordinary-body body)
    (let ((start-tag (gensym)))
      `(block nil
         (,let-type ,(extract-bindings variable-clauses)
                    ,@declarations
                    (tagbody
                       ,start-tag
                       (when ,(car end-test)
                         (return
                           (progn ,@(cdr end-test))))
                       ,@forms
                       (,setq-type ,@(extract-updates
                                        variable-clauses))
                       (go ,start-tag)))))))
