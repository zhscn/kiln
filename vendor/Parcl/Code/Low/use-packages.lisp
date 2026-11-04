(cl:in-package #:parcl-low)

(define-condition conflicts ()
  ((%conflicts
      :initarg :conflicts
      :reader conflicts))
  #+kiln ; kiln: CONFLICTS is a list of (symbol package other-symbol).
  (:report (lambda (condition stream)
             (format stream "Conflicts:~%")
             (loop for (symbol package other) in (conflicts condition)
                   do (format stream "Symbol ~s from package ~s conflicts with ~s~%"
                              symbol package other))))
  #-kiln
  (:report (lambda (condition stream)
             (format stream "Conflicts:~%")
             (loop for entries being each hash-value of (conflicts condition)
                   do (loop for (symbol . packages) in entries
                            do (format stream "Symol ~s from packages" symbol)
                            (loop for package in packages
                                  do (format stream " ~s" package))
                            (terpri stream))))))

;;; Currently, we do not offer any restarts.  The dictionary entry on
;;; USE-PACKAGE does not say that a correctable error has to be
;;; signaled, but in section 11.1.1.2.5, it is said that any time a
;;; name conflict is about to occur, a correctable error is signaled.
;;; So at some point, we must define restarts.  The problem is to
;;; define exactly what restarts are useful, in particular so that
;;; they can be used programmatically.

#-kiln
(defmethod use-packages (client package packages-to-use)
  (let ((added-packages
          (set-difference (use-list client package) packages-to-use)))
    (let ((accessible-symbols '()))
      (map-symbols client package
                   (lambda (symbol)
                     (push (list symbol) accessible-symbols)))
      (loop for package-to-use in added-packages
            do (map-external-symbols
                client package-to-use
                (lambda (symbol)
                  (let ((collision (find symbol accessible-symbols
                                         :key #'car
                                         :test
                                         (lambda (s1 s2)
                                           (symbol-names-equal client s1 s2)))))
                    (if (null collision)
                        (push (list symbol) accessible-symbols)
                        (push accessible-symbols (cdr collision)))))))
      (let ((conflicts
              (remove-if (lambda (x) (null (cdr x))) accessible-symbols)))
        (unless (null conflicts)
          (error 'conflicts
                 :conflicts conflicts)))
      (setf (use-list client package)
            (append (use-list client package) packages-to-use)))))

;;; kiln: the method above computes the added packages the wrong way
;;; round (the packages already used, not the new ones), takes a symbol
;;; that is accessible through two packages for a conflict, ignores
;;; shadowing symbols, and does not update the used-by lists.
#+kiln
(defmethod use-packages (client package packages-to-use)
  (let ((added '()))
    (dolist (p packages-to-use)
      (unless (or (eq p package)
                  (member p (use-list client package))
                  (member p added))
        (push p added)))
    (setf added (reverse added))
    (let ((shadowing (shadowing-symbols client package))
          (conflicts '()))
      (flet ((check (symbol from name)
               (multiple-value-bind (other status)
                   (find-symbol client package name)
                 (when (and status
                            (not (eq other symbol))
                            (not (member other shadowing)))
                   (push (list symbol from other) conflicts)))
               (dolist (q added)
                 (unless (eq q from)
                   (multiple-value-bind (other status)
                       (find-present-symbol client q name)
                     (when (and (eq status :external)
                                (not (eq other symbol))
                                (null (nth-value 1 (find-present-symbol
                                                    client package name))))
                       (push (list symbol from other) conflicts)))))))
        (dolist (p added)
          (map-external-symbols client p
                                (lambda (symbol)
                                  (check symbol p (symbol-name client symbol))))))
      (unless (null conflicts)
        (error 'conflicts :conflicts conflicts))
      (setf (use-list client package)
            (append (use-list client package) added))
      (dolist (p added)
        (push package (used-by-list client p)))
      t)))
