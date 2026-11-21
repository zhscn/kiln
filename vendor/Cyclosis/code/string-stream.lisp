(cl:in-package #:cyclosis)

(defclass string-stream (stream)
  ((%string :accessor stream-string
            :initarg :string
            :type string)
   (%position :accessor stream-file-position
              :initarg :position
              :initform nil)))

(defmethod initialize-instance :after ((instance string-stream) &rest initargs &key)
  (declare (ignore initargs))
  (check-type (stream-string instance) string))

;;; String output stream and with-output-to-string.

(defclass string-output-stream
    (character-output-mixin string-stream fundamental-character-output-stream)
  ()
  (:default-initargs :position 0))

(defmethod initialize-instance :after ((instance string-output-stream) &rest initargs &key)
  (declare (ignore initargs))
  (unless (array-has-fill-pointer-p (stream-string instance))
    (error "~S must be a string with a fill-pointer"
           (stream-string instance))))

(defmethod (setf stream-file-position) :around (position (instance string-output-stream))
  (with-accessors ((string stream-string))
      instance
    (case position
      (:start
       (call-next-method 0 instance))
      (:end
       (call-next-method (length string) instance))
      (otherwise
       (call-next-method)))))

(defmethod (setf stream-file-position) :after (position (instance string-output-stream))
  (with-accessors ((string stream-string)
                   (position stream-file-position))
      instance
    (cond ((< position (fill-pointer string)))
          ((< (fill-pointer string) (array-total-size string))
           (setf (fill-pointer string) position))
          (t
           ;; kiln: grow geometrically (upstream: by 32, quadratic).
           (adjust-array string (max (+ position 32) (* 2 (array-total-size string)))
                         :fill-pointer position)))))

(defmethod stream-write-char ((stream string-output-stream) character)
  ;; kiln: the position is the string's length (STREAM-FILE-POSITION
  ;; below), so the character is always appended, and VECTOR-PUSH-EXTEND
  ;; keeps the fill pointer: the slot is written directly, without the
  ;; methods of (SETF STREAM-FILE-POSITION), which did that bookkeeping
  ;; through generic functions for every character.
  (let ((string (stream-string stream)))
    (vector-push-extend character string)
    (setf (slot-value stream '%position) (length string))
    character))

(defun try-append-native-string (stream string source start end)
  (declare (fixnum start end))
  (let ((layout regalia::*character-vector-layout*))
    (when (and (kiln.sys:%primop :stringp source)
               (kiln.sys:%primop :standard-instance-p string)
               (eq (kiln.sys:%primop :standard-instance-access string -2)
                   (kiln.sys:%primop :svref-unchecked layout 0))
               (null (kiln.sys:%primop :standard-instance-access
                                     string (kiln.sys:%primop :svref-unchecked layout 2))))
      (let* ((slot (kiln.sys:%primop :svref-unchecked layout 3))
             (fill (kiln.sys:%primop :standard-instance-access string slot))
             (storage (kiln.sys:%primop :standard-instance-access
                                        string (kiln.sys:%primop :svref-unchecked layout 4))))
        (when (and (not (eq source storage))
                   (kiln.sys:%primop :fixnump fill)
                   (<= (- end start) (- (kiln.sys:%primop :length storage) fill)))
          (let* ((cursor (output-cursor stream))
                 (column (caar cursor)) (line (cdar cursor))
                 (previous-column column) (previous-line line)
                 (destination fill))
            (declare (fixnum destination))
            (do ((index start (1+ index))) ((= index end))
              (declare (fixnum index))
              (let ((char (kiln.sys:%primop :schar-unchecked source index)))
                (kiln.sys:%primop :set-schar-unchecked storage destination char)
                (incf destination)
                (setf previous-column column previous-line line)
                (if (eq char #\Newline)
                    (setf column 0 line (1+ line))
                    (incf column))))
            (kiln.sys:%primop :set-standard-instance-access string slot destination)
            (setf (slot-value stream '%position) destination
                  (caar cursor) column (cdar cursor) line
                  (caadr cursor) previous-column (cdadr cursor) previous-line)
            t))))))

;;; Append the selected range and update the output cursor.
(defun append-output-string (stream seq start end)
  (let* ((string (stream-string stream))
         (end (if (kiln.sys:%primop :stringp seq)
                  (kiln.kernel::%string-bounds seq start end)
                  (kiln.kernel::sequence-end seq start end))))
    (when (or (= start end) (try-append-native-string stream string seq start end))
      (return-from append-output-string seq))
    (let* ((current-length (length string))
           (new-length (+ current-length (- end start))))
      (when (< (array-total-size string) new-length)
        (adjust-array string (max new-length (* 2 (array-total-size string)))))
      (setf (fill-pointer string) new-length)
      (replace string seq :start1 current-length :start2 start :end2 end)
      (setf (slot-value stream '%position) new-length)
      (let* ((cursor (output-cursor stream))
             (column (caar cursor)) (line (cdar cursor))
             (previous-column column) (previous-line line))
        (loop for index from start below end
              do (setf previous-column column previous-line line)
                 (if (char= (char seq index) #\Newline)
                     (setf column 0 line (1+ line))
                     (setf column (1+ column))))
        (setf (caar cursor) column (cdar cursor) line
              (caadr cursor) previous-column (cdadr cursor) previous-line))
      seq)))

(defmethod stream-write-string
    ((stream string-output-stream) seq &optional (start 0) end)
  (append-output-string stream seq start end))

(defmethod stream-write-sequence
    ((stream string-output-stream) seq &optional (start 0) end)
  (when (stringp seq)
    (return-from stream-write-sequence
      (append-output-string stream seq start end)))
  (with-accessors ((string stream-string))
      stream
    (unless end
      (setf end (length seq)))
    (map nil (lambda (ch)
               (update-output-cursor stream ch))
         seq)
    (let ((current-length (length string))
          (new-length (+ (length string) (- end start))))
      (when (< (array-dimension string 0) new-length)
        (adjust-array string new-length))
      (setf (fill-pointer string) new-length)
      (replace string seq
               :start1 current-length
               :start2 start
               :end2 end)
      seq)))

(defmethod stream-file-position ((stream string-output-stream))
  (length (stream-string stream)))

(defmethod stream-element-type ((stream string-output-stream))
  (array-element-type (stream-string stream)))

;;; kiln: used by a macro at compile time.
(eval-when (:compile-toplevel :load-toplevel :execute)
(defun expand-with-output-to-string
    (var string-form element-type body)
  (if string-form
      (expand-with-open-stream var
                               `(progn ; element-type is ignored, but it might have side effects
                                  ,element-type
                                  (make-instance 'string-output-stream
                                                 :string (progn ,string-form)))
                               body)
      (expand-with-open-stream var
                               `(make-instance 'string-output-stream
                                               :string (make-array 8
                                                                   :element-type ,element-type
                                                                   :fill-pointer 0 :adjustable t))
                               `(,@body
                                 (copy-seq (stream-string ,var)))))))

;;; String input stream and with-input-from-string.

(defclass string-input-stream
    (string-stream character-input-mixin fundamental-character-input-stream)
  ((%start :accessor stream-file-start
           :initarg :start
           :initform 0)
   (%end :accessor stream-file-end
         :initarg :end
         :initform nil)))

(defmethod initialize-instance :after ((instance string-input-stream) &rest initargs &key)
  (declare (ignore initargs))
  (with-accessors ((position stream-file-position)
                   (start stream-file-start)
                   (end stream-file-end)
                   (string stream-string))
      instance
    (unless start
      (setf start 0))
    (unless end
      (setf end (length string)))
    (unless position
      (setf position start))))

;;; A buffered unread character precedes the stored offset in the string.
(defmethod stream-file-position :around ((instance string-input-stream))
  (let ((position (call-next-method)))
    (if (and position (previous-char instance)) (1- position) position)))

(defmethod (setf stream-file-position) :around (position (instance string-input-stream))
  (setf (previous-char instance) nil)
  (case position
    (:start
     (call-next-method (stream-file-start instance) instance))
    (:end
     (call-next-method (stream-file-end instance) instance))
    (otherwise
     (call-next-method))))

(defmethod stream-read-char ((stream string-input-stream))
  (with-accessors ((position stream-file-position)
                   (end stream-file-end)
                   (string stream-string))
      stream
    (if (< position end)
        (prog1
            (char string position)
          (incf position))
        :eof)))

(defmethod stream-peek-char ((stream string-input-stream))
  (with-accessors ((position stream-file-position)
                   (end stream-file-end)
                   (string stream-string))
      stream
    (if (< position end)
        (char string position)
        :eof)))

#+(or)(defmethod stream-read-sequence
    ((stream string-input-stream) seq &optional (start 0) end)
  (let* ((available (- (slot-value stream 'end) (slot-value stream 'start)))
         (requested (- (or end (length seq)) start))
         (provided (min available requested)))
    (replace seq (slot-value stream 'string)
             :start1 start
             :end1 (+ start provided)
             :start2 (slot-value stream 'start))
    (incf (slot-value stream 'start) provided)
    (+ start provided)))

;;; kiln: used by a macro at compile time.
(eval-when (:compile-toplevel :load-toplevel :execute)
(defun expand-with-input-from-string
    (var string start end position body)
  (if position
      (multiple-value-bind (body-forms declares)
          (alexandria:parse-body body)
        (expand-with-open-stream var
                                 `(make-instance 'string-input-stream
                                                 :string ,string
                                                 :start ,start
                                                 :end ,end)
                                 `(,@declares
                                   (multiple-value-prog1
                                       (progn ,@body-forms)
                                     (setf ,position (stream-file-position ,var))))))
      (expand-with-open-stream var
                               `(make-instance 'string-input-stream
                                               :string ,string
                                               :start ,start
                                               :end ,end)
                               body))))
