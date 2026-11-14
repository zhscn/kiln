(in-package #:kiln.compiler)

(defconstant +mir-values-prefix-limit+ 16)
(defstruct mir-values-fact count (types #()))

(defun mir-values-ref-type (fact index)
  "The type of value INDEX, padding missing values with NIL."
  (cond ((eq fact :unseen) :unseen)
        ((and (mir-values-fact-count fact) (>= index (mir-values-fact-count fact))) 'null)
        ((< index (length (mir-values-fact-types fact))) (svref (mir-values-fact-types fact) index))
        (t t)))

(defun mir-unknown-values (&optional (primary t))
  (make-mir-values-fact :types (vector primary)))

(defun mir-join-values (old new expansions)
  (cond ((eq old :unseen) new) ((eq new :unseen) old)
        (t
         (let* ((count (and (eql (mir-values-fact-count old) (mir-values-fact-count new))
                            (mir-values-fact-count old)))
                (size (max (length (mir-values-fact-types old)) (length (mir-values-fact-types new))))
                (types (make-array size)))
           (dotimes (index size)
             (let* ((before (mir-values-ref-type old index))
                    (joined (mir-type-join before (mir-values-ref-type new index))))
               (when (and (hir-range-p before) (hir-range-p joined) (not (equal before joined)))
                 (incf (svref expansions index))
                 (when (>= (svref expansions index) 2) (setf joined 'integer)))
               (setf (svref types index) joined)))
           (make-mir-values-fact :count count :types types)))))

(defun mir-fixed-values (types)
  (if (find :unseen types) :unseen
      (make-mir-values-fact :count (length types)
                            :types (subseq types 0 (min (length types) +mir-values-prefix-limit+)))))

(defun mir-check-values (fact primary)
  (cond ((or (eq fact :unseen) (eq primary :unseen)) :unseen)
        ((eql (mir-values-fact-count fact) 0) fact)
        (t (let* ((before (mir-values-fact-types fact))
                  (types (make-array (max 1 (length before)))))
             (replace types before) (setf (svref types 0) primary)
             (make-mir-values-fact :count (mir-values-fact-count fact) :types types)))))

(defun mir-single-value-call-p (name)
  ;; Multiple-valued functions require their own contracts, even when a
  ;; primary-result type is known. Unknown library calls retain unknown count.
  (or (hir-predicate-type name)
      (member name '(car cdr first rest rplaca rplacd identity + - * / abs 1+ 1- logand logior logxor
                     < > <= >= = /= eq eql equal equalp zerop plusp minusp
                     cons list vector make-array length char schar aref elt char-code))))
