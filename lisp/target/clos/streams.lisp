;;;; Streams (docs/10 §16): kiln's client of Cyclosis, intrinsic: the CL
;;;; stream functions are Cyclosis'. The standard streams are POSIX file
;;;; streams on descriptors 0, 1 and 2, which read and write through the
;;;; runtime (kiln_rt_fd_read, kiln_rt_fd_write).

(in-package #:cyclosis)

(defun octet-storage (octets)
  (if (simple-vector-p octets) octets (regalia::contents octets)))

(defun check-octet-range (octets start end)
  (unless (and (integerp start) (integerp end) (<= 0 start end (length octets)))
    (error "Bad octet range ~s ~s for a vector of length ~s" start end (length octets))))

(defun kiln.kernel::%fd-write (fd octets start end)
  (check-octet-range octets start end)
  (let ((n (kiln.sys:%primop :fd-write fd (octet-storage octets) start end)))
    (when (minusp n)
      (error 'stream-error :stream fd))
    n))

(defun kiln.kernel::%fd-read (fd octets start end)
  (check-octet-range octets start end)
  (let ((n (kiln.sys:%primop :fd-read fd (octet-storage octets) start end)))
    (when (minusp n)
      (error 'stream-error :stream fd))
    n))

(defclass kiln-client () ())

(defparameter *client* (make-instance 'kiln-client))

(defparameter +standard-input+
  (make-instance 'posix-file-stream
                 :descriptor 0 :input t :close-descriptor nil :element-type 'character))

(defparameter +standard-output+
  (make-instance 'posix-file-stream
                 :descriptor 1 :output t :close-descriptor nil :element-type 'character))

(defparameter +error-output+
  (make-instance 'posix-file-stream
                 :descriptor 2 :output t :close-descriptor nil :element-type 'character))

(defparameter +terminal-io+
  (make-instance 'two-way-stream
                 :input-stream +standard-input+ :output-stream +standard-output+))

(macrolet ((initial (name target)
             `(defmethod trinsic:initial-cell-value
                  ((client kiln-client) (name (eql ',name)) (type (eql 'cl:variable)))
                (make-instance 'synonym-stream :symbol ',target))))
  (initial cl:*standard-input* +standard-input+)
  (initial cl:*standard-output* +standard-output+)
  (initial cl:*error-output* +error-output+)
  (initial cl:*trace-output* +error-output+)
  (initial cl:*terminal-io* +terminal-io+)
  (initial cl:*query-io* +terminal-io+)
  (initial cl:*debug-io* +terminal-io+))

(defmethod whitespace-char-p ((client kiln-client) ch)
  (and (member ch '(#\Tab #\Newline #\Linefeed #\Page #\Return #\Space)) t))

(define-interface :client-class kiln-client :client-form *client* :intrinsic t)
