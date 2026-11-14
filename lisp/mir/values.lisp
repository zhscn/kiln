(in-package #:kiln.compiler)

(defun mir-parse-values-declaration (type)
  (let* ((expanded (hir-declaration-expanded type)) (original (hir-declaration-original type))
         (original-parts (and (consp original) (eq (car original) 'values) (cdr original)))
         (required nil) (optional nil) (rest t) (state :required))
    (unless (and (consp expanded) (eq (car expanded) 'values) (hir-proper-list-p expanded))
      (mir-fail "Invalid MIR VALUES declaration ~S" original))
    (loop for part in (cdr expanded) for index from 0 do
      (cond ((eq part '&optional)
             (unless (eq state :required) (mir-fail "Misplaced &OPTIONAL in VALUES"))
             (setf state :optional))
            ((eq part '&rest)
             (unless (member state '(:required :optional)) (mir-fail "Misplaced &REST in VALUES"))
             (setf state :rest))
            ((eq part '&allow-other-keys)
             (unless (member state '(:required :optional :done)) (mir-fail "Misplaced &ALLOW-OTHER-KEYS in VALUES"))
             (setf state :end))
            (t
             (when (or (member part '(* values)) (member part lambda-list-keywords)
                       (and (consp part) (eq (car part) 'values)) (member state '(:done :end)))
               (mir-fail "Invalid VALUES component ~S" part))
             (let* ((source (if original-parts (nth index original-parts) part))
                    (declaration (if (equal source part) part (make-hir-type-declaration source part))))
               (ecase state
                 (:required (push declaration required))
                 (:optional (push declaration optional))
                 (:rest (setf rest declaration state :done)))))))
    (when (eq state :rest) (mir-fail "Missing &REST type in VALUES"))
    (make-mir-values-declaration :required (coerce (nreverse required) 'simple-vector)
                                 :optional (coerce (nreverse optional) 'simple-vector) :rest rest)))

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

(defun mir-asserted-values (fact declaration)
  "Refine padded value types after checks while retaining the producer's count."
  (when (eq fact :unseen) (return-from mir-asserted-values :unseen))
  (let* ((required (mir-values-declaration-required declaration))
         (optional (mir-values-declaration-optional declaration))
         (prefix (+ (length required) (length optional)))
         (count (mir-values-fact-count fact))
         (size (min +mir-values-prefix-limit+
                    (if (eq (hir-declaration-expanded (mir-values-declaration-rest declaration)) t)
                        (max (length (mir-values-fact-types fact)) prefix)
                        (or count +mir-values-prefix-limit+))))
         (types (make-array size)))
    (dotimes (index size)
      (let* ((type (cond ((< index (length required)) (svref required index))
                         ((< index prefix) (svref optional (- index (length required))))
                         (t (mir-values-declaration-rest declaration))))
             (wanted (hir-declaration-type type)))
        (when (and (>= index (length required)) (or (null count) (>= index count)))
          (setf wanted (hir-type-join wanted 'null)))
        (setf (svref types index) (hir-type-intersection (mir-values-ref-type fact index) wanted))))
    (make-mir-values-fact :count count :types types)))

(defun mir-standard-call-p (name)
  (let ((symbol (if (and (consp name) (eq (car name) 'setf)
                         (consp (cdr name)) (null (cddr name)))
                    (second name) name)))
    (and (symbolp symbol) (eq (symbol-package symbol) (find-package :cl)))))

(defun mir-single-value-call-p (name)
  ;; Multiple-valued functions require their own contracts, even when a
  ;; primary-result type is known. Unknown library calls retain unknown count.
  (or (member name '((setf aref) (setf svref) (setf elt) (setf char) (setf schar)) :test #'equal)
      (hir-predicate-type name)
      (member name '(car cdr first rest rplaca rplacd identity + - * / abs 1+ 1- logand logior logxor
                     < > <= >= = /= eq eql equal equalp zerop plusp minusp
                     cons list vector make-array length char schar aref elt char-code))))
