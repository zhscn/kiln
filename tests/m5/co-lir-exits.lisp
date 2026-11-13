(defvar *lir-return-function* nil)
(defvar *lir-go-function* nil)
(defvar *lir-exit-state* nil)

(let ((session (kiln.compiler:make-session)))
  (multiple-value-bind (module original-literals)
      (kiln.compiler:compile-module
       (kiln.compiler::front-end-forms
        '((setq *lir-return-function*
                (lambda (invoke identity)
                  (block result
                    (unwind-protect
                         (funcall invoke (lambda () (return-from result (values identity :returned))))
                      (kiln.sys:%gc)
                      (setq *lir-exit-state* identity)))))
          (setq *lir-go-function*
                (lambda (invoke identity)
                  (block result
                    (let ((remaining (list identity identity)))
                      (tagbody
                       again
                         (unless remaining (go finished))
                         (setq remaining (cdr remaining))
                         (kiln.sys:%gc)
                         (funcall invoke (lambda () (go again)))
                         (return-from result :missed)
                       finished)
                      identity)))))
        session)
       "exit-producer" :session session :image t)
    (multiple-value-bind (program literals)
        (kiln.kir::normalize-lir-module module original-literals)
      (let* ((direct (kiln.sys:%primop :compile-program program literals kiln.kir::+backend-target-fingerprint+))
             (packet (kiln.sys:%primop :encode-packet program kiln.kir::+packet-lir-payload+))
             (decoded (kiln.sys:%primop :compile-packet packet literals)))
        (dolist (initializer (list direct decoded))
          (funcall initializer)
          (let ((identity (vector 'identity))
                (invoke (lambda (function) (funcall function))))
            (setq *lir-exit-state* nil)
            (multiple-value-bind (value kind) (funcall *lir-return-function* invoke identity)
              (print (list (eq value identity) kind (eq *lir-exit-state* identity))))
            (print (eq (funcall *lir-go-function* invoke identity) identity))))))))
