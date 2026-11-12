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

(defun ir-declaration-original (type)
  (cond ((ir-type-declaration-p type) (ir-type-declaration-original type))
        ((and (consp type) (member (car type) '(and or not)))
         (cons (car type) (mapcar #'ir-declaration-original (cdr type))))
        (t type)))

(defun ir-declaration-expanded (type)
  (cond ((ir-type-declaration-p type) (ir-type-declaration-expanded type))
        ((and (consp type) (member (car type) '(and or not)))
         (cons (car type) (mapcar #'ir-declaration-expanded (cdr type))))
        (t type)))

(defun ir-expand-type (type environment)
  "Expand type aliases in this lexical environment, retaining bounded work.
Each named alias queried is a dependency, including currently undefined names."
  (unless (and (boundp '*client*) *client* (ir-base-environment environment))
    (return-from ir-expand-type type))
  (let ((budget 128))
    (block expansion
      (labels ((walk (specifier path)
                 (when (or (minusp (decf budget)) (member specifier path :test #'equal))
                   (return-from expansion type))
                 (let* ((name (if (consp specifier) (car specifier) specifier))
                        (named (and (symbolp name) (not (keywordp name))
                                    (not (eq (symbol-package name) (find-package '#:common-lisp)))))
                        (expander (and named
                                       (client-type-expander *client* environment name))))
                   (when named (note-dependency :type name))
                   (cond (expander
                          (walk (funcall expander specifier environment) (cons specifier path)))
                         ((and (consp specifier) (member name '(and or not cons))
                               (ir-proper-list-p specifier))
                          (cons name (mapcar (lambda (part) (walk part (cons specifier path)))
                                             (cdr specifier))))
                         ((and (consp specifier) (member name '(array simple-array vector))
                               (consp (cdr specifier)) (ir-proper-list-p specifier))
                          (list* name (walk (second specifier) (cons specifier path))
                                 (mapcar (lambda (part)
                                           (if (and (consp part) (ir-proper-list-p part)) (copy-list part) part))
                                         (cddr specifier))))
                         ((and (consp specifier) (ir-proper-list-p specifier))
                          ;; Bounds and dimensions belong to the proof snapshot;
                          ;; EQL and MEMBER payloads retain their object identities.
                          (if (member name '(integer rational real float single-float double-float short-float long-float))
                              (cons name (mapcar (lambda (bound)
                                                   (if (and (consp bound) (ir-proper-list-p bound))
                                                       (copy-list bound) bound)) (cdr specifier)))
                              (copy-list specifier)))
                         (t specifier)))))
        (walk type nil)))))

(defun ir-expand-declaration (type environment)
  (if (ir-type-declaration-p type) type
      (let ((expanded (ir-expand-type type environment)))
        (if (equal type expanded) type (make-ir-type-declaration type expanded)))))

(defun ir-declared-variable-type (environment variable)
  "Intersect declarations on this binding identity in the current scope."
  (let ((types nil))
    (loop for env = environment then (ir-env-parent env) while (ir-env-p env)
          do (dolist (entry (ir-env-types env))
               (when (and (eq (car entry) variable)
                          (not (member (cdr entry) types :test #'equal)))
                 (push (cdr entry) types))))
    (cond ((null types) t) ((null (cdr types)) (car types))
          (t (cons 'and (nreverse types))))))

(defmethod trucler:describe-variable (client (environment ir-env) name)
  (multiple-value-bind (binding found) (ir-lookup environment name :var)
    (if found
        (cond ((ir-var-p binding)
               (make-instance 'trucler:lexical-variable-description
                              :name name :identity binding :type (ir-declaration-original (ir-declared-variable-type environment binding))
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

(defun ir-policy-from-environment (environment)
  (let ((policy (trucler:describe-optimize *client* environment)))
    (flet ((quality (value shift)
             (unless (and (integerp value) (<= 0 value 3))
               (ir-error "Invalid optimization quality ~S" value))
             (ash value shift)))
      (logior (quality (trucler:speed policy) 0) (quality (trucler:safety policy) 2)
              (quality (trucler:debug policy) 4) (quality (trucler:space policy) 6)
              (quality (trucler:compilation-speed policy) 8)))))

(defun ir-body-policy (environment declarations)
  (if (assoc 'optimize declarations)
      (ir-policy-from-environment (ir-env environment :declarations declarations))
      *ir-policy*))

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
             (when (ir-var-p var)
               (push (cons var (ir-expand-declaration (second spec) env)) (ir-env-types env))))))
        (otherwise
         ;; A type name in declaration position is shorthand for TYPE.
         (unless (or (member (car spec) '(special optimize inline notinline ftype declaration))
                     (member (car spec)
                             (trucler:declarations (trucler:describe-declarations *client* env))))
           (cond
             #+kiln
             ((not (or (and (symbolp (car spec)) (boundp '*client*) *client* (ir-base-environment env)
                            (client-type-expander *client* env (car spec)))
                       (kiln.kernel::type-specifier-p (car spec))))
              (warn 'unknown-declaration-warning :specifier spec))
             (t
              (dolist (name (cdr spec))
                (let ((var (ir-lookup env name :var)))
                  (when (ir-var-p var)
                    (push (cons var (ir-expand-declaration (car spec) env)) (ir-env-types env)))))))))))
    env))

(defun ir-declare-binding (environment name declarations)
  "A binding declaration also applies to later sequential initializers.
Names not bound yet must not attach to an outer binding of the same name."
  (let ((selected nil))
    (dolist (spec declarations)
      (cond ((and (eq (car spec) 'type) (member name (cddr spec)))
             (push (list 'type (second spec) name) selected))
            ((and (not (member (car spec) '(type special optimize inline notinline ftype
                                           declaration ignore ignorable dynamic-extent)))
                  (member name (cdr spec)))
             (push (list (car spec) name) selected))))
    (if selected (ir-declare environment (nreverse selected)) environment)))

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
