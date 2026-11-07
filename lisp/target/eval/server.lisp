;;;; The back-end protocol: a read-eval-print loop for
;;;; programs (tools, editors, agents). Requests and replies are
;;;; S-expressions. A request is evaluated as a task; an error the task
;;;; does not handle does not end it: the server sends the condition,
;;;; the restarts and the frames, and serves further requests inside the
;;;; debugger, on the same stack (a nested debug level), until a restart
;;;; leaves it.

(in-package #:kiln.kernel)

(defvar *server-output*)                ; where replies go
(defvar *server-input*)
(defvar *debug-level* 0)
(defvar *debug-frames* '())             ; frames of the innermost debug level
(defvar *debug-restarts* '())           ; its restarts

;;; Replies: lists, keywords, integers, NIL and strings. Strings escape
;;; backslash, double quote, newline (\n), carriage return (\r) and tab
;;; (\t), so that a reply is one line (Emacs Lisp reads them as they are).

(defun write-message-string (string stream)
  (write-char #\" stream)
  (loop for c across string
        do (case c
             (#\\ (write-string "\\\\" stream))
             (#\" (write-string "\\\"" stream))
             (#\Newline (write-string "\\n" stream))
             (#\Return (write-string "\\r" stream))
             (#\Tab (write-string "\\t" stream))
             (t (write-char c stream))))
  (write-char #\" stream))

(defun write-message (x stream)
  (cond ((null x) (write-string "nil" stream))
        ((stringp x) (write-message-string x stream))
        ((keywordp x) (write-char #\: stream) (write-string (string-downcase (symbol-name x)) stream))
        ((integerp x) (format stream "~D" x))
        ((consp x)
         (write-char #\( stream)
         (loop for (e . rest) on x
               do (write-message e stream)
                  (when rest (write-char #\Space stream)))
         (write-char #\) stream))
        (t (write-message-string (princ-to-string x) stream))))

(defun send (message)
  (let ((out *server-output*))
    (write-message message out)
    (terpri out)
    (finish-output out)))

(defun safe-string (function object)
  "FUNCTION (PRIN1-TO-STRING, PRINC-TO-STRING) of OBJECT, or a note if
printing signals an error."
  (handler-case (funcall function object)
    (error () "#<error printing object>")))

(defun short-string (object)
  (let ((*print-length* 20) (*print-level* 4))
    (safe-string #'prin1-to-string object)))

;;; Tasks

(defun read-forms (text)
  (with-input-from-string (in text)
    (let ((eof (list nil)))
      (loop for form = (read in nil eof)
            until (eq form eof)
            collect form))))

(defun evaluate-text (text bindings)
  "Evaluates the forms of TEXT in turn; returns the values of the last.
BINDINGS, an alist (VARIABLE . VALUE), are bound lexically around each."
  (let ((values '()))
    (dolist (form (read-forms text) values)
      (setf values (multiple-value-list
                    (eval (if bindings
                              `(let ,(loop for (name . value) in bindings
                                           collect `(,name ',value))
                                 (declare (ignorable ,@(mapcar #'car bindings)))
                                 ,form)
                              form)))))))

(defun run-task (id text &optional bindings)
  "Evaluates TEXT as the task ID, and sends its outcome: (:OK ID VALUES
OUTPUT), or (:ABORTED ID OUTPUT) if a restart left it. Output to the
standard streams is collected."
  (let ((out (make-string-output-stream))
        (sent nil))
    (flet ((finish (message)
             (setf sent t)
             (send message)))
      (unwind-protect
           (let ((values nil) (completed nil))
             (with-simple-restart (abort "Abort task ~D." id)
               (let ((*standard-output* out)
                     (*error-output* out)
                     (*trace-output* out)
                     (*debugger-hook* (lambda (condition hook)
                                        (declare (ignore hook))
                                        (debug-level id condition out))))
                 (setf values (mapcar #'short-string (evaluate-text text bindings))
                       completed t)))
             (finish (if completed
                         `(:ok ,id ,values ,(get-output-stream-string out))
                         `(:aborted ,id ,(get-output-stream-string out)))))
        (unless sent
          (send `(:aborted ,id ,(get-output-stream-string out))))))))

;;; Debug levels

(defun frame-description (frame index)
  "(INDEX NAME FILE LINE COLUMN VARIABLES), strings for the names and
values."
  (multiple-value-bind (file start) (kiln.sys:frame-source frame)
    (multiple-value-bind (line column) (and file start (kiln.sys:source-line file start))
      (list index
            (short-string (kiln.sys:frame-name frame))
            file line column
            (loop for (name . value) in (kiln.sys:frame-variables frame)
                  collect (list (short-string name) (short-string value)))))))

(defparameter *evaluation-functions*
  '(evaluate-text eval kiln.compiler::native-eval kiln.compiler::native-eval-1
    kiln.compiler::native-eval-body kiln.compiler::native-eval-toplevel)
  "Functions whose frames are the server's evaluation of a task.")

(defun task-frames ()
  "The frames of the task that invoked the debugger, without the server's:
those newer than the task's EVALUATE-TEXT and the evaluation under it."
  (let* ((frames (debugger-frames))
         (end (position 'evaluate-text frames :key #'kiln.sys:frame-name)))
    (when end
      (loop while (and (plusp end)
                       (member (frame-name-base (kiln.sys:frame-name (nth (1- end) frames)))
                               *evaluation-functions*))
            do (decf end)))
    (subseq frames 0 end)))

(defun restart-report (restart)
  (let ((report (predicament::report-function restart)))
    (cond ((null report)
           (if (restart-name restart) (symbol-name (restart-name restart)) "restart"))
          (t (safe-string (lambda (r) (with-output-to-string (s) (funcall report s) r))
                          restart)))))

(defun debug-level (id condition out)
  "Called by INVOKE-DEBUGGER for an error of the task ID: sends (:DEBUG
ID LEVEL TYPE REPORT RESTARTS FRAMES OUTPUT), then serves requests here
until a restart leaves."
  (let* ((*debug-level* (1+ *debug-level*))
         (*debug-frames* (task-frames))
         (*debug-restarts* (compute-restarts condition)))
    (send `(:debug ,id ,*debug-level*
                   ,(short-string (class-name (class-of condition)))
                   ,(safe-string #'princ-to-string condition)
                   ,(loop for r in *debug-restarts*
                          for i from 0
                          collect (list i (if (restart-name r) (symbol-name (restart-name r)) "")
                                        (restart-report r)))
                   ,(loop for f in *debug-frames*
                          for i from 0 below 30
                          collect (frame-description f i))
                   ,(get-output-stream-string out)))
    (loop (serve-request))))

;;; Requests

(defun serve-request ()
  "Reads and serves one request. Before reading, sends (:WAITING LEVEL):
a client reads replies up to that line."
  (send `(:waiting ,*debug-level*))
  (let* ((eof (list nil))
         (request (let ((*package* (find-package "KEYWORD"))
                        (*read-eval* nil))
                    (handler-case (read *server-input* nil eof)
                      (error (e)
                        (send `(:error nil ,(safe-string #'princ-to-string e)))
                        (return-from serve-request))))))
    (when (eq request eof)
      (throw 'serve-done nil))
    (destructuring-bind (op &optional id &rest args)
        (if (consp request) request (list request))
      (flet ((fail (control &rest arguments)
               (send `(:error ,id ,(apply #'format nil control arguments)))))
        (case op
          (:eval
           (run-task id (first args)))
          (:eval-in-frame
           (let ((frame (and (integerp (first args)) (nth (first args) *debug-frames*))))
             (if frame
                 (run-task id (second args) (kiln.sys:frame-variables frame))
                 (fail "no frame ~S" (first args)))))
          (:frame
           (let ((frame (and (integerp (first args)) (nth (first args) *debug-frames*))))
             (if frame
                 (send `(:frame ,id ,(frame-description frame (first args))))
                 (fail "no frame ~S" (first args)))))
          (:restart
           (let ((restart (and (integerp (first args)) (nth (first args) *debug-restarts*))))
             (if restart
                 ;; The values of the forms of the text, if any, are the
                 ;; restart's arguments. The reply is the outcome of the
                 ;; tasks it resumes or aborts.
                 (apply #'invoke-restart restart
                        (and (second args)
                             (mapcar #'eval (read-forms (second args)))))
                 (fail "no restart ~S" (first args)))))
          (:package
           (let ((package (find-package (first args))))
             (if package
                 (progn (setf *package* package)
                        (send `(:ok ,id (,(package-name package)) "")))
                 (fail "no package ~S" (first args)))))
          (:quit
           (send `(:bye ,id))
           (throw 'serve-done nil))
          (t (fail "unknown request ~S" op)))))))

(defun kiln.sys:serve (&key (input *standard-input*) (output *standard-output*))
  "Serves the back-end protocol: reads requests from INPUT,
writes replies to OUTPUT, until the end of INPUT or a :QUIT request,
which abort the tasks in progress."
  (let ((*server-input* input)
        (*server-output* output)
        (*package* (find-package "COMMON-LISP-USER"))
        (*debug-level* 0))
    (catch 'serve-done
      (loop (serve-request)))
    nil))
