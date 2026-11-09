;;;; Pathnames: physical pathnames with Unix namestrings
;;;; (parsed like SBCL), logical pathnames, wildcards, and the file system
;;;; functions, through the runtime's file system calls (%PRIMOP :SYS,
;;;; kiln_rt_sys).
;;;;
;;;; A pathname is a standard object of a class with the built-in class
;;;; PATHNAME (or LOGICAL-PATHNAME) as a superclass, as Regalia's arrays.
;;;; Components: the host is NIL for physical pathnames and the host's
;;;; name for logical ones. The device is NIL for physical pathnames and
;;;; :UNSPECIFIC for logical ones. A name or type with a * in it is a wildcard pattern; a directory is a list (:ABSOLUTE or
;;;; :RELATIVE, then strings, :WILD, :WILD-INFERIORS, :UP, :BACK or :HOME).

(in-package #:kiln.kernel)

;;; Set once the file system functions are defined (at the end).
(defvar *default-pathname-defaults*)

(defclass pathname-components (standard-object pathname)
  ((%host :initarg :host :initform nil :reader %host)
   (%device :initarg :device :initform nil :reader %device)
   (%directory :initarg :directory :initform nil :reader %directory)
   (%name :initarg :name :initform nil :reader %name)
   (%type :initarg :type :initform nil :reader %type)
   (%version :initarg :version :initform nil :reader %version)))

(defclass physical-pathname (pathname-components) ())

(defclass logical-pathname-object (pathname-components logical-pathname) ())

(defun make-pathname-object (logicalp host device directory name type version)
  (make-instance (if logicalp 'logical-pathname-object 'physical-pathname)
                 :host host :device (if logicalp :unspecific device) :directory directory
                 :name name :type type :version version))

(defun logical-pathname-p (object)
  (typep object 'logical-pathname-object))

(defun pathnamep (object)
  (typep object 'pathname-components))

(defun pathname-components-equal (a b)
  (and (pathnamep a) (pathnamep b)
       (eq (logical-pathname-p a) (logical-pathname-p b))
       (equal (%host a) (%host b))
       (equal (%device a) (%device b))
       (equal (%directory a) (%directory b))
       (equal (%name a) (%name b))
       (equal (%type a) (%type b))
       (or (equal (%version a) (%version b))
           (and (not (logical-pathname-p a))
                (member (%version a) '(nil :newest :unspecific))
                (member (%version b) '(nil :newest :unspecific))))))

(setf *instance-equal* #'pathname-components-equal)

;;; Case (CLHS 19.2.2.1.2): the customary case of Unix is lower case, of
;;; logical pathnames upper case.

(defun common-case (string logicalp)
  "STRING in the :COMMON case convention, converted to or from the local
one: a string all in one case gets the other."
  (cond ((not (stringp string)) string)
        (logicalp string)
        ((every (lambda (c) (not (lower-case-p c))) string) (string-downcase string))
        ((every (lambda (c) (not (upper-case-p c))) string) (string-upcase string))
        (t string)))

(defun component-case (component logicalp case)
  (if (eq case :common)
      (if (consp component)
          (mapcar (lambda (c) (common-case c logicalp)) component)
          (common-case component logicalp))
      component))

(macrolet ((define-accessor (name reader)
             `(defun ,name (pathname &key (case :local))
                (let ((p (pathname pathname)))
                  (component-case (,reader p) (logical-pathname-p p) case)))))
  (define-accessor pathname-host %host)
  (define-accessor pathname-device %device)
  (define-accessor pathname-directory %directory)
  (define-accessor pathname-name %name))

(defun pathname-type (pathname &key (case :local))
  (let ((p (pathname pathname)))
    (component-case (%type p) (logical-pathname-p p) case)))

(defun pathname-version (pathname)
  (%version (pathname pathname)))

;;; Strings, as the runtime takes and gives them: UTF-8 octets in simple
;;; vectors.

(defun string-octets (string)
  (let ((octets '()))
    (dotimes (i (length string))
      (let ((code (char-code (char string i))))
        (cond ((< code #x80) (push code octets))
              ((< code #x800)
               (push (logior #xc0 (ash code -6)) octets)
               (push (logior #x80 (logand code #x3f)) octets))
              ((< code #x10000)
               (push (logior #xe0 (ash code -12)) octets)
               (push (logior #x80 (logand (ash code -6) #x3f)) octets)
               (push (logior #x80 (logand code #x3f)) octets))
              (t
               (push (logior #xf0 (ash code -18)) octets)
               (push (logior #x80 (logand (ash code -12) #x3f)) octets)
               (push (logior #x80 (logand (ash code -6) #x3f)) octets)
               (push (logior #x80 (logand code #x3f)) octets)))))
    (let* ((n (length octets))
           (vector (make-simple-vector n 0)))
      (dolist (octet octets vector)
        (setf n (- n 1))
        (setf (svref vector n) octet)))))

(defun octets-string (vector start end)
  (let ((chars '())
        (i start))
    (loop while (< i end)
          do (let* ((b (svref vector i))
                    (n (cond ((< b #x80) 0) ((< b #xe0) 1) ((< b #xf0) 2) (t 3)))
                    (code (if (zerop n) b (logand b (ash #x3f (- n))))))
               (dotimes (k n)
                 (setf code (logior (ash code 6) (logand (svref vector (+ i k 1)) #x3f))))
               (push (code-char code) chars)
               (setf i (+ i n 1))))
    (coerce (nreverse chars) 'string)))

(defun sys (op &optional (a 0) (b 0) (c 0))
  (kiln.sys:%primop :sys op a b c))

(defun sys-string (op a)
  "The string that the call OP stores, or the negative result."
  (let ((size 256))
    (loop
      (let* ((buffer (make-simple-vector size 0))
             (n (if (eql op 8) (sys op buffer) (sys op a buffer))))
        (cond ((minusp n) (return n))
              ((<= n size) (return (octets-string buffer 0 n)))
              (t (setf size n)))))))

(defun errno-message (errno)
  (let ((message (sys-string 13 errno)))
    (if (stringp message) message (format nil "error ~d" errno))))

(defun file-system-error (pathname errno)
  (error 'cyclosis::open-fail :pathname pathname :message (errno-message (- errno))))

;;; Parsing

(defun split-string (string separator start end)
  "The substrings of STRING between START and END separated by SEPARATOR."
  (let ((parts '()))
    (loop (let ((p (position separator string :start start :end end)))
            (push (subseq string start (or p end)) parts)
            (if p (setf start (+ p 1)) (return (nreverse parts)))))))

(defun wild-component (string)
  (cond ((string= string "*") :wild)
        (t string)))

(defun parse-physical-namestring (string start end)
  (let* ((slash (position #\/ string :start start :end end :from-end t))
         (directory
           (when slash
             (let ((parts (remove "" (split-string string #\/ start slash) :test #'string=))
                   (absolute (and (< start end) (char= (char string start) #\/))))
               (cond ((and (not absolute) parts (string= (first parts) "~"))
                      (list* :absolute :home (mapcar #'directory-component (rest parts))))
                     (t
                      (cons (if absolute :absolute :relative)
                            (mapcar #'directory-component parts)))))))
         (file-start (if slash (+ slash 1) start))
         (name nil)
         (type nil))
    (when (< file-start end)
      (let ((file (subseq string file-start end)))
        (if (or (string= file ".") (string= file ".."))
            (setf name file)
            (let ((dot (position #\. file :from-end t)))
              (if (and dot (plusp dot))
                  (setf name (wild-component (subseq file 0 dot))
                        type (wild-component (subseq file (+ dot 1))))
                  (setf name (wild-component file)))))))
    (make-pathname-object nil nil nil directory name type (if name :newest nil))))

(defun directory-component (string)
  (cond ((string= string "..") :up)
        ((string= string "*") :wild)
        ((string= string "**") :wild-inferiors)
        (t string)))

;;; Logical pathnames (CLHS 19.3): HOST:[;]{DIRECTORY;}*[NAME[.TYPE[.VERSION]]],
;;; read in upper case.

(defvar *logical-hosts* '())             ; (host-name . translations)

(defun logical-host-entry (host)
  (assoc host *logical-hosts* :test #'string-equal))

(defun logical-word (string)
  (cond ((string= string "*") :wild)
        ((string= string "**") :wild-inferiors)
        (t (string-upcase string))))

(defun parse-logical-namestring (string start end host)
  (let* ((colon (position #\: string :start start :end end))
         (host (if colon (string-upcase (subseq string start colon)) host))
         (start (if colon (+ colon 1) start))
         (semicolon (position #\; string :start start :end end :from-end t))
         (directory
           (if semicolon
             (let ((relative (char= (char string start) #\;)))
               (cons (if relative :relative :absolute)
                     (mapcar (lambda (word)
                               (if (string= word "..") :back (logical-word word)))
                             (remove "" (split-string string #\; start semicolon)
                                     :test #'string=))))
             '(:absolute)))
         (file-start (if semicolon (+ semicolon 1) start))
         (parts (if (< file-start end) (split-string string #\. file-start end) '()))
         (name (and parts (logical-word (first parts))))
         (type (and (rest parts) (logical-word (second parts))))
         (version (and (cddr parts)
                       (let ((v (third parts)))
                         (cond ((string= v "*") :wild)
                               ((string-equal v "NEWEST") :newest)
                               (t (parse-integer v)))))))
    (make-pathname-object t host nil directory name type version)))

(defun logical-namestring-p (string start end)
  (let ((colon (position #\: string :start start :end end)))
    (and colon (logical-host-entry (subseq string start colon)))))

(defun parse-namestring (thing &optional host (defaults *default-pathname-defaults*)
                         &key (start 0) end junk-allowed)
  (declare (ignore junk-allowed))
  (cond ((pathnamep thing) (values thing start))
        ((streamp thing) (values (pathname thing) start))
        (t
         (let* ((string (string thing))
                (end (or end (length string)))
                (logical-host (cond ((stringp host) host)
                                    ((pathnamep host) nil)
                                    ((and (null host) (logical-pathname-p defaults)
                                          (not (find #\/ string :start start :end end)))
                                     (%host defaults)))))
           (values (if (or logical-host (logical-namestring-p string start end))
                       (parse-logical-namestring string start end logical-host)
                       (parse-physical-namestring string start end))
                   end)))))

(defmethod pathname ((pathspec pathname)) pathspec)
(defmethod pathname ((pathspec string)) (values (parse-namestring pathspec)))
(defmethod pathname ((pathspec synonym-stream))
  (handler-case (pathname (symbol-value (synonym-stream-symbol pathspec)))
    (type-error (condition)
      (error 'type-error :datum pathspec
             :expected-type (type-error-expected-type condition)))))

(defun logical-pathname (pathspec)
  (when (and (stringp pathspec)
             (not (logical-namestring-p pathspec 0 (length pathspec))))
    (error 'type-error :datum pathspec :expected-type 'logical-pathname))
  (let ((p (if (stringp pathspec)
               (parse-logical-namestring pathspec 0 (length pathspec) nil)
               (pathname pathspec))))
    (unless (logical-pathname-p p)
      (error 'type-error :datum p :expected-type 'logical-pathname))
    p))

;;; Namestrings

(defun component-string (component)
  (case component
    ((:wild) "*")
    ((:wild-inferiors) "**")
    ((:up :back) "..")
    ((:home) "~")
    (t component)))

(defun directory-namestring (pathname)
  (let ((p (pathname pathname)))
    (with-output-to-string (s)
      (let ((directory (%directory p)))
        (if (logical-pathname-p p)
            (progn
              (when (eq (first directory) :relative) (write-char #\; s))
              (dolist (c (rest directory))
                (write-string (component-string c) s)
                (write-char #\; s)))
            (progn
              (when (and (eq (first directory) :absolute)
                         (not (eq (second directory) :home)))
                (write-char #\/ s))
              (dolist (c (rest directory))
                (write-string (component-string c) s)
                (write-char #\/ s))))))))

(defun file-namestring (pathname)
  (let ((p (pathname pathname)))
    (with-output-to-string (s)
      (when (%name p) (write-string (component-string (%name p)) s))
      (when (%type p)
        (write-char #\. s)
        (write-string (component-string (%type p)) s))
      (when (and (logical-pathname-p p) (%type p) (%version p))
        (write-char #\. s)
        (case (%version p)
          (:wild (write-char #\* s))
          (:newest (write-string "NEWEST" s))
          (t (format s "~d" (%version p))))))))

(defun host-namestring (pathname)
  (let ((p (pathname pathname)))
    (if (logical-pathname-p p) (%host p) "")))

(defun namestring (pathname)
  (let ((p (pathname pathname)))
    (concatenate 'string
                 (if (logical-pathname-p p) (concatenate 'string (%host p) ":") "")
                 (directory-namestring p)
                 (file-namestring p))))

(defun enough-namestring (pathname &optional (defaults *default-pathname-defaults*))
  (let* ((p (pathname pathname))
         (d (pathname defaults))
         (directory (%directory p))
         (default-directory (%directory d)))
    (if (and (equal (%host p) (%host d))
             (eq (first directory) :absolute)
             (eq (first default-directory) :absolute)
             (<= (length default-directory) (length directory))
             (equal default-directory (subseq directory 0 (length default-directory))))
        (namestring (make-pathname-object
                     (logical-pathname-p p) nil nil
                     (let ((rest (nthcdr (length default-directory) directory)))
                       (and rest (cons :relative rest)))
                     (%name p) (%type p) nil))
        (namestring p))))

;;; Construction and merging

(defun canonical-directory (directory)
  (cond ((null directory) nil)
        ((stringp directory) (list :absolute directory))
        ((eq directory :wild) (list :absolute :wild-inferiors))
        (t directory)))

(defun make-pathname (&key (host nil hostp) (device nil devicep) (directory nil directoryp)
                        (name nil namep) (type nil typep) (version nil versionp)
                        defaults (case :local))
  (let* ((d (and defaults (pathname defaults)))
         (host (if hostp host (and d (%host d))))
         (logicalp (if hostp (and (stringp host) (logical-host-entry host) t)
                       (and d (logical-pathname-p d)))))
    (flet ((component (suppliedp value reader)
             (component-case (if suppliedp value (and d (funcall reader d))) logicalp case)))
      (make-pathname-object
       logicalp host
       (component devicep device #'%device)
       (canonical-directory (component directoryp directory #'%directory))
       (component namep name #'%name)
       (component typep type #'%type)
       (if versionp version (and d (%version d)))))))

(defun collapse-back (directory)
  "DIRECTORY without the components that :BACK removes."
  (let ((result '()))
    (dolist (c directory (nreverse result))
      (if (and (eq c :back) result (stringp (first result)))
          (pop result)
          (push c result)))))

(defun merge-pathnames (pathname &optional (defaults *default-pathname-defaults*)
                                   (default-version :newest))
  (let* ((d (pathname defaults))
         (p (if (pathnamep pathname)
                pathname
                (parse-namestring pathname nil d)))
         (directory (%directory p))
         (default-directory (%directory d)))
    (make-pathname-object
     (or (logical-pathname-p p) (and (null (%host p)) (logical-pathname-p d)))
     (or (%host p) (%host d))
     (or (%device p) (%device d))
     (cond ((null directory) default-directory)
           ((and (eq (first directory) :relative) default-directory)
            (collapse-back (append default-directory (rest directory))))
           (t directory))
     (or (%name p) (%name d))
     (or (%type p) (%type d))
     (cond ((%version p))
           ((%name p) default-version)
           (t (or (%version d) default-version))))))

;;; Wildcards

(defun wild-component-p (component)
  (or (and (member component '(:wild :wild-inferiors)) t)
      (and (stringp component) (find #\* component) t)))

(defun wild-pathname-p (pathname &optional field-key)
  (let ((p (pathname pathname)))
    (flet ((wild (field)
             (case field
               (:host nil)
               (:device nil)
               (:directory (some #'wild-component-p (rest (%directory p))))
               (:name (wild-component-p (%name p)))
               (:type (wild-component-p (%type p)))
               (:version (eq (%version p) :wild)))))
      (if field-key
          (wild field-key)
          (some #'wild '(:directory :name :type :version))))))

(defun match-glob (pattern string)
  "The substrings of STRING that the *s of PATTERN match, or :FAIL."
  (labels ((walk (p s)
             (cond ((= p (length pattern))
                    (if (= s (length string)) '() :fail))
                   ((char= (char pattern p) #\*)
                    (loop for e from (length string) downto s
                          do (let ((rest (walk (+ p 1) e)))
                               (unless (eq rest :fail)
                                 (return (cons (subseq string s e) rest))))
                          finally (return :fail)))
                   ((and (< s (length string)) (char= (char pattern p) (char string s)))
                    (walk (+ p 1) (+ s 1)))
                   (t :fail))))
    (walk 0 0)))

(defun match-component (pattern component)
  "The pieces of COMPONENT that the wildcards of PATTERN match, or :FAIL."
  (cond ((or (null pattern) (eq pattern :wild)) (list component))
        ((and (stringp pattern) (find #\* pattern))
         (if (stringp component) (match-glob pattern component) :fail))
        ((equal pattern component) '())
        (t :fail)))

(defun match-directory (pattern directory)
  "The pieces of DIRECTORY that the wildcards of PATTERN match (a list for
each :WILD-INFERIORS), or :FAIL."
  (cond ((null pattern) (list directory))
        ((null directory) :fail)
        ((not (eq (first pattern) (first directory))) :fail)
        (t
         (labels ((walk (ps cs)
                    (cond ((null ps) (if (null cs) '() :fail))
                          ((eq (first ps) :wild-inferiors)
                           (loop for n from (length cs) downto 0
                                 do (let ((rest (walk (rest ps) (nthcdr n cs))))
                                      (unless (eq rest :fail)
                                        (return (cons (subseq cs 0 n) rest))))
                                 finally (return :fail)))
                          ((null cs) :fail)
                          (t (let ((here (match-component (first ps) (first cs))))
                               (if (eq here :fail)
                                   :fail
                                   (let ((rest (walk (rest ps) (rest cs))))
                                     (if (eq rest :fail) :fail (append here rest)))))))))
           (walk (rest pattern) (rest directory))))))

(defun pathname-match-p (pathname wildcard)
  (let ((p (pathname pathname))
        (w (pathname wildcard)))
    (and (not (eq (match-directory (%directory w) (%directory p)) :fail))
         (not (eq (match-component (%name w) (%name p)) :fail))
         (not (eq (match-component (%type w) (%type p)) :fail))
         (or (member (%version w) '(nil :wild :newest))
             (eql (%version w) (%version p)))
         t)))

(defun fill-component (to pieces source)
  "TO with its wildcards replaced by PIECES; the second value is the
pieces left."
  (cond ((or (null to) (eq to :wild))
         (if pieces (values (first pieces) (rest pieces)) (values source pieces)))
        ((and (stringp to) (find #\* to))
         (values (with-output-to-string (s)
                   (loop for c across to
                         do (if (char= c #\*)
                                (let ((piece (pop pieces)))
                                  (when (stringp piece) (write-string piece s)))
                                (write-char c s))))
                 pieces))
        (t (values to pieces))))

(defun translate-pathname (source from-wildcard to-wildcard &key)
  (let* ((source (pathname source))
         (from (pathname from-wildcard))
         (to (pathname to-wildcard))
         (directory-pieces (match-directory (%directory from) (%directory source)))
         (name-pieces (match-component (%name from) (%name source)))
         (type-pieces (match-component (%type from) (%type source))))
    (when (or (eq directory-pieces :fail) (eq name-pieces :fail) (eq type-pieces :fail))
      (error "~s does not match ~s" source from))
    (let ((directory
            (if (null (%directory to))
                (%directory source)
                (cons (first (%directory to))
                      (loop for c in (rest (%directory to))
                            append (cond ((eq c :wild-inferiors)
                                          (let ((piece (pop directory-pieces)))
                                            (if (listp piece) piece (list piece))))
                                         ((wild-component-p c)
                                          (list (fill-component c (list (pop directory-pieces)) nil)))
                                         (t (list c))))))))
      (make-pathname-object
       (logical-pathname-p to) (%host to) (%device to)
       (if (logical-pathname-p to)
           directory
           (cons (first directory)
                 (mapcar (lambda (c) (if (stringp c) (string-downcase-if-logical c source) c))
                         (rest directory))))
       (casefix (fill-component (%name to) name-pieces (%name source)) source to)
       (casefix (fill-component (%type to) type-pieces (%type source)) source to)
       (if (member (%version to) '(nil :wild)) (%version source) (%version to))))))

;;; Translating a logical pathname to a physical one makes the pieces lower
;;; case (logical pathnames are in upper case, Unix names usually not).
(defun string-downcase-if-logical (string source)
  (if (logical-pathname-p source) (string-downcase string) string))

(defun casefix (component source to)
  (if (and (stringp component) (logical-pathname-p source) (not (logical-pathname-p to)))
      (string-downcase component)
      component))

(defun logical-pathname-translations (host)
  (let ((entry (logical-host-entry host)))
    (unless entry
      (error "No logical host ~s" host))
    (cdr entry)))

(defun (setf logical-pathname-translations) (translations host)
  (let* ((host (string-upcase (string host)))
         (entry (or (logical-host-entry host)
                    (let ((entry (cons host '())))
                      (push entry *logical-hosts*)
                      entry))))
    (setf (cdr entry)
          (mapcar (lambda (translation)
                    (list (let ((from (first translation)))
                            (if (stringp from)
                                (parse-logical-namestring from 0 (length from) host)
                                from))
                          (pathname (second translation))))
                  translations))
    translations))

(defun load-logical-pathname-translations (host)
  (if (logical-host-entry host)
      nil
      (error "No translations for the logical host ~s" host)))

(defun translate-logical-pathname (pathname &key)
  (let ((p (pathname pathname)))
    (if (logical-pathname-p p)
        (dolist (translation (logical-pathname-translations (%host p))
                             (error 'file-error :pathname p))
          (when (pathname-match-p p (first translation))
            (return (translate-logical-pathname
                     (translate-pathname p (first translation) (second translation))))))
        p)))

;;; The file system

(defun user-homedir-pathname (&optional host)
  (declare (ignore host))
  (let ((home (sys-string 10 (string-octets "HOME"))))
    (if (stringp home)
        (parse-namestring (if (and (plusp (length home))
                                   (char= (char home (- (length home) 1)) #\/))
                              home
                              (concatenate 'string home "/")))
        nil)))

(defun current-directory ()
  (let ((cwd (concatenate 'string (sys-string 8 0) "/")))
    (parse-physical-namestring cwd 0 (length cwd))))

(setf *default-pathname-defaults* (current-directory))

(defun native-namestring (pathname)
  "The Unix file name of PATHNAME, merged with *DEFAULT-PATHNAME-DEFAULTS*."
  (let ((p (translate-logical-pathname (merge-pathnames pathname))))
    (when (wild-pathname-p p)
      (error 'file-error :pathname p))
    (let ((directory (%directory p)))
      (if (eq (second directory) :home)
          (concatenate 'string
                       (directory-namestring (user-homedir-pathname))
                       (directory-namestring
                        (make-pathname-object nil nil nil (cons :relative (cddr directory))
                                              nil nil nil))
                       (file-namestring p))
          (concatenate 'string (directory-namestring p) (file-namestring p))))))

(defun native-octets (pathname)
  (string-octets (native-namestring pathname)))

(defun file-kind (pathname)
  "NIL, :FILE, :DIRECTORY or :SPECIAL."
  (case (sys 7 (native-octets pathname) 0)
    (1 :file) (2 :directory) (3 :special) (t nil)))

(defun as-directory (pathname)
  "PATHNAME with its name and type as the last directory component."
  (let ((p (pathname pathname)))
    (if (or (%name p) (%type p))
        (make-pathname-object nil nil nil
                              (append (or (%directory p) (list :relative))
                                      (list (file-namestring p)))
                              nil nil nil)
        p)))

(defun probe-file (pathspec)
  (let* ((p (merge-pathnames pathspec))
         (real (sys-string 9 (native-octets p))))
    (cond ((not (stringp real)) nil)
          ((eq (file-kind real) :directory)
           (as-directory (parse-namestring real)))
          (t (parse-namestring real)))))

(defmethod truename ((pathspec pathname))
  (or (probe-file pathspec)
      (error 'cyclosis:file-does-not-exist :pathname pathspec)))

(defmethod truename ((pathspec string))
  (truename (pathname pathspec)))

(defun file-write-date (pathspec)
  (let ((seconds (sys 7 (native-octets pathspec) 2)))
    (if (minusp seconds)
        nil
        ;; Universal time of 1970-01-01T00:00:00Z.
        (+ seconds 2208988800))))

(defun file-author (pathspec)
  (let* ((path (pathname pathspec))
         (author (sys-string 21 (native-octets path))))
    (cond ((not (stringp author)) (file-system-error path author))
          ((zerop (length author)) (error "No account for the owner of ~S." path))
          (t author))))

(defun delete-file (filespec)
  (let* ((p (merge-pathnames filespec))
         (r (sys 3 (native-octets p))))
    (when (minusp r)
      (file-system-error p r))
    t))

(defun rename-file (filespec new-name)
  (let* ((old (merge-pathnames filespec))
         (old-truename (truename old))
         (new (merge-pathnames new-name old))
         (r (sys 4 (native-octets old) (native-octets new))))
    (when (minusp r)
      (file-system-error old r))
    (values new old-truename (truename new))))

(defun ensure-directories-exist (pathspec &key verbose)
  (declare (ignore verbose))
  (let* ((p (merge-pathnames pathspec))
         (directory (%directory (translate-logical-pathname p)))
         (created nil))
    (loop for n from 2 to (length directory)
          do (let ((d (make-pathname-object nil nil nil (subseq directory 0 n) nil nil nil)))
               (unless (file-kind d)
                 (let ((r (sys 5 (native-octets d) #o777)))
                   (when (minusp r)
                     (file-system-error d r))
                   (setf created t)))))
    (values pathspec created)))

(defun directory-entries (directory)
  "The names in the directory pathname DIRECTORY."
  (let ((size 4096))
    (loop
      (let* ((buffer (make-simple-vector size 0))
             (n (sys 11 (native-octets directory) buffer)))
        (cond ((minusp n) (return '()))
              ((> n size) (setf size n))
              (t (return (let ((names '()) (start 0))
                           (dotimes (i n (nreverse names))
                             (when (zerop (svref buffer i))
                               (push (octets-string buffer start i) names)
                               (setf start (+ i 1))))))))))))

(defun check-directory-list (dir pathspec)
  (when (consp dir)
    (when (and (eq (first dir) :absolute)
               (member (second dir) '(:up :back)))
      (error 'file-error :pathname pathspec))
    (loop for (a b) on (rest dir)
          when (and (eq a :wild-inferiors) (member b '(:up :back)))
            do (error 'file-error :pathname pathspec))))

(defun directory (pathspec &key)
  "The pathnames of the files and directories that match PATHSPEC;
directories are in directory form. Symbolic links are not resolved."
  (check-directory-list (pathname-directory pathspec) pathspec)
  (let* ((pattern (translate-logical-pathname (merge-pathnames pathspec)))
         (results '()))
    (check-directory-list (%directory pattern) pattern)
    (labels ((sub (directory name)
               (append directory (list name)))
             (files (directory)
               (dolist (entry (directory-entries
                               (make-pathname-object nil nil nil directory nil nil nil)))
                 (let* ((file (parse-physical-namestring entry 0 (length entry)))
                        (kind (file-kind (make-pathname-object nil nil nil directory
                                                               (%name file) (%type file) nil))))
                   (when (and (not (eq (match-component (%name pattern) (%name file)) :fail))
                              (not (eq (match-component (%type pattern) (%type file)) :fail)))
                     (push (if (eq kind :directory)
                               (make-pathname-object nil nil nil (sub directory entry) nil nil nil)
                               (make-pathname-object nil nil nil directory
                                                     (%name file) (%type file) :newest))
                           results)))))
             (subdirectories (directory)
               (loop for entry in (directory-entries
                                   (make-pathname-object nil nil nil directory nil nil nil))
                     when (eq (file-kind (make-pathname-object nil nil nil (sub directory entry)
                                                               nil nil nil))
                              :directory)
                       collect entry))
             (walk (directory rest)
               (cond ((null rest)
                      (if (or (%name pattern) (%type pattern))
                          (files directory)
                          (when (file-kind (make-pathname-object nil nil nil directory nil nil nil))
                            (push (make-pathname-object nil nil nil directory nil nil nil)
                                  results))))
                     ((eq (first rest) :wild-inferiors)
                      (walk directory (rest rest))
                      (dolist (entry (subdirectories directory))
                        (walk (sub directory entry) rest)))
                     ((wild-component-p (first rest))
                      (dolist (entry (subdirectories directory))
                        (unless (eq (match-component (first rest) entry) :fail)
                          (walk (sub directory entry) (rest rest)))))
                     (t (walk (sub directory (first rest)) (rest rest))))))
      (let ((directory (%directory pattern)))
        (walk (list (first directory)) (rest directory))))
    (sort (remove-duplicates results :test #'equal) #'string< :key #'namestring)))
