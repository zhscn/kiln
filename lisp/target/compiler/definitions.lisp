;;;; Source definitions shared by navigation and incremental compilation.
(in-package #:kiln.compiler)

(defvar *source-definitions* (make-hash-table :test 'equal))
(defvar *importing-source-definitions* nil)
(defvar *source-definitions-initialized* nil)
(defvar *source-definition-record-observer* nil)
(defvar kiln.sys:*warn-on-cross-file-redefinition* t)

(define-condition source-redefinition-warning (style-warning simple-condition) ())

(defun record-source-definition (record)
  (when (getf record :file)
    (setf (getf record :file) (namestring (merge-pathnames (getf record :file)))))
  (let* ((dspec (getf record :dspec))
         (old (gethash dspec *source-definitions*)))
    (when (and kiln.sys:*warn-on-cross-file-redefinition* old
               (getf old :file) (getf record :file)
               (not (equal (getf old :file) (getf record :file))))
      (warn 'source-redefinition-warning :format-control "~S from ~A redefined in ~A"
            :format-arguments (list dspec (getf old :file) (getf record :file))))
    (let ((aliases (case (first dspec)
                     ((defun defgeneric defmacro) '(defun defgeneric defmacro))
                     ((defsetf define-setf-expander) '(defsetf define-setf-expander))
                     ((defclass defstruct define-condition) '(defclass defstruct define-condition))
                     ((defvar defconstant) '(defvar defconstant)))))
      (dolist (kind aliases)
        (unless (eq kind (first dspec))
          (let* ((key (list kind (second dspec)))
                 (previous (gethash key *source-definitions*)))
            (when previous
              (remhash key *source-definitions*)
              (when (fboundp 'remove-definition-unit)
                (remove-definition-unit (getf previous :name))))))))
    (setf (gethash dspec *source-definitions*) record)
    (when *source-definition-record-observer*
      (funcall *source-definition-record-observer* record))))

(defun import-source-definitions ()
  (unless *importing-source-definitions*
    (let ((*importing-source-definitions* t)
          (kiln.sys:*warn-on-cross-file-redefinition*
            (and *source-definitions-initialized* kiln.sys:*warn-on-cross-file-redefinition*))
          (batches (reverse kiln.kernel::*source-definition-batches*)))
      (setf kiln.kernel::*source-definition-batches* nil
            *source-definitions-initialized* t)
      (dolist (batch batches)
        (dolist (record batch)
          (record-source-definition record)
          (when (and (fboundp 'register-definition-unit) (getf record :keys))
            (let ((*package* (or (find-package (getf record :package)) *package*))
                  (*source-file* (getf record :file))
                  (*eval-source-cst* nil))
              (register-definition-unit (getf record :name) (getf record :form)
                                        (getf record :keys) (getf record :outputs) nil)
              (let ((unit (gethash (getf record :name) *definition-units*)))
                (when unit (setf (definition-unit-source-range unit) (getf record :source)))))))))))

(defun kiln.sys:definition-form (record)
  "Restore the source form of a definition record on demand."
  (decode-source-form (getf record :form)))

(defun canonical-dspec (name)
  (if (or (symbolp name) (and (consp name) (eq (car name) 'setf)))
      (list 'defun name) name))

(defun kiln.sys:find-definitions (name)
  "Return source records for a canonical dspec, or all definitions named NAME."
  (import-source-definitions)
  (let ((exact (gethash (canonical-dspec name) *source-definitions*)))
    (if exact (list (copy-list exact))
        (loop for record being the hash-values of *source-definitions*
              when (equal name (second (getf record :dspec)))
                collect (copy-list record)))))

(defun kiln.sys:definitions-in-file (file)
  "Return source records in FILE, ordered by their starting offsets."
  (import-source-definitions)
  (sort (loop for record being the hash-values of *source-definitions*
              when (equal (namestring (merge-pathnames file))
                          (and (getf record :file)
                               (namestring (merge-pathnames (getf record :file)))))
                collect (copy-list record))
        #'< :key (lambda (record) (or (car (getf record :source)) 0))))

(defun kiln.sys:who-calls (name)
  "Return definitions containing statically named calls to NAME."
  (import-source-definitions)
  (loop for record being the hash-values of *source-definitions*
        when (member name (getf record :calls) :test #'equal)
          collect (getf record :dspec)))

(setf *source-definition-lookup*
      (lambda (dspec)
        (import-source-definitions)
        (gethash dspec *source-definitions*)))

(defun forget-source-binding (dspec)
  (let ((kind (first dspec)) (name (second dspec)))
    (case kind
      ((defun defgeneric defmacro define-modify-macro) (fmakunbound name))
      (define-compiler-macro (setf (compiler-macro-function name) nil))
      (defvar (makunbound name))
      (defconstant
       (remprop name 'kiln.kernel::%constant)
       (makunbound name)
       (kiln.kernel::change-assumption :constant name))
      ((defsetf define-setf-expander)
       (remprop name 'kiln.kernel::setf-expander)
       (kiln.kernel::change-assumption :setf name))
      (deftype
       (remprop name 'kiln.kernel::type-expander)
       (kiln.kernel::change-assumption :type name))
      ((defclass define-condition defstruct)
       (when (find-class name nil) (setf (find-class name) nil))
       (when (eq kind 'defstruct)
         (remhash (cons :typed name) *structures*)
         (remhash (cons :object name) *structures*))))))

(defun kiln.sys:reload-source-file (file &key (external-format :default))
  "Evaluate new or changed definitions, retaining unchanged definitions' identities.
Nondefinition top-level forms run in source order as with LOAD."
  (let* ((path (merge-pathnames file))
         (filename (namestring path))
         (old (mapcar (lambda (record)
                        (gethash (getf record :dspec) *source-definitions*))
                      (kiln.sys:definitions-in-file path)))
         (seen nil) (changed nil) (unchanged nil)
         (*package* *package*) (*readtable* *readtable*)
         (*load-pathname* path) (*load-truename* (truename path))
         (*source-definition-record-observer*
           (lambda (record)
             (when (and (not *updating-definitions*) (equal filename (getf record :file)))
               (pushnew (getf record :dspec) seen :test #'equal)))))
    (with-open-file (stream path :external-format external-format)
      (loop with eof = (list nil)
            for cst = (let ((eclector.base:*client* kiln.kernel::*load-source-reader-client*))
                        (eclector.concrete-syntax-tree:read stream nil eof))
            until (eq cst eof)
            for form = (cst:raw cst)
            for dspec = (definition-specifier form)
            for previous = (and dspec (gethash dspec *source-definitions*))
            do (let ((*source-file* filename) (*eval-source-cst* cst))
                 (when dspec (push dspec seen))
                 (if (and previous (not (getf previous :stale)) (equal filename (getf previous :file))
                          (source-form-equal-p form (getf previous :form)))
                     (progn
                       (setf (getf previous :source) (cst-source-range cst))
                       (let ((unit (gethash (getf previous :name) *definition-units*)))
                         (when unit (setf (definition-unit-source-cst unit) cst)))
                       (push dspec unchanged))
                     (progn (eval form) (when dspec (push dspec changed)))))))
    (let ((kept (copy-list unchanged)))
      (loop for count = (length kept)
            do (dolist (record old)
                 (when (member (getf record :parent) kept :test #'equal)
                   (pushnew (getf record :dspec) kept :test #'equal)))
            until (= count (length kept)))
      (setf seen (union kept seen :test #'equal)))
    (let ((*evaluating* t))
    (dolist (record old)
      (let ((dspec (getf record :dspec)))
        (when (and (not (member dspec seen :test #'equal))
                   (eq record (gethash dspec *source-definitions*)))
          (forget-source-binding dspec)
          (remhash dspec *source-definitions*)
          (remove-definition-unit (getf record :name))))))
    (when *pending-redefinitions* (update-dependents))
    (values (nreverse changed) (nreverse unchanged))))
