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

(defun mir-return-value-owners (function carriers)
  "Track bundles whose secondary values still occupy the ABI value area."
  (let* ((blocks (hir-vector (mir-function-blocks function)))
         (instructions (mir-function-instructions function))
         (polls (mir-loop-poll-blocks function))
         (inputs (make-array (length blocks) :initial-element :unseen))
         (outputs (make-array (length blocks) :initial-element 0))
         (masks (map 'simple-vector
                     (lambda (block)
                       (loop for parameter across (mir-block-parameters block)
                             sum (ash 1 parameter))) blocks))
         (queued (make-array (length blocks) :initial-element nil))
         (work (make-hir-buffer)))
    (setf (svref inputs 0) 0 (svref queued 0) t)
    (hir-push 0 work)
    (loop for cursor from 0 while (< cursor (hir-buffer-count work))
          for id = (mir-at work cursor) for block = (svref blocks id)
          for owners = (svref inputs id) for term = (mir-block-terminator block) do
      (setf (svref queued id) nil)
      (when (logbitp id polls) (setf owners 0))
      (loop for index across (hir-vector (mir-block-instructions block))
            for instruction = (mir-at instructions index)
            for kind = (mir-instruction-kind instruction)
            for result = (mir-instruction-result instruction) do
        (cond ((and result (svref carriers result)) (setf owners 0))
              ((member kind '(6 7 15))
               (setf owners (if result (ash 1 result) 0)))
              ((= kind 9) (setf owners (logior owners (ash 1 result))))
              ((= kind 39)
               (setf owners (if (and result
                                    (not (svref carriers (svref (mir-instruction-operands instruction) 0)))
                                    (logbitp (svref (mir-instruction-operands instruction) 0) owners))
                                (logior owners (ash 1 result)) 0)))
              ;; Checks, dynamic exits and unknown primops conservatively
              ;; destroy ownership. Heap carriers continue to handle them.
              ((logtest 124 (mir-instruction-effects instruction)) (setf owners 0))))
      (setf (svref outputs id) owners)
      (unless (member (mir-terminator-kind term) '(0 1 2)) (setf owners 0))
      (loop for edge across (mir-terminator-edges term)
            for target = (mir-edge-target edge)
            for parameters = (mir-block-parameters (svref blocks target))
            for mapped = (logandc2 owners (svref masks target))
            for bundles = 0 do
        (loop for parameter across parameters for argument across (mir-edge-arguments edge)
              when (eq (mir-value-representation (mir-at (mir-function-values function) parameter)) :bundle) do
          (incf bundles)
          ;; A pair move may publish a single-value view or restore a carrier.
          ;; Retain only the destination's proof, not unrelated old aliases.
          (setf mapped (if (and (= bundles 1) (not (svref carriers parameter))
                                (not (svref carriers argument)) (logbitp argument owners))
                           (ash 1 parameter) 0)))
        (when (> bundles 1) (setf mapped 0))
        (let* ((old (svref inputs target))
               (joined (if (eq old :unseen) mapped (logand old mapped))))
          (unless (eql old joined)
            (setf (svref inputs target) joined)
            (unless (svref queued target)
              (setf (svref queued target) t)
              (hir-push target work))))))
    outputs))

(defstruct mir-bundle-plan carriers demand)

(defun mir-propagate-bundle-demand (function carriers)
  (let ((blocks (hir-vector (mir-function-blocks function))))
    (labels ((mark (id)
               (unless (svref carriers id) (setf (svref carriers id) t))))
      (loop with changed = t while changed do
        (setf changed nil)
        (loop for instruction across (hir-vector (mir-function-instructions function))
              for result = (mir-instruction-result instruction)
              when (and (member (mir-instruction-kind instruction) '(11 39))
                        result (svref carriers result)
                        (mark (svref (mir-instruction-operands instruction) 0)))
                do (setf changed t))
        (loop for block across blocks do
          (loop for edge across (mir-terminator-edges (mir-block-terminator block))
                for parameters = (mir-block-parameters (svref blocks (mir-edge-target edge))) do
            (loop for parameter across parameters for argument across (mir-edge-arguments edge)
                  when (and (svref carriers parameter) (mark argument)) do (setf changed t))))))
    carriers))

(defun mir-compute-bundle-plan (function)
  "Separate secondary-value demand from the need to persist a heap carrier."
  (let* ((values (hir-vector (mir-function-values function)))
         (blocks (hir-vector (mir-function-blocks function)))
         (carriers (make-array (length values) :initial-element nil)))
    (labels ((mark (id)
               (when (eq (mir-value-representation (svref values id)) :bundle)
                 (unless (svref carriers id) (setf (svref carriers id) t)))))
      (loop for instruction across (hir-vector (mir-function-instructions function))
            for kind = (mir-instruction-kind instruction)
            unless (or (member kind '(10 11 37 39))
                       (and (= kind 14) (zerop (mir-instruction-data instruction))))
              do (map nil #'mark (mir-instruction-operands instruction)))
      (loop for block across blocks for term = (mir-block-terminator block)
            unless (= 2 (mir-terminator-kind term)) do (map nil #'mark (mir-terminator-operands term)))
      (mir-propagate-bundle-demand function carriers)
      (let ((demand (copy-seq carriers)))
        (loop for block across blocks for term = (mir-block-terminator block)
              when (= 2 (mir-terminator-kind term)) do
                (setf (svref demand (svref (mir-terminator-operands term) 0)) t))
        (mir-propagate-bundle-demand function demand)
        ;; Saving another bundle or restoring it at an edge can invalidate a
        ;; transient view. Repeat after adding carriers until no proof changes.
        (loop for owners = (mir-return-value-owners function carriers)
              for changed = nil do
          (loop for block across blocks for term = (mir-block-terminator block)
                when (= 2 (mir-terminator-kind term)) do
            (let ((value (svref (mir-terminator-operands term) 0)))
              (unless (logbitp value (svref owners (mir-block-id block)))
                (when (mark value) (setf changed t)))))
          (unless changed (return))
          (mir-propagate-bundle-demand function carriers))
        (make-mir-bundle-plan :carriers carriers :demand demand)))))

(defun mir-bundle-plan (function)
  (mir-analysis function :bundle-plan #'mir-compute-bundle-plan))

(defun mir-bundle-carriers (function)
  (mir-bundle-plan-carriers (mir-bundle-plan function)))
