(cl:in-package #:parcl-low-class)

;;; kiln: the names already visited are in a hash table (upstream: a list
;;; searched with SYMBOL-NAMES-EQUAL for every inherited symbol, quadratic;
;;; kiln's compiler maps the symbols of every package for each module).
;;; kiln's client compares symbol names with STRING=, so EQUAL on the names.
(defmethod parcl-low:map-symbols (client package function)
  (let ((visited (make-hash-table :test 'equal)))
    (loop for entry in (symbol-entries package)
          for symbol = (entry-symbol entry)
          do (funcall function symbol)
             (setf (gethash (symbol-name symbol) visited) t))
    (loop for package in (use-list package)
          do (parcl-low:map-external-symbols
              client package
              (lambda (symbol)
                (let ((name (symbol-name symbol)))
                  (unless (gethash name visited)
                    (funcall function symbol)
                    (setf (gethash name visited) t))))))))
