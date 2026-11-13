(in-package #:kiln.kir)

;;;; Source stack storage is established in the entry block and remains
;;;; registered through the lexical body. Describe each object and its
;;;; root region together so Rust can initialize and link them atomically.

(defun lir-stack-shape (state slot)
  (or (gethash slot (lir-function-stack-shapes state))
      (lir-function-error state "unknown stack storage ~S" slot)))

(defun lir-prepare-stack (state parts)
  (let* ((slots (rest (assoc :slots parts)))
         (entry (find :block parts :key #'first))
         (entries (make-hash-table :test 'equalp))
         (closures (make-hash-table :test 'equalp))
         (initialized (make-hash-table :test 'equalp))
         (outer :nil) (declarations '()))
    (dolist (slot slots)
      (when (gethash (first slot) (lir-function-stack-shapes state))
        (lir-function-error state "duplicate stack storage ~S" (first slot)))
      (setf (gethash (first slot) (lir-function-stack-shapes state)) (second slot)))
    (dolist (part parts)
      (when (eq (first part) :block)
        (dolist (statement (cddr part))
          (case (first statement)
            (:stack-closure
             (let ((slot (third statement)) (name (fourth statement)))
               (multiple-value-bind (old found) (gethash slot closures)
                 (when (and found (not (equal old name)))
                   (lir-function-error state "stack closure storage has conflicting entries")))
               (setf (gethash slot closures) name)))
            (:stack-object-init
             (unless (and (eq part entry)
                          (equalp (rest (lir-stack-shape state (second statement))) (cddr statement))
                          (not (gethash (second statement) initialized)))
               (lir-function-error state "stack initialization needs a unique matching entry declaration"))
             (setf (gethash (second statement) initialized) t))
            (:stack-roots-enter
             (let ((region (second statement)) (object (third statement)))
               (unless (and (eq part entry)
                            (equal (lir-stack-shape state region) '(:stack-roots-entry))
                            (equalp (lir-stack-shape state object) (cons :stack-object (cdddr statement)))
                            (gethash object initialized)
                            (not (gethash region entries)))
                 (lir-function-error state "stack roots need unique matching entry storage"))
               (setf (gethash region entries) t)
               (push `(:region ,region :stack-roots ,outer ,object) declarations)
               (setf outer region)))))))
    (dolist (slot slots)
      (let* ((name (first slot)) (shape (second slot))
             (class (second shape)) (count (third shape)))
        (case (first shape)
          (:stack-object
           (unless (gethash name initialized)
             (lir-function-error state "stack storage has no initialization"))
           (push `(:stack-object ,name
                    ,(cond ((and (eql class +packet-class-cons+) (eql count 2)) :cons)
                           ((and (eql class +packet-class-function+) (gethash name closures))
                            `(:closure ,(gethash name closures)))
                           (t (lir-function-error state "unsupported stack shape ~S" shape))))
                 declarations))
          (:stack-roots-entry
           (unless (gethash name entries) (lir-function-error state "stack roots have no entry")))
          (t (lir-function-error state "dynamic slots need structured region declarations")))))
    (nreverse declarations)))

(defun lir-stack-statement (state statement)
  (let ((args (rest statement)))
    (ecase (first statement)
      (:stack-object-init nil)
      (:stack-roots-enter (lir-emit state `(:enter ,(first args) ())))
      (:stack-roots-leave (lir-emit state `(:leave ,(first args))))
      (:stack-cons
       (unless (and (consp (second args)) (eq (first (second args)) :slot))
         (lir-function-error state "stack cons needs named storage"))
       (lir-emit state `(:alloc ,(first args) :cons (:stack ,(second (second args)))
                         (,(lir-operand state (third args) :obj) ,(lir-operand state (fourth args) :obj)))))
      (:stack-closure
       (lir-emit state `(:alloc-closure ,(first args) ,(third args) (:stack ,(second args))))))))
