(in-package #:kiln.compiler)

(defun hir-lookup (environment name namespace)
  (ecase namespace
    (:var
     (loop for env = environment then (hir-env-parent env)
           while (hir-env-p env)
           for entry = (assoc name (hir-env-vars env) :test #'eq)
           when entry return (values (cdr entry) t)
           finally (return (values nil nil))))
    (:fun
     (if (symbolp name)
         (loop for env = environment then (hir-env-parent env)
               while (hir-env-p env)
               for entry = (assoc name (hir-env-funcs env) :test #'eq)
               when entry return (values (cdr entry) t)
               finally (return (values nil nil)))
         (loop for env = environment then (hir-env-parent env)
               while (hir-env-p env)
               for entries = (hir-env-funcs env)
               for entry = (and entries (assoc name entries :test #'equal))
               when entry return (values (cdr entry) t)
               finally (return (values nil nil)))))
    (:block
     (loop for env = environment then (hir-env-parent env)
           while (hir-env-p env)
           for entry = (assoc name (hir-env-blocks env) :test #'eq)
           when entry return (values (cdr entry) t)
           finally (return (values nil nil))))
    (:tag
     (loop for env = environment then (hir-env-parent env)
           while (hir-env-p env)
           for entry = (assoc name (hir-env-tags env) :test #'eql)
           when entry return (values (cdr entry) t)
           finally (return (values nil nil))))))

(defun hir-base-environment (environment)
  (if (hir-env-p environment) (hir-env-base environment) environment))

(defun hir-declaration-original (type)
  (cond ((hir-type-declaration-p type) (hir-type-declaration-original type))
        ((and (consp type) (member (car type) '(and or not)))
         (cons (car type) (mapcar #'hir-declaration-original (cdr type))))
        (t type)))

(defun hir-declaration-expanded (type)
  (cond ((hir-type-declaration-p type) (hir-type-declaration-expanded type))
        ((and (consp type) (member (car type) '(and or not)))
         (cons (car type) (mapcar #'hir-declaration-expanded (cdr type))))
        (t type)))

(defun hir-expand-type (type environment)
  "Expand type aliases in this lexical environment, retaining bounded work.
Each named alias queried is a dependency, including currently undefined names."
  (unless (and (boundp '*client*) *client* (hir-base-environment environment))
    (return-from hir-expand-type type))
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
                   (cond (expander
                          (walk (funcall expander specifier environment) (cons specifier path)))
                         ((and (consp specifier) (member name '(and or not cons))
                               (hir-proper-list-p specifier))
                          (cons name (mapcar (lambda (part) (walk part (cons specifier path)))
                                             (cdr specifier))))
                         ((and (consp specifier) (member name '(array simple-array vector))
                               (consp (cdr specifier)) (hir-proper-list-p specifier))
                          (list* name (walk (second specifier) (cons specifier path))
                                 (mapcar (lambda (part)
                                           (if (and (consp part) (hir-proper-list-p part)) (copy-list part) part))
                                         (cddr specifier))))
                         ((and (consp specifier) (hir-proper-list-p specifier))
                          ;; Bounds and dimensions belong to the proof snapshot;
                          ;; EQL and MEMBER payloads retain their object identities.
                          (if (member name '(integer rational real float single-float double-float short-float long-float))
                              (cons name (mapcar (lambda (bound)
                                                   (if (and (consp bound) (hir-proper-list-p bound))
                                                       (copy-list bound) bound)) (cdr specifier)))
                              (copy-list specifier)))
                         (t specifier)))))
        (walk type nil)))))

(defun hir-expand-declaration (type environment)
  (if (hir-type-declaration-p type) type
      (let ((expanded (hir-expand-type type environment)))
        (if (equal type expanded) type (make-hir-type-declaration type expanded)))))

(defun hir-declared-variable-type (environment variable)
  "Intersect declarations on this binding identity in the current scope."
  (let* ((global (if (boundp '*client*)
                     (client-global-variable-type *client* (hir-var-name variable)) t))
         (types (unless (eq global t) (list (hir-expand-declaration global environment)))))
    (loop for env = environment then (hir-env-parent env) while (hir-env-p env)
          do (dolist (entry (hir-env-types env))
               (when (and (eq (car entry) variable)
                          (not (member (cdr entry) types :test #'equal)))
                 (push (cdr entry) types))))
    (cond ((null types) t) ((null (cdr types)) (car types))
          (t (cons 'and (nreverse types))))))

(defmethod trucler:describe-variable (client (environment hir-env) name)
  (multiple-value-bind (binding found) (hir-lookup environment name :var)
    (if found
        (cond ((hir-var-p binding)
               (make-instance 'trucler:lexical-variable-description
                              :name name :identity binding :type (hir-declaration-original (hir-declared-variable-type environment binding))
                              :ignore (and (logtest 8 (hir-var-flags binding)) 'ignorable)
                              :dynamic-extent (logtest 16 (hir-var-flags binding))))
              ((eq (car binding) :special)
               (make-instance 'trucler:local-special-variable-description :name name))
              (t (make-instance 'trucler:local-symbol-macro-description
                                :name name :expansion (second binding))))
        (trucler:describe-variable client (hir-base-environment environment) name))))

(defmethod trucler:describe-function (client (environment hir-env) name)
  (multiple-value-bind (binding found) (hir-lookup environment name :fun)
    (if found
        (if (hir-fun-p binding)
            (make-instance 'trucler:local-function-description :name name :identity binding)
            (make-instance 'trucler:local-macro-description :name name :expander (second binding)))
        (trucler:describe-function client (hir-base-environment environment) name))))

(defmethod trucler:describe-block (client (environment hir-env) name)
  (declare (ignore client))
  (let ((exit (hir-lookup environment name :block)))
    (and exit (make-instance 'trucler:block-description :name name :identity exit))))

(defmethod trucler:describe-tag (client (environment hir-env) name)
  (declare (ignore client))
  (let ((exit (hir-lookup environment name :tag)))
    (and exit (make-instance 'trucler:tag-description :name name :identity exit))))

(defmethod trucler:global-environment (client (environment hir-env))
  (trucler:global-environment client (hir-base-environment environment)))

(defmethod trucler:global-environment-p (client (environment hir-env))
  (and (null (hir-env-vars environment)) (null (hir-env-funcs environment))
       (null (hir-env-blocks environment)) (null (hir-env-tags environment))
       (null (hir-env-declarations environment))
       (trucler:global-environment-p client (hir-env-parent environment))))

(defmethod trucler:describe-declarations (client (environment hir-env))
  (trucler:describe-declarations client (hir-base-environment environment)))

(defmethod trucler:describe-optimize (client (environment hir-env))
  (let ((base (trucler:describe-optimize client (hir-base-environment environment)))
        (qualities '()))
    (loop for env = environment then (hir-env-parent env) while (hir-env-p env)
          do (dolist (spec (hir-env-declarations env))
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

(defun hir-policy-from-environment (environment)
  (let ((policy (trucler:describe-optimize *client* environment)))
    (flet ((quality (value shift)
             (unless (and (integerp value) (<= 0 value 3))
               (hir-error "Invalid optimization quality ~S" value))
             (ash value shift)))
      (logior (quality (trucler:speed policy) 0) (quality (trucler:safety policy) 2)
              (quality (trucler:debug policy) 4) (quality (trucler:space policy) 6)
              (quality (trucler:compilation-speed policy) 8)))))

(defun hir-body-policy (environment declarations)
  (if (assoc 'optimize declarations)
      (hir-policy-from-environment (hir-env environment :declarations declarations))
      *hir-policy*))

(defmethod trucler:macro-function (name (environment hir-env))
  (let ((description (trucler:describe-function *client* environment name)))
    (and (typep description 'trucler:macro-description) (trucler:expander description))))

(defmethod trucler:compiler-macro-function (name (environment hir-env))
  (let ((description (trucler:describe-function *client* environment name)))
    (and (typep description 'trucler:compiler-macro-mixin) (trucler:compiler-macro description))))

(defmethod trucler:symbol-macro-expansion (name (environment hir-env))
  (multiple-value-bind (expansion found) (symbol-macro-expansion *client* environment name)
    (if found expansion name)))

(defun hir-split-body (forms &optional documentation)
  (let ((declarations '()) (documented nil))
    (loop
      (cond ((and documentation (not documented) (rest forms)
                  (stringp (hir-raw (first forms))))
             (setf forms (rest forms) documented t))
            ((and forms (consp (hir-raw (first forms)))
                  (eq (car (hir-raw (first forms))) 'declare))
             (dolist (spec (rest (hir-parts (pop forms))))
               (let ((parts (mapcar #'hir-raw (hir-parts spec))))
                 (unless (and parts (or (symbolp (car parts)) (consp (car parts))
                                        (typep (car parts) 'class)))
                   (hir-error "Malformed declaration ~S" (hir-raw spec)))
                 (push parts declarations))))
            (t (return))))
    (values forms (nreverse declarations))))

(defun hir-special-names (declarations)
  (loop for spec in declarations when (eq (car spec) 'special) append (cdr spec)))

(defun hir-special-binding-p (name declarations environment)
  (or (member name (hir-special-names declarations))
      (typep (trucler:describe-variable *client* (trucler:global-environment *client* environment) name)
             'trucler:global-special-variable-description)))

(defun hir-declare (environment declarations)
  (when (null declarations)
    (return-from hir-declare environment))
  (let ((env (hir-env environment :declarations declarations
                     :vars (mapcar (lambda (name) (cons name '(:special)))
                                   (hir-special-names declarations)))))
    (dolist (spec declarations)
      (case (car spec)
        ((ignore ignorable dynamic-extent)
         (dolist (name (cdr spec))
           (let ((var (hir-lookup env name :var)))
             (when (hir-var-p var)
               (setf (hir-var-flags var)
                     (logior (hir-var-flags var) (if (eq (car spec) 'dynamic-extent) 16 8)))))))
        (type
         (dolist (name (cddr spec))
           (let ((var (hir-lookup env name :var)))
             (when (hir-var-p var)
               (push (cons var (hir-expand-declaration (second spec) env)) (hir-env-types env))))))
        (otherwise
         ;; A type name in declaration position is shorthand for TYPE.
         (unless (or (member (car spec) '(special optimize inline notinline ftype declaration))
                     (member (car spec)
                             (trucler:declarations (trucler:describe-declarations *client* env))))
           (cond
             ((not (client-type-specifier-p (and (boundp '*client*) *client*) env (car spec)))
              (warn 'unknown-declaration-warning :specifier spec))
             (t
              (dolist (name (cdr spec))
                (let ((var (hir-lookup env name :var)))
                  (when (hir-var-p var)
                    (push (cons var (hir-expand-declaration (car spec) env)) (hir-env-types env)))))))))))
    env))

(defun hir-declare-binding (environment name declarations)
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
    (if selected (hir-declare environment (nreverse selected)) environment)))

(defun hir-evaluation-environment (environment)
  "Compile local macro expanders in the retained compile-time evaluator.
Only macros and symbol macros are visible there, never lexical values."
  (let ((base (hir-base-environment environment)) (variables '()) (functions '()))
    (loop for env = environment then (hir-env-parent env) while (hir-env-p env)
          do (dolist (entry (hir-env-vars env))
               (unless (assoc (car entry) variables) (push entry variables)))
             (dolist (entry (hir-env-funcs env))
               (unless (assoc (car entry) functions :test #'equal) (push entry functions))))
    (dolist (entry variables)
      (cond ((hir-var-p (cdr entry))
             (setf base (trucler:add-lexical-variable *client* base (car entry) (cdr entry))))
            ((eq (cadr entry) :special)
             (setf base (trucler:add-local-special-variable *client* base (car entry))))
            ((eq (cadr entry) :symbol-macro)
             (setf base (trucler:add-local-symbol-macro *client* base (car entry) (third entry))))))
    (dolist (entry functions)
      (if (hir-fun-p (cdr entry))
          (setf base (trucler:add-local-function *client* base (car entry) (cdr entry)))
          (setf base (trucler:add-local-macro *client* base (car entry) (third entry)))))
    (trucler:restrict-for-macrolet-expander *client* base)))

#+kiln
(defmethod kiln.eval:environment-client ((environment hir-env))
  (declare (ignore environment))
  *client*)
