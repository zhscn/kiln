;;;; Module registration and dependency loading.

(in-package #:kiln.kernel)

(defvar *modules* nil)
(defvar *module-provider-functions* nil)
(defvar *requiring-modules* nil)

(defun provide (module-name)
  (pushnew (string module-name) *modules* :test #'string=)
  t)

(defun require (module-name &optional pathnames)
  (let ((name (string module-name)))
    (when (member name *requiring-modules* :test #'string=)
      (error "Circular REQUIRE of module ~S." module-name))
    (let ((saved-modules (copy-list *modules*))
          (*requiring-modules* (cons name *requiring-modules*)))
      (unless (member name *modules* :test #'string=)
        (if pathnames
            (dolist (pathname (if (listp pathnames) pathnames (list pathnames)))
              (load pathname))
            (unless (some (lambda (provider) (funcall provider module-name))
                          *module-provider-functions*)
              (error "Do not know how to REQUIRE module ~S." module-name))))
      (set-difference *modules* saved-modules))))
