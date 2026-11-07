;;;; Heap images (docs/15): the program saves an image, and tools/test.sh
;;;; runs the executable again from it (KILN_IMAGE), and the executable
;;;; with the image appended; clos-image.image is the expected output of
;;;; those runs.

(defvar *counter* 0)
(defvar *table* (make-hash-table :test #'eq))
(defvar *equal-table* (make-hash-table :test #'equal))
(defvar *list* (list 1 2 3))
(defvar *string* (make-string 3 :initial-element #\a))
(defvar *big* (expt 3 100))
(defvar *gensym* (gensym "G"))
(defvar *dynamic* :global)

(defclass image-point ()
  ((x :initarg :x :accessor image-point-x)
   (y :initarg :y :accessor image-point-y)))

(defgeneric image-describe (thing))
(defmethod image-describe ((p image-point)) (format nil "point ~a ~a" (image-point-x p) (image-point-y p)))
(defmethod image-describe ((n integer)) (format nil "integer ~a" n))

(defstruct image-pair left right)

(defun make-counter ()
  (let ((n 0)) (lambda () (incf n))))

(defvar *closure* (make-counter))
(defvar *point* (make-instance 'image-point :x 1 :y 2))

;;; Keys: a heap symbol, a static symbol, a cons, an instance.
(setf (gethash *gensym* *table*) 'gensym
      (gethash 'car *table*) 'static
      (gethash *list* *table*) 'list
      (gethash *point* *table*) 'point
      (gethash "key" *equal-table*) 'string
      (gethash '(1 2) *equal-table*) 'list)
(funcall *closure*)
(incf *counter*)
(intern "SAVED-SYMBOL" "CL-USER")
(push (lambda () (format t "init hook~%")) kiln.sys:*init-hooks*)

(defun main ()
  (format t "restored~%")
  (format t "counter ~a~%" (incf *counter*))
  (format t "closure ~a ~a~%" (funcall *closure*) (funcall *closure*))
  (format t "eq table ~a ~a ~a ~a ~a~%"
          (gethash *gensym* *table*) (gethash 'car *table*)
          (gethash *list* *table*) (gethash *point* *table*)
          (hash-table-count *table*))
  (format t "equal table ~a ~a~%"
          (gethash (copy-seq "key") *equal-table*) (gethash (list 1 2) *equal-table*))
  (format t "list ~a string ~a big ~a~%" *list* *string* (= *big* (expt 3 100)))
  (format t "symbol ~s ~s~%" (find-symbol "SAVED-SYMBOL" "CL-USER") (symbol-package *gensym*))
  (format t "methods ~a / ~a~%" (image-describe *point*) (image-describe 42))
  (defmethod image-describe ((s string)) (format nil "string ~a" s))
  (format t "new method ~a~%" (image-describe "abc"))
  (format t "struct ~a~%" (image-pair-right (make-image-pair :left 1 :right 2)))
  (format t "new instance ~a~%" (image-describe (make-instance 'image-point :x 3 :y 4)))
  (format t "dynamic ~a ~a~%" *dynamic* (let ((*dynamic* :bound)) *dynamic*))
  ;; New objects reachable only from the image's objects survive
  ;; collections.
  (setf (gethash :fresh *table*) (list (make-string 2 :initial-element #\z)))
  (push (make-instance 'image-point :x 5 :y 6) *list*)
  (dotimes (i 20000) (make-list 50))
  (kiln.sys:%gc)
  (format t "after gc ~a ~a~%" (gethash :fresh *table*) (image-point-x (first *list*)))
  (format t "error: ~a~%" (handler-case (error "boom") (error (e) (princ-to-string e))))
  (format t "read ~s~%" (read-from-string "(a b . \"c\")"))
  ;; An image saved by a process started from one (clos-image.image2).
  (kiln.sys:save-image "clos-image-2.img" :toplevel #'main-2))

(defun main-2 ()
  (format t "second image~%")
  (format t "counter ~a~%" *counter*)
  (format t "~a ~a~%" (gethash :fresh *table*) (mapcar #'image-describe (list 7 "x" (first *list*))))
  (dotimes (i 20000) (make-list 50))
  (kiln.sys:%gc)
  (format t "~a~%" (image-point-y (first *list*))))

(let ((*dynamic* :bound-while-saving))
  (kiln.sys:save-image "clos-image.img" :toplevel #'main))
(kiln.sys:save-image "clos-image.exe" :toplevel #'main :executable t)
(format t "saved ~a~%" *counter*)
