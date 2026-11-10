;;; UTF-8 crosses the file buffer boundary; unread, peek and IO share state.
(let ((path (format nil "/tmp/kiln-reader-buffer-~D.txt" (random 1000000))))
  (unwind-protect
       (progn
         (with-open-file (stream path :direction :output :if-exists :supersede)
           (dotimes (i 8191) (write-char #\a stream))
           (write-string "λ
Z" stream))
         (with-open-file (stream path)
           (dotimes (i 8191) (assert (char= #\a (read-char stream))))
           (let ((char (read-char stream)))
             (print (list (char-code char) (file-position stream)))
             (unread-char char stream)
             (print (list (char-code (peek-char nil stream)) (file-position stream)))
             (print (list (char-code (read-char stream)) (file-position stream))))
           (print (char-code (read-char stream)))
           (print (char-code (read-char stream)))
           (print (read-char stream nil :eof)))
         (with-open-file (stream path :direction :io :if-exists :overwrite)
           (read-char stream)
           (write-char #\B stream)
           (file-position stream 0)
           (print (list (read-char stream) (read-char stream)))))
    (delete-file path)))
