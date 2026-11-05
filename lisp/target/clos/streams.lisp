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

;;; A string goes out with one write: STREAM-WRITE-CHAR writes the octets
;;; of each character with its own (kiln's file streams have no buffer,
;;; so that their output and the runtime's PRINT stay in order). The
;;; compiler on kiln writes its KIR this way (docs/11 §9).
(defmethod stream-write-string ((stream posix-file-stream) string &optional (start 0) end)
  (check-character-stream stream)
  (let ((end (or end (length string))))
    (if (not (typep (octet-transcoder stream) 'utf-8-transcoder))
        (call-next-method)
        (let ((octets (kiln.kernel::make-simple-vector (* 4 (- end start)) 0))
              (count 0)
              (cursor (output-cursor stream)))
          (flet ((out (octet)
                   (setf (svref octets count) octet)
                   (setf count (+ count 1))))
            (loop for index from start below end
                  for char = (char string index)
                  for code = (char-code char)
                  do (cond ((< code #x80)
                            (out code))
                           ((< code #x800)
                            (out (logior #b11000000 (ash code -6)))
                            (out (logior #b10000000 (logand code #b111111))))
                           ((< code #x10000)
                            (out (logior #b11100000 (ash code -12)))
                            (out (logior #b10000000 (logand (ash code -6) #b111111)))
                            (out (logior #b10000000 (logand code #b111111))))
                           (t
                            (out (logior #b11110000 (ash code -18)))
                            (out (logior #b10000000 (logand (ash code -12) #b111111)))
                            (out (logior #b10000000 (logand (ash code -6) #b111111)))
                            (out (logior #b10000000 (logand code #b111111)))))
                     (update-cursor cursor char)))
          (when (plusp count)
            (stream-write-octets stream octets 0 count))
          (setf (output-cursor stream) cursor)
          string))))
