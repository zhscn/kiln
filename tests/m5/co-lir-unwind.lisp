(defvar *lir-unwind-function* nil)
(defvar *lir-unwind-state* nil)
(defvar *lir-unwind-bound* :outside)

(let ((session (kiln.compiler:make-session)))
  (multiple-value-bind (module original-literals)
      (kiln.compiler:compile-module
       (kiln.compiler::front-end-forms
        '((setq *lir-unwind-function*
                (lambda (mode identity callback)
                  (catch 'done
                    (catch 'other
                      (let ((*lir-unwind-bound* identity))
                        (unwind-protect
                             (cond ((eq mode :call) (funcall callback identity))
                                   ((eq mode :apply) (apply callback (list identity)))
                                   ((eq mode :error) (car identity))
                                   ((eq mode :zero) (throw 'done (values)))
                                   (mode (throw 'done (values identity :thrown)))
                                   (t (values identity :normal)))
                          (kiln.sys:%gc)
                          (setq *lir-unwind-state* *lir-unwind-bound*)
                          (when (eq mode :replace)
                            (throw 'done (values identity :replaced))))))))))
        session)
       "unwind-producer" :session session :image t)
    (multiple-value-bind (program literals)
        (kiln.kir::normalize-lir-module module original-literals)
      (let* ((direct (kiln.sys:%primop :compile-program program literals kiln.kir::+backend-target-fingerprint+))
             (packet (kiln.sys:%primop :encode-packet program kiln.kir::+packet-lir-payload+))
             (decoded (kiln.sys:%primop :compile-packet packet literals)))
        (dolist (initializer (list direct decoded))
          (funcall initializer)
          (dolist (mode '(t nil :call :apply :replace))
            (let ((identity (vector 'identity)))
              (setq *lir-unwind-state* nil)
              (multiple-value-bind (value kind)
                  (funcall *lir-unwind-function* mode identity
                           (lambda (value) (throw 'done (values value :called))))
                (print (list (eq value identity) kind
                             (eq *lir-unwind-state* identity) *lir-unwind-bound*)))))
          (let ((identity (vector 'identity)))
            (handler-case (funcall *lir-unwind-function* :error identity nil)
              (type-error () (print (list :error (eq *lir-unwind-state* identity) *lir-unwind-bound*))))
            (print (list :zero
                         (null (multiple-value-list (funcall *lir-unwind-function* :zero identity nil)))
                         (eq *lir-unwind-state* identity) *lir-unwind-bound*))
            (let ((value (catch 'external
                           (funcall *lir-unwind-function* :call identity
                                    (lambda (value) (throw 'external value))))))
              (print (list :external (eq value identity)
                           (eq *lir-unwind-state* identity) *lir-unwind-bound*)))))))))

(dolist (case
          '((:unknown-handler "unknown source handler"
             (:func "bad" (:vars (:a :obj))
               (:block :e (:runtime-op :a :gc () :missing) (:return :a 1))))
            (:missing-landing "region has no source landing"
             (:func "bad" (:vars)
               (:slots (:r (:dynamic-entry :catch)))
               (:block :e (:dynamic-enter :r :catch (:fixnum-tag 0))
                 (:dynamic-leave :r) (:return (:fixnum-tag 0) 1))))
            (:dispatch-shape "isolated dispatch block"
             (:func "bad" (:vars)
               (:block :e (:br (:unwind-target-p :r) :land :outer) (:trap))))))
  (let* ((module (kiln.kir:make-kmodule "rejected-unwind"))
         (kiln.kir::*module* module))
    (kiln.kir:module-data "entry" '(:static-function "bad"))
    (kiln.kir:module-init "entry")
    (push (third case) (kiln.kir::kmodule-funcs module))
    (handler-case (kiln.kir::normalize-lir-module module)
      (error (condition)
        (print (and (search (second case) (princ-to-string condition)) (first case)))))))
