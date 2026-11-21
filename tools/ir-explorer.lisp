;;;; Invoked by ir-explorer.py in an SBCL process with Quicklisp.
(load (merge-pathnames "env.lisp" *load-truename*))
(ql:quickload "kiln" :silent t)
(in-package #:kiln.compiler)

(defparameter *explorer-instruction-names*
  #(:constant :argument :global-read :global-write :global-function :function
    :global-call :call :primop :single :primary :declaration-check :argument-count
    :arity-check :value-ref :multiple-value-call :argument-present :rest-list
    :argument-error :cell :cell-read :cell-write :capture :closure :closure-set
    :unbound-cell :load-time-value :special-bind :special-unbind :progv-enter
    :catch-enter :landed-values :protect-enter :cleanup-landing :block-enter
    :tagbody-enter :go-landing :value-present :values-tail :values-asserted :debug-binding))

(defparameter *explorer-terminator-names*
  #(:jump :branch :return :trap :throw :region-entry :continue-unwind :exit-to))

(defun explorer-kind-name (kind names)
  (if (< kind (length names)) (svref names kind) kind))

(defun explorer-function-p (function filter)
  (let ((name (or (mir-function-name function) (mir-function-debug-name function))))
    (or (null filter) (string-equal filter (princ-to-string name))
        (and (symbolp name) (string-equal filter (symbol-name name))))))

(defun explorer-mir (unit filter out)
  (let ((functions 0) (blocks 0) (instructions 0) (values 0) (calls 0))
    (loop for function across (hir-vector (mir-unit-functions unit))
          when (explorer-function-p function filter)
            do (incf functions)
               (incf values (hir-buffer-count (mir-function-values function)))
               (format out "~&function ~D ~S~%" (mir-function-id function)
                       (or (mir-function-name function) (mir-function-debug-name function)))
               (loop for block across (hir-vector (mir-function-blocks function))
                     do (incf blocks)
                        (format out "  block ~D ~S~%" (mir-block-id block) (mir-block-parameters block))
                        (loop for id across (hir-vector (mir-block-instructions block))
                              for inst = (mir-at (mir-function-instructions function) id)
                              for kind = (mir-instruction-kind inst)
                              do (incf instructions)
                                 (when (member kind '(6 7 15)) (incf calls))
                                 (format out "    ~S = ~S ~S ~S~%"
                                         (mir-instruction-result inst)
                                         (explorer-kind-name kind *explorer-instruction-names*)
                                         (mir-instruction-operands inst) (mir-instruction-data inst)))
                        (let ((term (mir-block-terminator block)))
                          (format out "    ~S ~S ~S~%"
                                  (explorer-kind-name (mir-terminator-kind term) *explorer-terminator-names*)
                                  (mir-terminator-operands term)
                                  (map 'list (lambda (edge)
                                               (list (mir-edge-target edge) (mir-edge-arguments edge)))
                                       (mir-terminator-edges term))))))
    (list functions blocks instructions values calls)))

(destructuring-bind (input directory requested kernel &rest preludes) (cdr sb-ext:*posix-argv*)
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (filter (unless (zerop (length requested)) requested))
         (session (make-session))
         (unit 0) (step 0) (matches 0) (hir nil) (selected-unit nil))
    (when (string= kernel "yes")
      (kiln::compile-files kiln::*kernel-files* session "kernel"))
    (when preludes
      (kiln::compile-files preludes session "explorer-prelude"))
    (with-open-file (index (merge-pathnames "stages.tsv" directory) :direction :output)
      (with-open-file (labels (merge-pathnames "labels.txt" directory) :direction :output)
        (with-open-file (expansions (merge-pathnames "expansions.txt" directory) :direction :output)
          (let ((kiln.sys:*macroexpansion-hook*
                  (lambda (event) (kiln.sys:print-macroexpansions (list event) expansions)))
                (*compiler-stage-observer*
                  (lambda (stage payload ticks)
                    (let ((*print-circle* t))
                      (case stage
                        (:hir
                         (incf unit)
                         (setf step 0 hir payload selected-unit nil))
                        (:labels
                         (loop for function across (car payload) for label across (cdr payload)
                               when (explorer-function-p function filter)
                                 do (incf matches)
                                    (format labels "~A~%" (coerce label 'string))))
                        (otherwise
                         (incf step)
                         (when (and (not selected-unit)
                                    (or (null filter)
                                        (some (lambda (function) (explorer-function-p function filter))
                                              (hir-vector (mir-unit-functions payload)))))
                           (setf selected-unit t)
                           (with-open-file (out (merge-pathnames (format nil "u~D.hir" unit) directory)
                                                :direction :output)
                             (pprint hir out))
                           (setf hir nil))
                         (when selected-unit
                           (let* ((name (format nil "u~D-~2,'0D.mir" unit step))
                                  (counts (with-open-file (out (merge-pathnames name directory)
                                                               :direction :output)
                                            (explorer-mir payload filter out))))
                             (format index "~D~C~A~C~A~C~A~{~C~D~}~%"
                                     unit #\Tab (string-downcase (symbol-name stage)) #\Tab name #\Tab
                                     (if ticks (truncate (* ticks 1000000) internal-time-units-per-second) "-")
                                     (loop for count in counts append (list #\Tab count)))))))))))
            (kiln:compile-file-to-lir input (merge-pathnames "program.lir" directory)
                                      :session session)))))
    (when (and filter (zerop matches))
      (error "No emitted function matched ~S." filter))))
