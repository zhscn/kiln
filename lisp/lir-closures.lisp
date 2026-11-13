(in-package #:kiln.kir)

;;;; Capture reads alone omit unused environment positions. Allocation
;;;; declarations establish each entry's complete shape; capture stores
;;;; retain the entry name so the backend can check every position.

(defun lir-scan-closure-statement (state statement)
  (when (member (first statement) '(:alloc-closure :stack-closure))
    (let ((variable (second statement))
          (entry (if (eq (first statement) :stack-closure) (fourth statement) (third statement))))
      (multiple-value-bind (old found) (gethash variable (lir-function-closure-entries state))
        (when (and found (not (equal old entry)))
          (lir-function-error state "closure variable has conflicting entries")))
      (setf (gethash variable (lir-function-closure-entries state)) entry)
      (lir-record-alias state variable :unknown))))

(defun lir-closure-entry (state variable)
  (let ((seen (make-hash-table :test 'equalp)))
    (loop
      (let ((entry (gethash variable (lir-function-closure-entries state))))
        (when entry (return entry)))
      (when (gethash variable seen)
        (lir-function-error state "closure alias cycle"))
      (setf (gethash variable seen) t)
      (let ((alias (gethash variable (lir-function-value-aliases state))))
        (unless (and alias (not (eq alias :unknown)))
          (lir-function-error state "capture store has no known closure entry"))
        (setf variable alias)))))

(defun lir-closure-statement (state statement)
  (let ((args (rest statement)))
    (ecase (first statement)
      (:alloc-closure
       (lir-no-handler state (fourth args))
       (unless (eql (third args) (gethash (second args) (lir-data-function-captures (lir-function-data state))))
         (lir-function-error state "closure allocation disagrees with its entry shape"))
       (lir-emit state `(:alloc-closure ,(first args) ,(second args) :heap)))
      (:closure-set
       (lir-emit state `(:capture-set ,(first args) ,(lir-closure-entry state (first args))
                                     ,(second args) ,(lir-operand state (third args) :obj)))))))
