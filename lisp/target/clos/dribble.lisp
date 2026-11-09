;;;; Session transcripts preserve the standard streams at each nesting level.

(in-package #:kiln.kernel)

(defvar *dribble-stream* nil)
(defvar *previous-dribble-streams* nil)

(defun dribble (&optional pathname &key (if-exists :append))
  (cond
    (pathname
     (let ((stream (open pathname :direction :output :if-exists if-exists
                                 :if-does-not-exist :create))
           (installed nil))
       (unless stream (error "No dribble file was opened for ~S." pathname))
       (unwind-protect
            (let ((input (make-echo-stream *standard-input* stream))
                  (output (make-broadcast-stream *standard-output* stream))
                  (errors (make-broadcast-stream *error-output* stream)))
              (push (list *dribble-stream* *standard-input* *standard-output* *error-output*)
                    *previous-dribble-streams*)
              (setf *dribble-stream* stream
                    *standard-input* input
                    *standard-output* output
                    *error-output* errors
                    installed t))
         (unless installed (close stream :abort t)))))
    ((null *dribble-stream*) (error "Not currently dribbling."))
    (t
     (let ((stream *dribble-stream*) (closed nil))
       (unwind-protect
            (progn (close stream) (setf closed t))
         (unless closed (ignore-errors (close stream :abort t)))
         (destructuring-bind (previous input output errors) (pop *previous-dribble-streams*)
           (setf *dribble-stream* previous
                 *standard-input* input
                 *standard-output* output
                 *error-output* errors))))))
  (values))
