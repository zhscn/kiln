(cl:in-package #:parcl-low)

(defmethod unuse-package (client package package-to-unuse)
  (unless (member package-to-unuse (use-list client package)
                  :test #'eq)
    (error 'package-is-not-used
           :package package
           :package-to-unuse package-to-unuse))
  (setf (use-list client package)
        (delete package-to-unuse (use-list client package)))
  ;; kiln: keep the used-by list in step.
  #+kiln
  (setf (used-by-list client package-to-unuse)
        (remove package (used-by-list client package-to-unuse))))
