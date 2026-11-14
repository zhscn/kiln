(in-package #:kiln.compiler)

(defvar *compilation-request* nil)
(defvar *dependencies* nil)
(defvar *source-definition-calls* nil)
(defvar *source-definition-parent* nil)
(defvar *source-record-observer* nil)
(defvar *source-origin* nil)
(defvar *unit-outputs* nil)
(defvar *unit-fingerprint* nil)

(defstruct compilation-request
  purpose session parent (children nil) source-origin (pipeline :hir)
  dependencies calls outputs fingerprint observer definition-parent
  (expansion-origins (make-hash-table :test 'eq))
  (records (list :records)) (diagnostics nil) (results nil) (state :running))

(defun request-collector (mode inherited marker)
  (ecase mode (:inherit inherited) (:fresh (list marker)) (:none nil)))

(defun call-with-compilation-request (purpose session function
                                     &key (dependencies :none) (calls :none) (outputs :none) (fingerprint :none)
                                          (observers :isolate) (pipeline *compiler-pipeline*))
  "Establish ownership before invoking FUNCTION with the request.
Collector inheritance is explicit; source ancestry remains available to diagnostics."
  (unless (member observers '(:inherit :isolate)) (error "Invalid observer ownership ~S" observers))
  (let* ((request (make-compilation-request
                   :purpose purpose :session session :parent *compilation-request*
                   :source-origin *source-origin* :pipeline pipeline
                   :dependencies (request-collector dependencies *dependencies* :dependencies)
                   :calls (request-collector calls *source-definition-calls* :calls)
                   :outputs (request-collector outputs *unit-outputs* :outputs)
                   :fingerprint (request-collector fingerprint *unit-fingerprint* :fingerprint)
                   :observer (and (eq observers :inherit) *source-record-observer*)
                   :definition-parent (and (eq observers :inherit) *source-definition-parent*)))
         (*compilation-request* request)
         (*dependencies* (compilation-request-dependencies request))
         (*source-definition-calls* (compilation-request-calls request))
         (*unit-outputs* (compilation-request-outputs request))
         (*unit-fingerprint* (compilation-request-fingerprint request))
         (*source-record-observer* (compilation-request-observer request))
         (*source-definition-parent* (compilation-request-definition-parent request))
         (*compiler-pipeline* pipeline))
    (when (compilation-request-parent request)
      (push request (compilation-request-children (compilation-request-parent request))))
    (unwind-protect
         (handler-bind ((warning (lambda (condition)
                                  (when (eq *compilation-request* request)
                                    (push condition (compilation-request-diagnostics request))))))
           (let ((results (multiple-value-list (funcall function request))))
             (setf (compilation-request-results request) results
                   (compilation-request-state request) :complete)
             (values-list results)))
      (setf (compilation-request-diagnostics request)
            (nreverse (compilation-request-diagnostics request))
            (compilation-request-children request)
            (nreverse (compilation-request-children request)))
      (unless (eq (compilation-request-state request) :complete)
        (setf (compilation-request-state request) :failed)))))

(defun source-origin (kind &optional operator source)
  (list :kind kind :operator operator :file *source-file* :source source :parent *source-origin*))

(defun form-source-origin (form)
  (loop for request = *compilation-request* then (compilation-request-parent request)
        while request
        for origin = (gethash form (compilation-request-expansion-origins request))
        when origin return origin
        finally (return *source-origin*)))

(defun note-expansion-origin (input output kind &optional origin)
  (let ((origin (or origin (source-origin kind (if (consp input) (car input) input)
                                         (or (and (boundp '*hir-source*) (hir-source-range *hir-source*))
                                             (and (boundp '*macro-source*) *macro-source*))))))
    (when (and *compilation-request* (consp output) (not (eq input output)))
      (let* ((table (compilation-request-expansion-origins *compilation-request*))
             (existing (gethash output table)))
        (unless (loop for parent = existing then (getf parent :parent)
                      while parent thereis (eq parent origin))
          (setf (gethash output table) origin))))
    origin))
