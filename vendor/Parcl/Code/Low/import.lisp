(cl:in-package #:parcl-low)

(defmethod import (client package symbol)
  #+sbcl (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let ((name (symbol-name client symbol)))
    (multiple-value-bind (present-symbol status)
        (find-present-symbol client package name)
      (when (and status (eq symbol present-symbol))
        (return-from import t))
      (unless (or (null status) (eq symbol present-symbol))
        ;; We have a conflict.
        (restart-case
            (error 'symbol-conflict
                   :package package
                   :conflicting-symbols (list symbol present-symbol))
          (unintern-existing-symbol ()
            (unintern client package present-symbol)
            (ensure-present-symbol client package symbol :internal))
          (do-not-import ()
            (return-from import t)))))
    (loop for used-package in (use-list client package)
          do (multiple-value-bind (inherited-symbol status)
                 (find-present-symbol client used-package name)
               (when (eq status :external)
                 (if (eq symbol inherited-symbol)
                     (ensure-present-symbol client package symbol)
                     ;; We have a conflict.
                     (restart-case
                         (error 'symbol-conflict
                   :package package
                                :conflicting-symbols
                                (list symbol inherited-symbol))
                       (make-a-shadowing-symbol ()
                         (shadowing-import client package symbol)
                         (return-from import t))
                       (do-not-import ()
                           (return-from import t)))))))
    (ensure-present-symbol client package symbol :internal)
    ;; kiln: an imported symbol without a home package gets PACKAGE as
    ;; its home (CLHS IMPORT), as the generic function's comment says.
    #+kiln
    (when (null (symbol-package client symbol))
      (setf (symbol-package client symbol) package))
    (return-from import t)))
