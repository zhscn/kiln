;;; FILE-POSITION of file streams after reads, UNREAD-CHAR, writes, seeks
;;; and appends (the stream keeps the file offset instead of asking the
;;; system each time). Octets: "aé€😀" is 1 + 2 + 3 + 4 = 10 octets in UTF-8.

(defvar *path* (format nil "/tmp/kiln-file-positions-~D.txt" (random 1000000)))

(with-open-file (s *path* :direction :output :if-exists :supersede)
  (format t "~s~%" (file-position s))
  (write-string "aé€😀" s)
  (format t "~s~%" (file-position s))
  (terpri s)
  (write-string "line two" s)
  (format t "~s~%" (file-position s)))

(with-open-file (s *path*)
  (let ((positions '()))
    (dotimes (i 5)
      (read-char s)
      (push (file-position s) positions))
    (format t "~s~%" (reverse positions)))
  (let ((c (read-char s)))
    (format t "~s ~s~%" (char-code c) (file-position s))
    (unread-char c s)
    (format t "~s~%" (file-position s))
    (format t "~s ~s~%" (read-line s) (file-position s)))
  (file-position s 1)
  (format t "~s ~s~%" (char-code (read-char s)) (file-position s))
  (file-position s :start)
  (format t "~s ~s~%" (read-line s) (file-position s)))

(with-open-file (s *path* :direction :output :if-exists :append)
  (write-string "!" s)
  (format t "~s~%" (file-position s))
  (write-string "?" s)
  (format t "~s~%" (file-position s)))

(with-open-file (s *path* :direction :io :if-exists :overwrite)
  (format t "~s ~s~%" (char-code (read-char s)) (file-position s))
  (file-position s 0)
  (write-string "Z" s)
  (format t "~s~%" (file-position s))
  (format t "~s ~s~%" (char-code (read-char s)) (file-position s))
  (file-position s 0)
  (format t "~s~%" (read-line s)))

(with-open-file (s *path*)
  (format t "~s ~s~%" (read-line s) (read-line s)))
(delete-file *path*)
