;;;; Maclina's object writer is used independently of its source reader.

(in-package #:maclina.compile-file)

(defgeneric package-name (client environment package))
(defmethod package-name (client environment package)
  (declare (ignore client environment))
  (cl:package-name package))

(defgeneric source-location-data (client source))
(defmethod source-location-data (client source)
  (declare (ignore client source))
  (values nil 0 0 0))
