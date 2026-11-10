(defun flow-pipeline (input)
  (let ((value nil) (mask 255))
    (setq value (logand input mask))
    (setq value (1+ value))
    (list (* value value) (1- value) (logior value 16) (integerp value))))
(print (flow-pipeline 250))
(print (flow-pipeline -1))

(defun flow-branch (flag)
  (let ((value 0))
    (if flag (setq value 5) (setq value 9))
    (+ value 1)))
(print (list (flow-branch t) (flow-branch nil)))

(defun flow-mixed (flag)
  (let ((value 1))
    (if flag (setq value "changed"))
    (integerp value)))
(print (list (flow-mixed t) (flow-mixed nil)))

;;; Later arguments can overwrite a variable whose earlier value is saved.
(let ((value nil))
  (print (list (+ (progn (setq value 2) value)
                  (progn (setq value "changed") 3))
               (integerp value))))

(let ((value nil))
  (print (list (aref (setq value (vector 10 20))
                     (progn (setq value "changed") 1))
               (simple-vector-p value))))

;;; Parallel initializers see the outer binding; local writes do not leak.
(let ((value 1))
  (let ((value 4) (other (progn (setq value "outer") 8)))
    (setq value (+ value other))
    (print value))
  (print (integerp value)))

;;; Early exits bypass writes that appear later in the tree.
(defun flow-block (early)
  (let ((value 1))
    (block done
      (when early (return-from done))
      (setq value "changed"))
    (integerp value)))
(print (list (flow-block t) (flow-block nil)))
(defun flow-catch (early)
  (let ((value 1))
    (catch 'done
      (when early (throw 'done nil))
      (setq value "changed"))
    (integerp value)))
(print (list (flow-catch t) (flow-catch nil)))

;;; A backedge must not carry the first iteration's binding facts.
(let ((value 1) (again t) (observations nil))
  (tagbody start
     (push (integerp value) observations)
     (setq value "changed")
     (when again (setq again nil) (go start)))
  (print observations))

;;; Cleanup can start before the protected form reaches its final write.
(defun flow-cleanup (early)
  (let ((value 1) (observed nil))
    (block done
      (unwind-protect
           (progn (when early (return-from done)) (setq value "changed"))
        (setq observed (integerp value))))
    observed))
(print (list (flow-cleanup t) (flow-cleanup nil)))

;;; A function retaining a captured writer can change the binding at a call.
(let ((value 1))
  (let ((writer (lambda () (setq value "changed"))))
    (funcall writer)
    (print (integerp value))))

(defun flow-unary-overflow (value)
  (when (typep value 'fixnum)
    (list (1+ value) (1- value))))
(print (flow-unary-overflow 4611686018427387903))
(print (flow-unary-overflow -4611686018427387904))
(print (handler-case (flow-pipeline "bad") (type-error () 'type-error)))
