;;;; A read-eval-print loop (docs/11 §3, M5.1). An error not handled by the
;;;; form is reported and the loop continues (there is no debugger yet:
;;;; the ABORT restart returns to the prompt).

(in-package #:kiln.kernel)

(defvar * nil)
(defvar ** nil)
(defvar *** nil)
(defvar + nil)
(defvar ++ nil)
(defvar +++ nil)
(defvar / nil)
(defvar // nil)
(defvar /// nil)
(defvar - nil)

(defun kiln.sys:repl (&key (input *standard-input*) (output *standard-output*) (prompt t))
  "Reads forms from INPUT, evaluates them and prints their values to
OUTPUT, until the end of INPUT."
  (let ((eof (list nil))
        (*package* *package*))
    (loop
      (when prompt
        (format output "~A> " (package-name *package*))
        (force-output output))
      (with-simple-restart (abort "Return to the REPL.")
        (let ((*debugger-hook*
                (lambda (condition hook)
                  (declare (ignore hook))
                  (format *error-output* "~&error: ~A~%" condition)
                  (force-output *error-output*)
                  (abort))))
          (let ((form (read input nil eof)))
            (when (eq form eof)
              (fresh-line output)
              (return-from kiln.sys:repl nil))
            (setq - form)
            (let ((values (multiple-value-list (eval form))))
              (setq /// // // / / values
                    *** ** ** * * (first values)
                    +++ ++ ++ + + form)
              ;; No FRESH-LINE first: on a terminal the line typed ends
              ;; with a newline the output stream does not see.
              (dolist (value values)
                (format output "~S~%" value)))))))))
