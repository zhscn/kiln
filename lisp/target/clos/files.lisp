;;;; File streams: Cyclosis' POSIX file streams with a
;;;; buffer, and OPEN's MAKE-FILE-STREAM for kiln's client. Cyclosis'
;;;; transcoders read and write one octet at a time; without a buffer each
;;;; would be a system call. The standard streams (streams.lisp) are not
;;;; buffered, so that their output is not delayed or reordered.

(in-package #:cyclosis)

(defconstant +file-buffer-size+ 8192)

(defstruct (file-buffer-state (:conc-name buffer-state-))
  (buffer (kiln.kernel::make-simple-vector +file-buffer-size+ 0))
  (in-start 0) (in-end 0) (out-end 0) (utf-8-characters :unknown))

(defclass kiln-file-stream (posix-file-stream)
  ((%buffer-state :initform (make-file-buffer-state) :reader file-state)
   ;; The descriptor's file offset, kept by the reads, writes and seeks
   ;; below, so that FILE-POSITION (asked at every form the reader makes
   ;; a CST of) needs no system call; NIL until first asked.
   (%os-position :initform nil :accessor os-position)
   (%octets-per-element :initform nil :accessor %octets-per-element)
   ;; Opened with O_APPEND: each write moves the offset to the end, so it
   ;; is not kept across writes.
   (%append :initform nil :initarg :append :reader file-append-p)))

(declaim (inline file-buffer in-start in-end out-end %utf-8-characters
                 (setf in-start) (setf in-end) (setf out-end)
                 (setf %utf-8-characters)))
(defun file-buffer (stream) (buffer-state-buffer (file-state stream)))
(defun in-start (stream) (buffer-state-in-start (file-state stream)))
(defun in-end (stream) (buffer-state-in-end (file-state stream)))
(defun out-end (stream) (buffer-state-out-end (file-state stream)))
(defun %utf-8-characters (stream) (buffer-state-utf-8-characters (file-state stream)))
(defun (setf in-start) (value stream)
  (setf (buffer-state-in-start (file-state stream)) value))
(defun (setf in-end) (value stream)
  (setf (buffer-state-in-end (file-state stream)) value))
(defun (setf out-end) (value stream)
  (setf (buffer-state-out-end (file-state stream)) value))
(defun (setf %utf-8-characters) (value stream)
  (setf (buffer-state-utf-8-characters (file-state stream)) value))

(defun note-written (stream count)
  (cond ((file-append-p stream) (setf (os-position stream) nil))
        ((os-position stream) (incf (os-position stream) count))))

(defun known-os-position (stream)
  (or (os-position stream)
      (setf (os-position stream)
            (check-sys stream (kiln.kernel::sys 2 (descriptor stream) 0 1)))))

(defun check-sys (stream result)
  (when (minusp result)
    (error 'stream-error :stream stream))
  result)

(defun flush-file-buffer (stream)
  (let ((end (out-end stream)))
    (when (plusp end)
      (setf (out-end stream) 0)
      (let ((written 0))
        (loop while (< written end)
              do (incf written
                       (check-sys stream
                                  (kiln.sys:%primop :fd-write (descriptor stream)
                                                    (file-buffer stream) written end)))))
      (note-written stream end))))

;;; The compiler writes its KIR files via kiln_rt_write_kir, after the
;;; buffered output, instead of one character at a time through the stream.
;;; NIL if STREAM is not a kiln file stream writing UTF-8; the caller prints
;;; the forms itself then. The output cursor is not updated (nothing reads
;;; the column of a KIR file).
(defun underlying-file-stream (stream)
  (loop while (typep stream 'synonym-stream)
        do (setf stream (symbol-value (cl:synonym-stream-symbol stream))))
  (and (typep stream 'posix-file-stream)
       (typep (octet-transcoder stream) 'utf-8-transcoder)
       stream))

(defun kiln.sys::%write-kir (form stream)
  (let ((stream (underlying-file-stream stream)))
    (when stream
      (when (typep stream 'kiln-file-stream)
        (when (< (in-start stream) (in-end stream))
          (discard-file-input stream))
        (flush-file-buffer stream))
      (let ((result (kiln.sys:%primop :write-kir form (descriptor stream))))
        (when (eql result -1000)
          (error "~S is not a KIR form." form))
        (check-sys stream result)
        (when (typep stream 'kiln-file-stream)
          (note-written stream result)))
      t)))

(defun kiln.sys::%write-backend-packet (program stream)
  (loop while (typep stream 'synonym-stream)
        do (setf stream (symbol-value (cl:synonym-stream-symbol stream))))
  (when (and (typep stream 'kiln-file-stream)
             (equal (cl:stream-element-type stream) '(unsigned-byte 8)))
    (when (< (in-start stream) (in-end stream)) (discard-file-input stream))
    (flush-file-buffer stream)
    (let ((result (kiln.sys:%primop :write-packet program (descriptor stream))))
      (when (eql result -1000) (error "Invalid backend program."))
      (check-sys stream result)
      (note-written stream result))
    t))

(defun discard-file-input (stream)
  "Moves the file position back over the input read ahead."
  (let ((ahead (- (in-end stream) (in-start stream))))
    (when (plusp ahead)
      (setf (os-position stream)
            (check-sys stream (kiln.kernel::sys 2 (descriptor stream) (- ahead) 1))))
    (setf (in-start stream) 0 (in-end stream) 0)))

(defmethod stream-write-octet ((stream kiln-file-stream) octet)
  (when (< (in-start stream) (in-end stream))
    (discard-file-input stream))
  (when (= (out-end stream) +file-buffer-size+)
    (flush-file-buffer stream))
  (setf (svref (file-buffer stream) (out-end stream)) octet)
  (incf (out-end stream))
  octet)

(defmethod stream-write-octets ((stream kiln-file-stream) octets &optional (start 0) end)
  ;; Copied into the buffer a chunk at a time: one generic function call
  ;; per octet (STREAM-WRITE-OCTET and its accessors) was most of the time
  ;; of writing KIR on kiln.
  (let ((end (or end (length octets)))
        (buffer (file-buffer stream))
        (i start))
    (when (< (in-start stream) (in-end stream))
      (discard-file-input stream))
    (loop while (< i end)
          do (when (= (out-end stream) +file-buffer-size+)
               (flush-file-buffer stream))
             (let* ((fill (out-end stream))
                    (n (min (- end i) (- +file-buffer-size+ fill))))
               (if (simple-vector-p octets)
                   (dotimes (k n)
                     (setf (svref buffer (+ fill k)) (svref octets (+ i k))))
                   (dotimes (k n)
                     (setf (svref buffer (+ fill k)) (aref octets (+ i k)))))
               (setf (out-end stream) (+ fill n))
               (setf i (+ i n)))))
  octets)

(defmethod stream-read-octet ((stream kiln-file-stream))
  (flush-file-buffer stream)
  (when (= (in-start stream) (in-end stream))
    (let ((n (check-sys stream
                        (kiln.sys:%primop :fd-read (descriptor stream) (file-buffer stream)
                                          0 +file-buffer-size+))))
      (setf (in-start stream) 0 (in-end stream) n)
      (when (os-position stream)
        (incf (os-position stream) n))))
  (if (= (in-start stream) (in-end stream))
      :eof
      (prog1 (svref (file-buffer stream) (in-start stream))
        (incf (in-start stream)))))

;;; A character that is one ASCII octet already in the buffer is taken
;;; from it directly; anything else (a multi-octet character, an empty
;;; buffer, pending output, another external format) goes through the
;;; transcoder as before. The reader reads source files this way, and they
;;; are nearly all ASCII. CHARACTER-INPUT-MIXIN's :AROUND method still
;;; handles UNREAD-CHAR and the cursor.
(defmethod stream-read-char ((stream kiln-file-stream))
  (let* ((state (file-state stream))
         (start (buffer-state-in-start state))
         (buffer (buffer-state-buffer state)))
    (if (and (< start (buffer-state-in-end state))
             (zerop (buffer-state-out-end state))
             (if (eq (buffer-state-utf-8-characters state) :unknown)
                 (utf-8-characters-p stream)
                 (buffer-state-utf-8-characters state))
             (< (svref buffer start) #x80))
        (progn (setf (buffer-state-in-start state) (+ start 1))
               (code-char (svref buffer start)))
        (call-next-method))))

(defun utf-8-characters-p (stream)
  "Is STREAM a character stream decoding UTF-8? Kept once known."
  (let ((known (%utf-8-characters stream)))
    (if (eq known :unknown)
        (setf (%utf-8-characters stream)
              (and (not (subtypep (stream-element-type stream) 'integer))
                   (typep (octet-transcoder stream) 'utf-8-transcoder)))
        known)))

(defmethod stream-read-octets ((stream kiln-file-stream) octets &optional (start 0) end)
  (let ((end (or end (length octets))))
    (do ((i start (+ i 1)))
        ((= i end) (- end start))
      (let ((octet (stream-read-octet stream)))
        (when (eq octet :eof)
          (return (- i start)))
        (setf (aref octets i) octet)))))

(defmethod stream-finish-output ((stream kiln-file-stream))
  (flush-file-buffer stream)
  nil)

(defmethod stream-force-output ((stream kiln-file-stream))
  (flush-file-buffer stream)
  nil)

(defmethod stream-clear-output ((stream kiln-file-stream))
  (setf (out-end stream) 0)
  nil)

(defun octets-per-element (stream)
  ;; Character streams are positioned in octets. The element type of a
  ;; file stream does not change: kept once computed.
  (or (and (typep stream 'kiln-file-stream) (%octets-per-element stream))
      (let ((n (if (subtypep (stream-element-type stream) 'integer)
                   (element-length (octet-transcoder stream))
                   1)))
        (when (typep stream 'kiln-file-stream)
          (setf (%octets-per-element stream) n))
        n)))

(defun unread-octets (stream)
  "The octets of the character UNREAD-CHAR gave back to STREAM, in UTF-8:
they have been read from the file, but the character has not."
  (let ((char (previous-char stream)))
    (if (characterp char)
        (let ((code (char-code char)))
          (cond ((< code #x80) 1) ((< code #x800) 2) ((< code #x10000) 3) (t 4)))
        0)))

(defmethod stream-file-position ((stream kiln-file-stream))
  (let ((octets (- (+ (known-os-position stream) (out-end stream)
                      (- (in-start stream) (in-end stream)))
                   (unread-octets stream)))
        (scale (octets-per-element stream)))
    (if (eql scale 1) octets (values (floor octets scale)))))

(defmethod (setf stream-file-position) (position (stream kiln-file-stream))
  (flush-file-buffer stream)
  (setf (in-start stream) 0 (in-end stream) 0)
  (setf (previous-char stream) nil)
  (let ((r (case position
             (:start (kiln.kernel::sys 2 (descriptor stream) 0 0))
             (:end (kiln.kernel::sys 2 (descriptor stream) 0 2))
             (t (kiln.kernel::sys 2 (descriptor stream)
                                  (* position (octets-per-element stream)) 0)))))
    (setf (os-position stream) (if (minusp r) nil r))
    (not (minusp r))))

(defmethod stream-file-length ((stream kiln-file-stream))
  (flush-file-buffer stream)
  (/ (check-sys stream (kiln.kernel::sys 12 (descriptor stream)))
     (octets-per-element stream)))

(defmethod close :before ((stream kiln-file-stream) &key abort)
  (when (stream-open-p stream)
    (if abort
        (setf (out-end stream) 0)
        (flush-file-buffer stream))
    (when (and (close-descriptorp stream) (not (minusp (descriptor stream))))
      (kiln.kernel::sys 1 (descriptor stream))
      (setf (descriptor stream) -1))))

(defun open-flags (direction)
  (ecase direction
    ((:input :probe) 1)
    (:output 2)
    (:io 3)))

;;; As Cyclosis' SBCL method, but :SUPERSEDE and :NEW-VERSION truncate the
;;; file instead of writing a temporary file, and :NEW-VERSION is :ERROR
;;; when the file exists (Unix has no versions; SBCL does the same).
(defmethod make-file-stream
    ((client kiln-client) path direction if-exists if-does-not-exist element-type external-format)
  (let* ((name (kiln.kernel::native-octets path))
         (exists (kiln.kernel::file-kind path))
         (flags (open-flags direction))
         (created nil))
    (flet ((fail (errno)
             (error 'open-fail :pathname path
                               :message (kiln.kernel::errno-message (- errno)))))
      (if (member direction '(:input :probe))
          (unless exists
            (ecase if-does-not-exist
              (:error (error 'file-does-not-exist :pathname path))
              (:create (ensure-directories-exist path)
               (setf flags (logior flags 4) created t))
              ((nil) (return-from make-file-stream nil))))
          (if exists
              (ecase if-exists
                ((:error :new-version) (error 'file-exists :pathname path))
                (:rename
                 (rename-file path (concatenate 'string (namestring path) ".bak"))
                 (setf flags (logior flags 4) created t))
                ((:rename-and-delete :supersede) (setf flags (logior flags 8)))
                (:append (setf flags (logior flags 16)))
                (:overwrite)
                ((nil) (return-from make-file-stream nil)))
              (ecase if-does-not-exist
                (:error (error 'file-does-not-exist :pathname path))
                (:create (ensure-directories-exist path)
                 (setf flags (logior flags 4 8) created t))
                ((nil) (return-from make-file-stream nil)))))
      (let ((fd (kiln.kernel::sys 0 name flags #o666)))
        (when (minusp fd)
          (fail fd))
        (let ((stream (make-instance 'kiln-file-stream
                                     :descriptor fd
                                     :pathname path
                                     :created created
                                     :append (logtest flags 16)
                                     :input (and (member direction '(:input :io)) t)
                                     :output (and (member direction '(:output :io)) t)
                                     :element-type (if (eq element-type :default)
                                                       'character
                                                       element-type)
                                     :external-format external-format)))
          ;; :APPEND starts at the end of the file (O_APPEND only moves
          ;; the offset there at the first write).
          (when (logtest flags 16)
            (setf (os-position stream) (check-sys stream (kiln.kernel::sys 2 fd 0 2))))
          (when (eq direction :probe)
            (close stream))
          stream)))))
