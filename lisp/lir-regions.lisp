(in-package #:kiln.kir)

;;;; Dynamic scopes can begin in different branches. Carry their active
;;;; stack along CFG edges rather than deriving parents from block order;
;;;; each join must agree before a structured region can be declared.

;;; Source handlers select an unwind target and forward nonmatches.
;;; Convert those isolated dispatch blocks to landing declarations so
;;; the backend owns target routing and the runtime payload representation.

(defun lir-prepare-landings (state parts)
  (let ((removed (make-hash-table :test 'equalp))
        (landings (make-hash-table :test 'equalp)))
    (dolist (part parts)
      (when (eq (first part) :block)
        (let* ((statement (third part)) (condition (second statement)))
          (when (and (eq (first statement) :br) (consp condition) (eq (first condition) :unwind-target-p))
            (unless (= (length (cddr part)) 1)
              (lir-function-error state "source handler needs an isolated dispatch block"))
            (let ((region (second condition)) (landing (third statement)))
              (when (or (gethash region (lir-function-region-landings state)) (gethash landing landings))
                (lir-function-error state "duplicate source landing"))
              (setf (gethash (second part) (lir-function-handler-regions state)) region
                    (gethash region (lir-function-region-landings state)) landing
                    (gethash landing landings) region
                    (gethash (second part) removed) t
                    (gethash (fourth statement) removed) t))))))
    (loop for part in parts
          unless (and (eq (first part) :block) (gethash (second part) removed))
            collect (let ((region (and (eq (first part) :block) (gethash (second part) landings))))
                      (if region `(:block ,(second part) (:lir-landing ,region) ,@(cddr part)) part)))))

;;; Tail branches can leave a join whose result variables have no producer.
;;; Keep blocks reachable by ordinary edges or a live region's landing;
;;; dead joins and their unused storage need no value or region declarations.
(defun lir-reachable-parts (state parts)
  (let ((blocks (make-hash-table :test 'equalp))
        (live (make-hash-table :test 'equalp))
        (slots (make-hash-table :test 'equalp))
        (used (make-hash-table :test 'equalp))
        (pending nil))
    (dolist (part parts)
      (when (eq (first part) :block) (setf (gethash (second part) blocks) part)))
    (dolist (slot (rest (assoc :slots parts))) (setf (gethash (first slot) slots) t))
    (labels ((edge (name)
               (unless (gethash name blocks) (lir-function-error state "unknown source block ~S" name))
               (unless (gethash name live) (setf (gethash name live) t) (push name pending)))
             (mark-slots (value)
               (if (consp value)
                   (progn (mark-slots (car value)) (mark-slots (cdr value)))
                   (when (gethash value slots) (setf (gethash value used) t)))))
      (let ((entry (find :block parts :key #'first)))
        (when entry (edge (second entry))))
      (loop while pending
            for block = (gethash (pop pending) blocks)
            do (dolist (statement (cddr block))
                 (when (plusp (hash-table-count slots)) (mark-slots statement))
                 (case (first statement)
                   (:dynamic-enter
                    (let ((landing (gethash (second statement) (lir-function-region-landings state))))
                      (when landing (edge landing))))
                   (:jump (edge (second statement)))
                   (:br (edge (third statement)) (edge (fourth statement)))
                   (:switch
                    (edge (third statement))
                    (dolist (arm (fourth statement)) (edge (second arm))))))))
    (loop for part in parts
          unless (and (eq (first part) :block) (not (gethash (second part) live)))
            collect (if (eq (first part) :slots)
                        `(:slots ,@(remove-if-not (lambda (slot) (gethash (first slot) used)) (rest part)))
                        part))))

(defun lir-prepare-regions (state parts)
  (let ((blocks (make-hash-table :test 'equalp))
        (inputs (make-hash-table :test 'equalp))
        (declarations (make-hash-table :test 'equalp))
        (pending nil) (result nil))
    (dolist (slot (rest (assoc :slots parts)))
      (when (eq (first (second slot)) :dynamic-entry)
        (setf (gethash (first slot) (lir-function-region-kinds state)) (second (second slot)))))
    (dolist (part parts)
      (when (eq (first part) :block)
        (setf (gethash (second part) blocks) part)
        (dolist (statement (cddr part))
          (when (eq (first statement) :dynamic-enter)
            (unless (member (third statement) '(:bind :progv :catch :unwind-protect :exit-point))
              (lir-function-error state "unsupported dynamic region ~S" (third statement)))
            (multiple-value-bind (old found) (gethash (second statement) (lir-function-region-tags state))
              (when (and found (not (equalp old (fourth statement))))
                (lir-function-error state "binding region has conflicting symbols")))
            (setf (gethash (second statement) (lir-function-region-tags state)) (fourth statement)
                  (gethash (second statement) (lir-function-region-kinds state)) (third statement))))))
    (when (zerop (hash-table-count (lir-function-region-kinds state)))
      (return-from lir-prepare-regions nil))
    (labels ((edge (name active)
               (unless (gethash name blocks) (lir-function-error state "unknown source block ~S" name))
               (multiple-value-bind (old found) (gethash name inputs)
                 (if found
                     (unless (equalp old active) (lir-function-error state "source regions disagree at a CFG join"))
                     (progn (setf (gethash name inputs) active) (push name pending)))))
             (private-root-p (name)
               (member name (lir-function-rest-regions state) :test #'equalp)))
      (let ((entry (find :block parts :key #'first)))
        (when entry (edge (second entry) nil)))
      (loop while pending
            for block = (gethash (pop pending) blocks)
            for active = (copy-list (gethash (second block) inputs))
            do (dolist (statement (cddr block))
                 (case (first statement)
                   (:dynamic-enter
                    (let* ((name (second statement))
                           (kind (third statement))
                           (landing (gethash name (lir-function-region-landings state)))
                           (declaration `(:region ,name ,kind ,(or (first active) :nil) ,@(and landing (list landing)))))
                      (when (and (not (member kind '(:bind :progv))) (null landing))
                        (lir-function-error state "region has no source landing"))
                      (when landing
                        (edge landing (if (eq kind :unwind-protect) (cons name active) active)))
                      (multiple-value-bind (old found) (gethash name declarations)
                        (when (and found (not (equalp old declaration)))
                          (lir-function-error state "binding region has conflicting parents"))
                        (unless found (push declaration result)))
                      (setf (gethash name declarations) declaration)
                      (push name active)))
                   (:dynamic-relink (push (second statement) active))
                   (:stack-roots-enter
                    (unless (private-root-p (second statement)) (push (second statement) active)))
                   ((:dynamic-leave :stack-roots-leave)
                    (unless (private-root-p (second statement))
                      (unless (equalp (first active) (second statement))
                        (lir-function-error state "source region leave is not innermost"))
                      (pop active)))
                   (:jump (edge (second statement) active))
                   (:br (edge (third statement) active) (edge (fourth statement) active))
                   (:switch
                    (edge (third statement) active)
                    (dolist (arm (fourth statement)) (edge (second arm) active)))))))
    ;; Dead source blocks still need region declarations for type checking.
    ;; Their lexical parents have no executable path to preserve.
    (dolist (slot (rest (assoc :slots parts)))
      (when (and (eq (first (second slot)) :dynamic-entry)
                 (not (gethash (first slot) declarations)))
        (let ((landing (gethash (first slot) (lir-function-region-landings state))))
          (push `(:region ,(first slot) ,(second (second slot)) :nil ,@(and landing (list landing))) result))))
    (nreverse result)))

(defun lir-region-statement (state statement)
  (let ((args (rest statement)))
    (ecase (first statement)
      ((:ensure-tls-index :special-unbind) nil)
      (:dynamic-enter
       (unless (eq (second args) :bind)
         (when (eq (second args) :progv) (lir-check-handler state (fifth args)))
         (lir-emit state `(:enter ,(first args)
                           ,(case (second args)
                              (:unwind-protect nil)
                              (:progv (list (lir-operand state (third args) :obj)
                                            (lir-operand state (fourth args) :obj)))
                              (t (list (lir-operand state (third args) :obj))))))))
      (:progv-restore
       (unless (eq (gethash (first args) (lir-function-region-kinds state)) :progv)
         (lir-function-error state "restoration needs a progv region")))
      (:dynamic-relink
       (unless (eq (gethash (first args) (lir-function-region-kinds state)) :exit-point)
         (lir-function-error state "only an exit point can relink"))
       (lir-emit state `(:enter ,(first args)
                         (,(lir-operand state (gethash (first args) (lir-function-region-tags state)) :obj)))))
      (:lir-landing
       (let ((view (unless (eq (gethash (first args) (lir-function-region-kinds state)) :unwind-protect)
                     (lir-new-temporary state :mv))))
         (setf (lir-function-landing-view state) view)
         (lir-emit state `(:landing ,(first args) ,@(and view (list view))))))
      (:landed-values
       (let ((source (lir-function-landing-view state))
             (target (gethash (second args) (lir-function-views state))))
         (unless source (lir-function-error state "values have no landing view"))
         (lir-emit state `(:mv-move ,target ,source))
         (lir-bind-result-pair state (first args) (second args) target)))
      (:unwind-values
       (lir-check-handler state (fifth args))
       (let ((target (lir-operand state (second args) :obj))
             (view (lir-view-for-values state (third args) (fourth args))))
         (lir-emit state `(,(ecase (first args) (:throw :throw) (:exit-to :exit-to)) ,target ,view))))
      (:continue-unwind
       (lir-check-handler state (second args))
       (lir-emit state `(:continue-unwind ,(first args))))
      (:special-bind-index
       (multiple-value-bind (symbol found) (gethash (first args) (lir-function-region-tags state))
         (unless found (lir-function-error state "binding has no region declaration"))
         (lir-emit state `(:enter ,(first args) (,(lir-operand state symbol :obj)
                                               ,(lir-operand state (third args) :obj))))))
      (:dynamic-leave (lir-emit state `(:leave ,(first args)))))))
