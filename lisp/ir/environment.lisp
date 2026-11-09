(in-package #:kiln.compiler)

(defun ir-lookup (environment name namespace)
  (ecase namespace
    (:var
     (loop for env = environment then (ir-env-parent env)
           while (ir-env-p env)
           for entry = (assoc name (ir-env-vars env) :test #'eq)
           when entry return (values (cdr entry) t)
           finally (return (values nil nil))))
    (:fun
     (if (symbolp name)
         (loop for env = environment then (ir-env-parent env)
               while (ir-env-p env)
               for entry = (assoc name (ir-env-funcs env) :test #'eq)
               when entry return (values (cdr entry) t)
               finally (return (values nil nil)))
         (loop for env = environment then (ir-env-parent env)
               while (ir-env-p env)
               for entries = (ir-env-funcs env)
               for entry = (and entries (assoc name entries :test #'equal))
               when entry return (values (cdr entry) t)
               finally (return (values nil nil)))))
    (:block
     (loop for env = environment then (ir-env-parent env)
           while (ir-env-p env)
           for entry = (assoc name (ir-env-blocks env) :test #'eq)
           when entry return (values (cdr entry) t)
           finally (return (values nil nil))))
    (:tag
     (loop for env = environment then (ir-env-parent env)
           while (ir-env-p env)
           for entry = (assoc name (ir-env-tags env) :test #'eql)
           when entry return (values (cdr entry) t)
           finally (return (values nil nil))))))

(defun ir-base-environment (environment)
  (if (ir-env-p environment) (ir-env-base environment) environment))

(defmethod trucler:describe-variable (client (environment ir-env) name)
  (multiple-value-bind (binding found) (ir-lookup environment name :var)
    (if found
        (cond ((ir-var-p binding)
               (make-instance 'trucler:lexical-variable-description
                              :name name :identity binding :type (ir-var-type binding)
                              :ignore (and (logtest 8 (ir-var-flags binding)) 'ignorable)
                              :dynamic-extent (logtest 16 (ir-var-flags binding))))
              ((eq (car binding) :special)
               (make-instance 'trucler:local-special-variable-description :name name))
              (t (make-instance 'trucler:local-symbol-macro-description
                                :name name :expansion (second binding))))
        (trucler:describe-variable client (ir-base-environment environment) name))))

(defmethod trucler:describe-function (client (environment ir-env) name)
  (multiple-value-bind (binding found) (ir-lookup environment name :fun)
    (if found
        (if (ir-fun-p binding)
            (make-instance 'trucler:local-function-description :name name :identity binding)
            (make-instance 'trucler:local-macro-description :name name :expander (second binding)))
        (trucler:describe-function client (ir-base-environment environment) name))))

(defmethod trucler:describe-block (client (environment ir-env) name)
  (declare (ignore client))
  (let ((exit (ir-lookup environment name :block)))
    (and exit (make-instance 'trucler:block-description :name name :identity exit))))

(defmethod trucler:describe-tag (client (environment ir-env) name)
  (declare (ignore client))
  (let ((exit (ir-lookup environment name :tag)))
    (and exit (make-instance 'trucler:tag-description :name name :identity exit))))

(defmethod trucler:global-environment (client (environment ir-env))
  (trucler:global-environment client (ir-base-environment environment)))

(defmethod trucler:global-environment-p (client (environment ir-env))
  (and (null (ir-env-vars environment)) (null (ir-env-funcs environment))
       (null (ir-env-blocks environment)) (null (ir-env-tags environment))
       (null (ir-env-declarations environment))
       (trucler:global-environment-p client (ir-env-parent environment))))

(defmethod trucler:describe-declarations (client (environment ir-env))
  (trucler:describe-declarations client (ir-base-environment environment)))

(defmethod trucler:describe-optimize (client (environment ir-env))
  (let ((base (trucler:describe-optimize client (ir-base-environment environment)))
        (qualities '()))
    (loop for env = environment then (ir-env-parent env) while (ir-env-p env)
          do (dolist (spec (ir-env-declarations env))
               (when (eq (car spec) 'optimize)
                 (dolist (quality (cdr spec))
                   (let ((name (if (consp quality) (car quality) quality)))
                     (unless (assoc name qualities)
                       (push (cons name (if (consp quality) (second quality) 3)) qualities)))))))
    (if (null qualities)
        base
        (flet ((quality (name fallback) (let ((entry (assoc name qualities)))
                                         (if entry (cdr entry) fallback))))
          (make-instance 'trucler:optimize-description
            :speed (quality 'speed (trucler:speed base))
            :space (quality 'space (trucler:space base))
            :safety (quality 'safety (trucler:safety base))
            :debug (quality 'debug (trucler:debug base))
            :compilation-speed (quality 'compilation-speed (trucler:compilation-speed base)))))))

(defmethod trucler:macro-function (name (environment ir-env))
  (let ((description (trucler:describe-function *client* environment name)))
    (and (typep description 'trucler:macro-description) (trucler:expander description))))

(defmethod trucler:compiler-macro-function (name (environment ir-env))
  (let ((description (trucler:describe-function *client* environment name)))
    (and (typep description 'trucler:compiler-macro-mixin) (trucler:compiler-macro description))))

(defmethod trucler:symbol-macro-expansion (name (environment ir-env))
  (multiple-value-bind (expansion found) (symbol-macro-expansion *client* environment name)
    (if found expansion name)))

(defun ir-split-body (forms &optional documentation)
  (let ((declarations '()))
    (when (and documentation (rest forms) (stringp (ir-raw (first forms))))
      (setf forms (rest forms)))
    (loop while (and forms (consp (ir-raw (first forms)))
                     (eq (car (ir-raw (first forms))) 'declare))
          do (dolist (spec (rest (ir-parts (pop forms))))
               (let ((parts (mapcar #'ir-raw (ir-parts spec))))
                 (unless (and parts (or (symbolp (car parts)) (consp (car parts))
                                        (typep (car parts) 'class)))
                   (ir-error "Malformed declaration ~S" (ir-raw spec)))
                 (push parts declarations))))
    (values forms (nreverse declarations))))

(defun ir-special-names (declarations)
  (loop for spec in declarations when (eq (car spec) 'special) append (cdr spec)))

(defun ir-special-binding-p (name declarations environment)
  (or (member name (ir-special-names declarations))
      (typep (trucler:describe-variable *client* (trucler:global-environment *client* environment) name)
             'trucler:global-special-variable-description)))

(defun ir-declare (environment declarations)
  (when (null declarations)
    (return-from ir-declare environment))
  (let ((env (ir-env environment :declarations declarations
                     :vars (mapcar (lambda (name) (cons name '(:special)))
                                   (ir-special-names declarations)))))
    (dolist (spec declarations)
      (case (car spec)
        ((ignore ignorable dynamic-extent)
         (dolist (name (cdr spec))
           (let ((var (ir-lookup env name :var)))
             (when (ir-var-p var)
               (setf (ir-var-flags var)
                     (logior (ir-var-flags var) (if (eq (car spec) 'dynamic-extent) 16 8)))))))
        (type
         (dolist (name (cddr spec))
           (let ((var (ir-lookup env name :var)))
             (when (ir-var-p var) (setf (ir-var-type var) (second spec))))))
        (otherwise
         ;; A type name in declaration position is shorthand for TYPE.
         (unless (or (member (car spec) '(special optimize inline notinline ftype declaration))
                     (member (car spec)
                             (trucler:declarations (trucler:describe-declarations *client* env))))
           (cond
             #+kiln
             ((not (kiln.kernel::type-specifier-p (car spec)))
              (warn 'unknown-declaration-warning :specifier spec))
             (t
              (dolist (name (cdr spec))
                (let ((var (ir-lookup env name :var)))
                  (when (ir-var-p var) (setf (ir-var-type var) (car spec)))))))))))
    env))

(defun ir-evaluation-environment (environment)
  "Compile local macro expanders in the retained compile-time evaluator.
Only macros and symbol macros are visible there, never lexical values."
  (let ((base (ir-base-environment environment)) (variables '()) (functions '()))
    (loop for env = environment then (ir-env-parent env) while (ir-env-p env)
          do (dolist (entry (ir-env-vars env))
               (unless (assoc (car entry) variables) (push entry variables)))
             (dolist (entry (ir-env-funcs env))
               (unless (assoc (car entry) functions :test #'equal) (push entry functions))))
    (dolist (entry variables)
      (cond ((ir-var-p (cdr entry))
             (setf base (trucler:add-lexical-variable *client* base (car entry) (cdr entry))))
            ((eq (cadr entry) :special)
             (setf base (trucler:add-local-special-variable *client* base (car entry))))
            ((eq (cadr entry) :symbol-macro)
             (setf base (trucler:add-local-symbol-macro *client* base (car entry) (third entry))))))
    (dolist (entry functions)
      (if (ir-fun-p (cdr entry))
          (setf base (trucler:add-local-function *client* base (car entry) (cdr entry)))
          (setf base (trucler:add-local-macro *client* base (car entry) (third entry)))))
    (trucler:restrict-for-macrolet-expander *client* base)))

#+kiln
(defmethod kiln.eval:environment-client ((environment ir-env))
  (declare (ignore environment))
  *client*)
