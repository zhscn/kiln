(cl:in-package #:common-boot)

(defmethod abp:finish-node
    ((builder builder)
     (kind t)
     (ast ico:load-time-value-ast))
  (with-builder-components (builder client environment)
    ;; kiln: a lexical environment with nothing but the global one
    ;; (upstream: the global environment itself, in which a LAMBDA form
    ;; cannot add its local functions or variables).
    (let* ((global-environment
             (make-instance 'trucler-reference:environment
               :global-environment (trucler:global-environment client environment)))
           (new-builder (make-builder client global-environment)))
      (reinitialize-instance ast
        :form-ast (convert-ast new-builder (ico:form-ast ast))))))

