(cl:in-package #:clostrophilia)

;;; We assume this code is executed to create functions and methods of
;;; refinement R.  These functions and methods operate on generic
;;; functions and methods of refinement R+1.
;;;
;;; They also operate on the arguments to the generic functions of
;;; refinement R+1, and these arguments are of refinement R+2.  When
;;; we need to know the classes of those arguments, we must call
;;; CLASS-OF of refinement R+1.  That function is therefore referred
;;; to here as CLASS-OF+1.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Class cache.
;;;
;;; A CLASS CACHE of a particular call to a generic function is a list
;;; of classes of the specialized required arguments passed to the
;;; generic function in that call.  The call class cache the same
;;; order as the required parameters of the generic function,
;;; independently of the argument precedence order of the function.
;;; The class cache (together with the class T for unspecialized
;;; arguments) is what is passed to
;;; COMPUTE-APPLICABLE-METHODS-USING-CLASSES in order to determine
;;; whether a list of applicable methods can be computed, using only
;;; the classes of the required arguments.
;;;
;;; For a particular call to a generic function, if the classes of the
;;; specialized required arguments correspond to the classes in a
;;; class cache, then we have already at some point determined a list
;;; of applicable methods for that call, so we do not have to compute
;;; it again.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Specializer profile.
;;;
;;; The SPECIALIZER PROFILE of a generic function is a proper list,
;;; the length of which is the number of required parameters of the
;;; generic function.  The specializer profile represents a condensed
;;; version of the information concerning the specializers of the
;;; methods of the generic function.  Each element of the specializer
;;; profile is either T or NIL.  The element is T when there exists a
;;; method on the generic function with a specializer other than the
;;; class T in the corresponding parameter position.  The element is
;;; NIL when every method on the generic function has the class T as a
;;; specializer in the corresponding parameter position.  Arguments to
;;; the generic function corresponding to a specializer profile
;;; element of NIL make no difference in determining the applicable
;;; methods for a particular call.
;;;
;;; The specializer profile must be updated when methods are added or
;;; removed from the generic function.  When a method is added, each
;;; specializer of that method which is not the class named T causes
;;; the corresponding element of the specializer profile to be set to
;;; T.  In this case, the call cache is discarded.  When a method is
;;; removed, the specializer profile is initially set to a list of a
;;; NIL elements.  Then the list of methods of the generic function is
;;; traversed and the specializer profile is updated as if each method
;;; were just added to the generic function.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Applicable method cache.
;;;
;;; An APPLICABLE METHOD CACHE of a particular call to a generic
;;; function is list of applicable methods, as returned by the generic
;;; function COMPUTE-APPLICABLE-METHODS-USING-CLASSES when called with
;;; the classes in the call profile.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Effective method cache.
;;;
;;; An EFFECTIVE METHOD CACHE for a particular applicable method cache
;;; is the result of calling the generic function
;;; COMPUTE-EFFECTIVE-METHOD, passing it the list of methods of that
;;; applicable method cache and then compiling the result in the null
;;; lexical environment.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Call cache.
;;;
;;; A CALL CACHE represents information about a particular call to a
;;; generic function.  It is represented as a proper list with at
;;; least 2 CONS cells in it, and it conceptually contains 3 items:
;;;
;;;   1. A class cache containing a list of class metaobjects, one for
;;;      each specialized required parameter, corresponding to the
;;;      classes of the arguments of the call.  This item is located
;;;      in the CAR of the list representing the call cache.
;;;
;;;   2. An effective method cache, containing the effective method
;;;      function to invoke for calls with corresponding to the
;;;      classes in the class cache.  This item is located in the
;;;      CADR of the list representing the call history entry.
;;;
;;;   3. An applicable method cache, containing a list of the
;;;      applicable methods that make up the effective method for this
;;;      call.  This item is located in the CDDR of the list
;;;      representing the call cache.

(defun make-call-cache
    (relevant-classes applicable-method-cache effective-method-cache)
  (list* relevant-classes
         effective-method-cache
         applicable-method-cache))

(defun class-cache (call-cache)
  (car call-cache))

(defun effective-method-cache (call-cache)
  (cadr call-cache))

(defun applicable-method-cache (call-cache)
  (cddr call-cache))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Call history.
;;;
;;; We maintain a CALL HISTORY for each generic function.  The call
;;; history is a proper list, each element of which is a CALL CACHE.
;;;
;;; Different call caches in one call history may share the same
;;; applicable method cache and the same effective method cache.  When
;;; a new call cache C is about to be added to the call history, the
;;; existing call history is traversed to see whether there is an
;;; existing call cache D with the same (EQUAL) applicable method
;;; cache.  In this case, C is modified before it is added so that its
;;; applicable method cache and effective method cache are set to
;;; those of D.

;;; The discriminating function does the following:
;;;
;;;   1. Compute the list of instance class numbers of the required
;;;      arguments that it was passed and for which the specializer
;;;      profile contains T.
;;;
;;;   2. Compare each one of those to pre-computed constants using a
;;;      TAGBODY form.  If there is a hit, then the corresponding
;;;      effective method is invoked and the discriminating function
;;;      returns.
;;;
;;;   3. If there is not a hit, then control is transferred to the end
;;;      of the TAGBODY form.  There, DEFAULT-DISCRIMINATING-FUNCTION
;;;      is invoked.
;;;
;;; The default discriminating function does the following:
;;;
;;;   1. Check that the instance class number of each specialized
;;;      required argument is the same as the unique number of its
;;;      class.  If it is not the case, call the generic function
;;;      UPDATE-INSTANCE-FOR-REDEFINED-CLASS on those arguments and
;;;      invoke the discriminating function again.
;;;
;;;   2. If the instances are all up-to-date, then compute a call
;;;      profile for the call by calling CLASS-OF for each required
;;;      argument and then call the generic function
;;;      COMPUTE-APPLICABLE-METHODS-USING-CLASSES with the resulting
;;;      call profile.
;;;
;;;   3. If the call in step 2 returns TRUE as a second return value,
;;;      then the first value returned represents an applicable method
;;;      cache to be stored.  If so, call the generic function
;;;      COMPUTE-EFFECTIVE-METHOD with applicable method cache, thus
;;;      computing an effective method cache.  Create a call cache
;;;      from the list computed in step 1, the applicable method
;;;      cache, and the effective method cache.  Add the computed call
;;;      cache to the call history.  Call the generic function
;;;      COMPUTE-DISCRIMINATING-FUNCTION in order to compute a new
;;;      discriminating function that takes into account the new
;;;      argument classes.  Finally, call the effective just computed
;;;      method and return the result.
;;;
;;;   4. If the call in step 2 returns FALSE as a second return value,
;;;      then instead call the generic function
;;;      COMPUTE-APPLICABLE-METHODS, passing it all the current
;;;      arguments.
;;;
;;;   5. If the call in step 4 returns a non-empty list of methods,
;;;      then call COMPUTE-EFFECTIVE-METHOD with that list.  Call the
;;;      resulting effective method and return the result.
;;;
;;;   6. If the call in step 4 returns an empty list, then call
;;;      NO-APPLICABLE-METHOD.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; How we make slot accessors fast.
;;;
;;; A slot accessor (reader or writer) generic function has methods on
;;; it that are instances of STANDARD-READER-METHOD and
;;; STANDARD-WRITER-METHOD.  Such methods have the moral meaning of
;;; (SLOT-VALUE <object> '<slot-name>) and
;;; (SETF (SLOT-VALUE <object> '<slot-name>) <new-value>)
;;; where <object> and <new-value> are arguments of the generic function
;;; and <slot-name> is the name of the slot given by applying
;;; ACCESSOR-METHOD-SLOT-DEFINITION to the method metaobject.
;;;
;;; But SLOT-VALUE and (SETF SLOT-VALUE) must do a lot of work (though
;;; it is possible to speed it up), and we want the accessor to go
;;; directly to the slot location to make it fast.  The problem with
;;; that idea is that the slot location can be different in different
;;; subclasses of the class being specialized to, as given by applying
;;; METHOD-SPECIALIZERS to the methods.  It can even be an instance
;;; slot in some subclasses and shared slot in others.
;;;
;;; We handle this situation by "cheating" in the discriminating
;;; function.  Once we have determined a list of applicable methods by
;;; calling COMPUTE-APPLICABLE-METHODS-USING-CLASSES, we make a pass
;;; over them and replace any accessor method by a newly created
;;; method that does the equivalent of (STANDARD-INSTANCE-ACCESS
;;; <object> <slot-location>), where <slot-position> is calculated by
;;; getting the name of the slot from the DIRECT-SLOT-DEFINITION
;;; stored in the accessor method, using CLASS-SLOTS on the class of
;;; <object> to find the EFFECTIVE slots of the class, then finding
;;; the slot with the right name, and finally getting its location by
;;; using SLOT-DEFINITION-LOCATION.

;;; When the applicable methods for a particular list of classes has
;;; no auxiliary methods and the most specific primary method is an
;;; accessor method, then we can create an effective method that calls
;;; STANDARD-INSTANCE-ACCESS or (SETF STANDARD-INSTANCE-ACCESS) as
;;; appropriate.  For that, we need to know the slot position of the
;;; particular slot in the class of the instance being accessed.  We
;;; do that by first finding the name of the slot in the
;;; DIRECT-SLOT-DEFINITION stored in the accessor method, using
;;; CLASS-SLOTS on the class of the instance to find the EFFECTIVE
;;; slots of the class, then finding the slot with the right name, and
;;; finally getting its location by using SLOT-DEFINITION-LOCATION.

(defun determine-slot-location (class accessor-method)
  (let* ((slot-definition (accessor-method-slot-definition accessor-method))
         (slot-name (slot-definition-name slot-definition))
         (effective-slots (class-slots class))
         (effective-slot (find slot-name effective-slots
                               :key #'slot-definition-name
                               :test #'eq)))
    (slot-definition-location effective-slot)))

;;; kiln: closures instead of compiled lambda expressions.
(defun effective-method-from-reader-method (class method)
  (let ((location (determine-slot-location class method)))
    (if (consp location)
        (lambda (instance)
          (declare (ignore instance))
          (car location))
        (lambda (instance)
          (standard-instance-access instance location)))))

(defun effective-method-from-writer-method (class method)
  (let ((location (determine-slot-location class method)))
    (if (consp location)
        (lambda (new-value instance)
          (declare (ignore instance))
          (setf (car location) new-value))
        (lambda (new-value instance)
          (setf (standard-instance-access instance location) new-value)))))

;;; kiln: effective methods are interpreted, not compiled (there is no
;;; compiler at run time yet).  EFFECTIVE-METHOD-FUNCTION turns the form
;;; returned by COMPUTE-EFFECTIVE-METHOD into a closure of one argument,
;;; the list of arguments, that does what the compiled form would do.
;;; The form is the result of WRAP-METHOD-COMBINATION-FORM; inside it,
;;; CALL-METHOD and MAKE-METHOD, the special operators PROGN,
;;; MULTIPLE-VALUE-PROG1, IF, QUOTE, the macros AND and OR, and calls to
;;; global functions are supported, which covers the standard method
;;; combination and the short forms.  Long-form DEFINE-METHOD-COMBINATION
;;; bodies that produce other code need the compiler.

(defun effective-method-body (effective-method)
  (if (and (consp effective-method)
           (eq (first effective-method) 'lambda)
           (consp (third effective-method))
           (eq (first (third effective-method)) 'macrolet)
           (consp (third (third effective-method)))
           (eq (first (third (third effective-method))) 'macrolet))
      (third (third (third effective-method)))
      (error "unsupported effective method form" effective-method)))

(defun effective-method-function (generic-function effective-method)
  (effective-method-closure
   (effective-method-body effective-method)
   (generic-function-method-class generic-function)))

(defun make-method-form-p (form)
  (and (consp form) (eq (first form) 'make-method)))

;;; The next methods of a CALL-METHOD form: MAKE-METHOD forms become
;;; methods whose function interprets the form.
(defun resolve-next-methods (next-methods method-class)
  (loop for next in next-methods
        collect
        (if (make-method-form-p next)
            (let ((closure (effective-method-closure (second next) method-class)))
              (make-method-instance method-class
                :qualifiers '()
                :lambda-list '()
                :specializers '()
                :function (lambda (arguments next-methods)
                            (declare (ignore next-methods))
                            (funcall closure arguments))))
            next)))

(defun call-method-closure (method next-methods method-class)
  (if (make-method-form-p method)
      (effective-method-closure (second method) method-class)
      ;; kiln: method functions with keyword parameters allow other keys
      ;; (kiln's method lambdas); appending :ALLOW-OTHER-KEYS T to the
      ;; arguments would show it to a &REST parameter.
      (let ((function (method-function method))
            (next-methods (resolve-next-methods next-methods method-class)))
        (lambda (arguments)
          (funcall function arguments next-methods)))))

;;; kiln: other operators that clients' method combinations use (an alist
;;; of the operator and a function of the form and a function that
;;; interprets a subform, which returns the closure).
(defvar *effective-method-operators* '())

(defun effective-method-closure (form method-class)
  (flet ((sub (form) (effective-method-closure form method-class)))
    (cond ((and (symbolp form) (not (keywordp form)) (not (member form '(t nil))))
           (error "unsupported variable in an effective method form" form))
          ((atom form)
           (lambda (arguments) (declare (ignore arguments)) form))
          (t
           (case (first form)
             (call-method
              (call-method-closure (second form) (third form) method-class))
             (quote
              (let ((object (second form)))
                (lambda (arguments) (declare (ignore arguments)) object)))
             (progn
              (if (null (rest form))
                  (lambda (arguments) (declare (ignore arguments)) nil)
                  (let ((closures (mapcar #'sub (rest form))))
                    (lambda (arguments)
                      (loop for (closure . more) on closures
                            when (null more)
                              return (funcall closure arguments)
                            do (funcall closure arguments))))))
             (multiple-value-prog1
              (let ((first (sub (second form)))
                    (closures (mapcar #'sub (rest (rest form)))))
                (lambda (arguments)
                  (multiple-value-prog1 (funcall first arguments)
                    (loop for closure in closures
                          do (funcall closure arguments))))))
             (if
              (let ((test (sub (second form)))
                    (then (sub (third form)))
                    (else (sub (fourth form))))
                (lambda (arguments)
                  (if (funcall test arguments)
                      (funcall then arguments)
                      (funcall else arguments)))))
             (and
              (cond ((null (rest form)) (sub t))
                    ((null (rest (rest form))) (sub (second form)))
                    (t (sub `(if ,(second form) (and ,@(rest (rest form))) nil)))))
             (or
              (cond ((null (rest form)) (sub nil))
                    ((null (rest (rest form))) (sub (second form)))
                    (t (let ((first (sub (second form)))
                             (rest (sub `(or ,@(rest (rest form))))))
                         (lambda (arguments)
                           (let ((value (funcall first arguments)))
                             (if value value (funcall rest arguments))))))))
             (t
              (let ((operator (first form))
                    (extension (cdr (assoc (first form) *effective-method-operators*))))
                (if extension
                    (funcall extension form #'sub)
              (let ((closures (mapcar #'sub (rest form))))
                (unless (and (symbolp operator) (fboundp operator))
                  (error "unsupported operator in an effective method form" operator))
                (lambda (arguments)
                  (apply (fdefinition operator)
                         (loop for closure in closures
                               collect (funcall closure arguments)))))))))))))

(defun final-methods (methods classes)
  (loop for method in methods
        collect (maybe-replace-method method classes)))

;;; For the specification of this generic function, see
;;; http://metamodular.com/CLOS-MOP/compute-discriminating-function.html
(defgeneric compute-discriminating-function (generic-function))

;;; This function computes a discriminating for a generic function,
;;; given the existing call history, and then it call
;;; SET-FUNCALLABLE-INSTANCE-FUNCTION in order to install that
;;; discriminating function.
(defun compute-and-install-discriminating-function (generic-function)
  (let ((df (compute-discriminating-function generic-function)))
    (set-funcallable-instance-function generic-function df)))

(defun method-equal (method1 method2)
  (or (eq method1 method2)
      (and (standard-accessor-method-p method1)
           (standard-accessor-method-p method2)
           (eql (slot-location method1)
                (slot-location method2)))))

(defun methods-equal (methods1 methods2)
  (and (small-integer= (length methods1) (length methods2))
       (every #'method-equal methods1 methods2)))

;;; This function takes a generic function, a list of classes of all
;;; the required arguments, a list of relevant classes (i.e., classes
;;; of the arguments that have parameters that are specialized upon),
;;; and a list of applicable methods.  It adds an new call cache to
;;; the call history of the generic function.  If the same (EQUAL)
;;; applicable method cache A already exists in some call cache C in
;;; the call history, then the new call cache is constructed from the
;;; list of class numbers passed as an argument, A, and the
;;; effective-method cache of C.  Otherwise the new call cache is
;;; constructed from the list of class numbers passed as an argument,
;;; the list of applicable methods passed as an argument, and a new
;;; effective method obtained by calling COMPUTE-EFFECTIVE-METHOD.
;;; Either way, we return the effective method of the new call cache.
(defun add-call-cache
    (generic-function classes relevant-classes applicable-methods)
  (let* ((call-history (call-history generic-function))
         (final-methods (final-methods applicable-methods classes))
         (call-cache (car (member final-methods call-history
                                  :key #'applicable-method-cache
                                  :test #'methods-equal)))
         (method-combination
           (generic-function-method-combination generic-function)))
    (if (null call-cache)
        ;; No call cache exists with the same applicable method cache.
        ;; We must create a new effective method.
        (let* ((effective-method
                 (compute-effective-method
                  generic-function
                  method-combination
                  final-methods))
               ;; kiln: interpreted; called with the arguments themselves
               ;; when the generic function has only required
               ;; parameters (SPREAD-ARITY).
               (effective-method-function
                 (let ((list-function
                         (effective-method-function generic-function effective-method))
                       (arity (spread-arity generic-function)))
                   (if arity
                       (spread-effective-method-function
                        generic-function arity effective-method list-function)
                       list-function))))
          ;; Add a new call cache to the call history.
          (setf (call-history generic-function)
                (cons (make-call-cache relevant-classes
                                       final-methods
                                       effective-method-function)
                      call-history))
          effective-method-function)
        ;; We already have a call cache with the same applicable
        ;; method cache.  Create an entry that reuses the existing
        ;; applicable method cache and the existing effective method.
        (let ((final-methods (applicable-method-cache call-cache))
              (effective-method-function (effective-method-cache call-cache)))
          (setf (call-history generic-function)
                (cons (make-call-cache relevant-classes
                                       final-methods
                                       effective-method-function)
                      call-history))
          effective-method-function))))

;;; This function can not itself be the discriminating function of a
;;; generic function, because it also takes the generic function
;;; itself as an argument.  However it can be called by the
;;; discriminating function, in which case the discriminating function
;;; must supply the GENERIC-FUNCTION argument either from a
;;; closed-over variable, from a compiled-in constant, or perhaps by
;;; some other mechanism.
;;; kiln: the discriminating function is not remade at each miss (that
;;; adds every entry of the call history to a new automaton, which made
;;; the misses of a generic function with N call caches cost N^3).  A
;;; miss whose classes have a call cache calls its effective method; the
;;; discriminating function is remade when the misses since it was made
;;; reach a quarter of the call history it was made from, or that history
;;; was short.  *BUILT-HISTORIES* maps a generic function to (LENGTH .
;;; MISSES): the length of that call history, and the misses since.
(defvar *built-histories* '())

(defun note-built-history (generic-function length)
  (let ((entry (assoc generic-function *built-histories* :test #'eq)))
    (if entry
        (setf (cdr entry) (cons length 0))
        (push (cons generic-function (cons length 0)) *built-histories*))))

(defun remake-discriminating-function-p (generic-function)
  (let ((entry (cdr (assoc generic-function *built-histories* :test #'eq))))
    (or (null entry)
        (< (car entry) 16)
        (>= (setf (cdr entry) (+ (cdr entry) 1))
            (+ (kiln.sys:%primop :fixnum-quotient (car entry) 4) 1)))))

(defun call-effective-method-function (generic-function function arguments)
  (if (spread-arity generic-function)
      (apply function arguments)
      (funcall function arguments)))

(defun default-discriminating-function (generic-function arguments profile)
  (let* ((required-argument-count (length profile))
         (required-arguments (subseq arguments 0 required-argument-count))
         ;; kiln: the check for obsolete instances that the comment above
         ;; describes (step 1).  The stamp of an obsolete instance is not
         ;; the unique number of its class, so no path of the automaton
         ;; matches it; it is brought up to date before dispatching again.
         (obsolete (loop for argument in required-arguments
                         for p in profile
                         thereis (and p (obsolete-instance-p argument) argument))))
    (unless (null obsolete)
      (update-obsolete-instance obsolete)
      (return-from default-discriminating-function
        (apply generic-function arguments))))
  (let* ((required-argument-count (length profile))
         (required-arguments (subseq arguments 0 required-argument-count))
         (classes (loop for argument in required-arguments
                        for p in profile
                        collect (if p
                                    (class-of+1 argument)
                                    (find-class 't))))
         (relevant-classes (loop for class in classes
                                 for p in profile
                                 when p
                                   collect class))
         (entry #-kiln (car (member relevant-classes (call-history generic-function)
                                    :key #'class-cache :test #'equal))
                ;; kiln: classes are compared by identity (EQUAL on
                ;; instances goes through TYPEP).
                #+kiln (loop for call-cache in (call-history generic-function)
                             when (loop for a in relevant-classes
                                        for b in (class-cache call-cache)
                                        always (eq a b))
                               return call-cache)))
    (unless (null entry)
      #+kiln
      (unless (remake-discriminating-function-p generic-function)
        (return-from default-discriminating-function
          (call-effective-method-function
           generic-function (effective-method-cache entry) arguments)))
      (compute-and-install-discriminating-function generic-function)
      (return-from default-discriminating-function
        (apply generic-function arguments)))
    (multiple-value-bind (applicable-methods ok)
        (compute-applicable-methods-using-classes generic-function classes)
      (when ok
        (when (null applicable-methods)
          (apply #'no-applicable-method generic-function arguments))
        (let* ((effective-method-function
                 (add-call-cache generic-function
                                 classes
                                 relevant-classes
                                 applicable-methods)))
          #+kiln
          (unless (remake-discriminating-function-p generic-function)
            (return-from default-discriminating-function
              (call-effective-method-function
               generic-function effective-method-function arguments)))
          (set-funcallable-instance-function
           generic-function
           (compute-discriminating-function generic-function))
          (return-from default-discriminating-function
            (apply generic-function arguments))))
      ;; Come here if we can't compute the applicable methods using
      ;; only the classes of the arguments.
      ;; kiln: the effective method is cached by the classes of the
      ;; arguments and, where a method has an EQL specializer, by the
      ;; argument itself if it is one of their objects (upstream computes
      ;; it at each call).
      #+kiln
      (let ((cache (eql-dispatch-cache generic-function))
            (applicable-methods
              (compute-applicable-methods generic-function arguments)))
        (when (null applicable-methods)
          (apply #'no-applicable-method generic-function arguments))
        (let* ((effective-method
                 (compute-effective-method
                  generic-function
                  (generic-function-method-combination generic-function)
                  (final-methods applicable-methods classes)))
               (list-function
                 (effective-method-function generic-function effective-method))
               (arity (spread-arity generic-function)))
          (when (< (length (cdr cache)) 256)
            (push (make-eql-dispatch-entry
                   (if arity
                       (spread-effective-method-function
                        generic-function arity effective-method list-function)
                       list-function)
                   (car cache) required-arguments profile)
                  (cdr cache)))
          (return-from default-discriminating-function
            (funcall list-function arguments))))
      (let ((applicable-methods
              (compute-applicable-methods generic-function arguments)))
        (when (null applicable-methods)
          (apply #'no-applicable-method generic-function arguments))
        (let* ((method-combination
                 (generic-function-method-combination generic-function))
               (effective-method
                 (compute-effective-method
                  generic-function
                  method-combination
                  (final-methods applicable-methods classes)))
               ;; kiln: interpreted.
               (effective-method-function
                 (effective-method-function generic-function effective-method)))
          (funcall effective-method-function arguments))))))

;;; kiln: caches of the effective methods of generic functions with EQL
;;; specializers, for the calls whose applicable methods the classes of
;;; the arguments do not determine (see DEFAULT-DISCRIMINATING-FUNCTION;
;;; upstream computes them at each call).  An alist from generic
;;; functions to (EQL-OBJECTS . ENTRIES): EQL-OBJECTS lists the objects
;;; of the EQL specializers of each required parameter, and an entry is a
;;; simple vector of the effective method function (spread, see
;;; SPREAD-ARITY, or of the list of arguments) and one specifier for each
;;; required argument: NIL for unspecialized parameters, (OBJECT) for an
;;; argument EQL to OBJECT, one of the EQL objects, and otherwise the
;;; stamp of the argument's class (the argument then is none of the EQL
;;; objects).  The discriminating function looks the entries up (see
;;; MAKE-DISCRIMINATING-CLOSURE).  Emptied by
;;; INVALIDATE-DISCRIMINATING-FUNCTION.  (Hash tables do not exist yet
;;; when this file is loaded.)
(defvar *eql-dispatch-caches* '())

(defun eql-specializer-objects (generic-function)
  (let* ((methods (%slot generic-function '%methods))
         (eql-specializer-class (find-class 'eql-specializer))
         (count (length (%slot (first methods) '%specializers))))
    (loop for i from 0 below count
          collect (loop for method in methods
                        for specializer = (nth i (%slot method '%specializers))
                        when (eq (class-of specializer) eql-specializer-class)
                          collect (%slot specializer '%object)))))

(defun eql-dispatch-cache (generic-function)
  (or (cdr (assoc generic-function *eql-dispatch-caches* :test #'eq))
      (let ((cache (cons (eql-specializer-objects generic-function) '())))
        (push (cons generic-function cache) *eql-dispatch-caches*)
        cache)))

;;; The cache of GENERIC-FUNCTION if it has methods with EQL specializers.
(defun eql-dispatch-cache-if-any (generic-function)
  (and (%slot generic-function '%methods)
       (some #'identity (eql-specializer-objects generic-function))
       (eql-dispatch-cache generic-function)))

(defun forget-eql-dispatch-cache (generic-function)
  (setf *eql-dispatch-caches*
        (remove generic-function *eql-dispatch-caches* :key #'car :test #'eq)))

;;; kiln: the discriminating function interprets the automaton instead
;;; of compiling the TAGBODY that COMPUTE-DISCRIMINATING-TAGBODY makes.  An
;;; internal state is a simple vector of triples START END TARGET, sorted
;;; by START, for the stamps START <= stamp < END (the transfer groups of
;;; MAKE-TRANSFER-GROUPS); a final state is (:FINAL . effective method).
;;; Each specialized required argument takes one transition, found by
;;; binary search; a miss calls the default discriminating function.

(defun automaton-states (info)
  ;; Returns the initial state.
  (let ((states '())
        (final-layer-p t))
    (loop for layer-info in (reverse info)
          do (loop for (name . content) in layer-info
                   do (push (cons name
                                  (if final-layer-p
                                      (cons :final content)
                                      (coerce
                                       (loop for ((start . end) . target)
                                               in (make-transfer-groups content)
                                             collect start
                                             collect end
                                             collect (cdr (assoc target states)))
                                       'simple-vector)))
                            states))
             (setf final-layer-p nil))
    (cdr (first states))))

;;; The target of the transition of STATE on STAMP, or NIL. Open-coded
;;; fixnum arithmetic: this runs at every call of a generic function.
(defmacro automaton-transition (state-form stamp-form)
  (let ((state (gensym)) (stamp (gensym)) (low (gensym)) (high (gensym))
        (middle (gensym)) (index (gensym)) (block (gensym)))
    `(let* ((,state ,state-form) (,stamp ,stamp-form) (,low 0)
            (,high (kiln.sys:%primop :fixnum-quotient (length ,state) 3)))
       (block ,block
         ;; LOW, HIGH and MIDDLE count triples; INDEX is MIDDLE's first
         ;; element.
         (loop while (< ,low ,high)
               do (let* ((,middle (kiln.sys:%primop :fixnum-quotient (+ ,low ,high) 2))
                         (,index (+ ,middle ,middle ,middle)))
                    (cond ((< ,stamp (svref ,state ,index))
                           (setf ,high ,middle))
                          ((< ,stamp (svref ,state (+ ,index 1)))
                           (return-from ,block (svref ,state (+ ,index 2))))
                          (t
                           (setf ,low (+ ,middle 1))))))
         nil))))

(defmacro argument-stamp (object-form)
  (let ((object (gensym)))
    `(let ((,object ,object-form))
       (cond ((or (kiln.sys:%primop :standard-instance-p ,object)
                  (kiln.sys:%primop :funcallable-instance-p ,object))
              (kiln.sys:%primop :standard-instance-access ,object -2))
             ;; kiln: a structure's stamp is in its layout (#(class stamp ...)).
             ((kiln.sys:%primop :structure-instance-p ,object)
              (svref (kiln.sys:%primop :structure-layout ,object) 1))
             (t (stamp+1 ,object))))))

(defun make-eql-dispatch-entry (effective-method-function objects arguments profile)
  (let ((entry (kiln.kernel::make-simple-vector (+ 1 (length profile)) nil)))
    (setf (svref entry 0) effective-method-function)
    (loop for argument in arguments
          for p in profile
          for eql-objects in objects
          for i from 1
          do (setf (svref entry i)
                   (cond ((not p) nil)
                         ((member argument eql-objects) (list argument))
                         (t (argument-stamp argument)))))
    entry))

;;; Does the specifier SPEC of an entry match ARGUMENT, whose stamp is
;;; STAMP? EQL-OBJECTS are the EQL objects of the parameter.
(defmacro eql-dispatch-match (spec-form argument stamp eql-objects)
  (let ((spec (gensym)))
    `(let ((,spec ,spec-form))
       (cond ((null ,spec) t)
             ((consp ,spec) (eql ,argument (car ,spec)))
             (t (and (eql ,stamp ,spec)
                     (not (member ,argument ,eql-objects))))))))

(defun eql-dispatch-lookup (cache arguments)
  ;; kiln: the entry found moves to the front of the list (a generic
  ;; function such as the builder protocol's RELATE, with EQL specializers
  ;; on dozens of relation kinds, scanned the whole list at each call).
  (loop for previous = nil then tail
        for tail on (cdr cache)
        for entry = (car tail)
        when (loop for argument in arguments
                   for eql-objects in (car cache)
                   for i from 1 below (length entry)
                   always (eql-dispatch-match (svref entry i) argument
                                              (argument-stamp argument) eql-objects))
          do (when previous
               (setf (cdr previous) (cdr tail)
                     (cdr tail) (cdr cache)
                     (cdr cache) tail))
             (return (svref entry 0))))

;;; kiln: generic functions whose lambda lists have only required
;;; parameters, at most six, are called without making a list of the
;;; arguments: the discriminating function has those parameters, and so
;;; do the effective method functions of their call histories.

;;; The slots are read directly (kiln's %SLOT): these functions run when
;;; a generic function misses, and the readers are generic functions.
(defun spread-arity (generic-function)
  (let ((lambda-list (%slot generic-function '%lambda-list)))
    (and (consp lambda-list)
         (<= (length lambda-list) 6)
         (loop for parameter in lambda-list
               never (member parameter lambda-list-keywords))
         (length lambda-list))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun spread-parameters (n)
    (loop for i from 0 below n
          collect (intern (format nil "A~D" i) '#:clostrophilia)))

  ;; FORM with each %ARGUMENTS in a list replaced by PARAMETERS.
  (defun splice-arguments (form parameters)
    (if (atom form)
        form
        (loop for x in form
              append (if (eq x '%arguments)
                         (copy-list parameters)
                         (list (splice-arguments x parameters)))))))

;;; (SPREAD-CASE N FORM) evaluates FORM with %ARGUMENTS spliced into the
;;; parameters A0 ... A(N-1), for N from 1 to 6.
(defmacro spread-case (n form)
  `(ecase ,n
     ,@(loop for i from 1 to 6
             collect `(,i ,(splice-arguments form (spread-parameters i))))))

(defun spread-list-function (arity list-function)
  (spread-case arity
    (lambda (%arguments) (funcall list-function (list %arguments)))))

;;; An effective method made of methods with fast functions (or accessor
;;; methods that MAYBE-REPLACE-METHOD made, which access the slot
;;; directly), combined by the standard method combination's PROGN,
;;; MULTIPLE-VALUE-PROG1, CALL-METHOD and MAKE-METHOD, is a closure of the
;;; spread arguments that calls them directly. Anything else goes through
;;; the list. (Two primary methods, a specific one and a default one, make
;;; a MULTIPLE-VALUE-PROG1 form: before this, most calls of the
;;; compiler's generic functions took the list.)
(defun spread-effective-method-function
    (generic-function arity effective-method list-function)
  (or (spread-form-closure (effective-method-body effective-method) arity
                           (generic-function-method-class generic-function))
      (spread-list-function arity list-function)))

(defun spread-form-closure (form arity method-class)
  "A function of ARITY arguments that does what the effective method FORM
does, or NIL."
  (flet ((sub (form) (spread-form-closure form arity method-class)))
    (cond ((atom form) nil)
          ((eq (first form) 'call-method)
           (let ((method (second form)))
             (if (make-method-form-p method)
                 (sub (second method))
                 (spread-method-call method
                                     (spread-next-methods (third form) arity method-class)
                                     arity))))
          ((eq (first form) 'progn)
           (let ((closures (mapcar #'sub (rest form))))
             (and closures
                  (every #'identity closures)
                  (if (null (rest closures))
                      (first closures)
                      (spread-case arity
                        (lambda (%arguments)
                          (let ((tail closures))
                            (loop (if (rest tail)
                                      (progn (funcall (first tail) %arguments)
                                             (setf tail (rest tail)))
                                      (return (funcall (first tail) %arguments)))))))))))
          ((eq (first form) 'multiple-value-prog1)
           (let ((first (sub (second form)))
                 (closures (mapcar #'sub (rest (rest form)))))
             (and first
                  (every #'identity closures)
                  (if (null closures)
                      first
                      (spread-case arity
                        (lambda (%arguments)
                          (multiple-value-prog1 (funcall first %arguments)
                            (dolist (closure closures)
                              (funcall closure %arguments)))))))))
          (t nil))))

(defun spread-next-methods (next-methods arity method-class)
  "As RESOLVE-NEXT-METHODS, and the method made for a MAKE-METHOD form has a
fast function when its form has a spread closure (CALL-NEXT-METHOD in an
:AROUND method calls it without a list)."
  (loop for next in next-methods
        collect
        (if (make-method-form-p next)
            (let ((closure (effective-method-closure (second next) method-class))
                  (spread (spread-form-closure (second next) arity method-class)))
              (apply #'make-method-instance method-class
                     :qualifiers '()
                     :lambda-list '()
                     :specializers '()
                     :function (lambda (arguments next-methods)
                                 (declare (ignore next-methods))
                                 (funcall closure arguments))
                     (and spread
                          (list :fast-function
                                (spread-case arity
                                  (lambda (next-methods %arguments)
                                    (declare (ignore next-methods))
                                    (funcall spread %arguments)))))))
            next)))

(defun spread-method-call (method next-methods arity)
  (let ((class (class-of method)))
    (cond ((and (eq class (find-class 'standard-reader-method)) (= arity 1))
           (let ((location (%slot method '%slot-location))
                 (name (%slot (%slot method '%slot-definition) '%name)))
             (if (consp location)
                 (lambda (a0) (declare (ignore a0)) (car location))
                 (note-reader-closure
                  (lambda (a0)
                    (let ((value (kiln.sys:%primop :standard-instance-access a0 location)))
                      (if (eq value +unbound-slot-value+)
                          (slot-unbound (class-of a0) a0 name)
                          value)))
                  location))))
          ((and (eq class (find-class 'standard-writer-method)) (= arity 2))
           (let ((location (%slot method '%slot-location)))
             (if (consp location)
                 (lambda (a0 a1) (declare (ignore a1)) (setf (car location) a0))
                 (lambda (a0 a1)
                   (kiln.sys:%primop :set-standard-instance-access a1 location a0)
                   a0))))
          (t
           (let ((fast (kiln.sys:%method-fast-function method)))
             (and fast
                  (spread-case arity
                    (lambda (%arguments)
                      ;; kiln: a jump, so that the method runs without
                      ;; this closure's frame.
                      (kiln.sys:%primop :tail-funcall-function
                                        fast next-methods %arguments)))))))))

(defun make-spread-discriminating-closure
    (generic-function arity profile initial eql-cache)
  (let ((p0 (nth 0 profile)) (p1 (nth 1 profile)) (p2 (nth 2 profile))
        (p3 (nth 3 profile)) (p4 (nth 4 profile)) (p5 (nth 5 profile))
        (o0 (nth 0 (car eql-cache))) (o1 (nth 1 (car eql-cache)))
        (o2 (nth 2 (car eql-cache))) (o3 (nth 3 (car eql-cache)))
        (o4 (nth 4 (car eql-cache))) (o5 (nth 5 (car eql-cache))))
    (declare (ignorable p0 p1 p2 p3 p4 p5 o0 o1 o2 o3 o4 o5))
    (macrolet ((discriminator (n)
                 (let* ((parameters (spread-parameters n))
                        (flags (subseq '(p0 p1 p2 p3 p4 p5) 0 n))
                        (objects (subseq '(o0 o1 o2 o3 o4 o5) 0 n))
                        (stamps (loop for i from 0 below n
                                      collect (intern (format nil "S~D" i)
                                                      '#:clostrophilia))))
                   `(lambda ,parameters
                      (let ((state initial))
                        ,@(loop for parameter in parameters
                                for flag in flags
                                collect `(when (and ,flag state)
                                           (setf state (automaton-transition
                                                        state (argument-stamp ,parameter)))))
                        (if (consp state)
                            (funcall (cdr state) ,@parameters)
                            (let ((function
                                    (and eql-cache
                                         (let ,(loop for stamp in stamps
                                                     for flag in flags
                                                     for parameter in parameters
                                                     collect `(,stamp (if ,flag
                                                                          (argument-stamp ,parameter)
                                                                          0)))
                                           (loop for entry in (cdr eql-cache)
                                                 when (and ,@(loop for parameter in parameters
                                                                   for stamp in stamps
                                                                   for object in objects
                                                                   for i from 1
                                                                   collect `(eql-dispatch-match
                                                                             (svref entry ,i)
                                                                             ,parameter ,stamp
                                                                             ,object)))
                                                   return (svref entry 0))))))
                              (if function
                                  (funcall function ,@parameters)
                                  (default-discriminating-function
                                   generic-function (list ,@parameters) profile)))))))))
      (ecase arity
        (1 (discriminator 1)) (2 (discriminator 2)) (3 (discriminator 3))
        (4 (discriminator 4)) (5 (discriminator 5)) (6 (discriminator 6))))))

;;; kiln: a generic function that dispatches on one of its (spread)
;;; parameters, without EQL specializers, has a discriminating closure
;;; with a direct-mapped cache: a simple vector of (stamp function) pairs,
;;; indexed by the low bits of the argument's stamp, as many pairs as the
;;; power of two at least the size of the call history (4 to 256). Stamps
;;; are consecutive class numbers. A miss takes the automaton. (A
;;; one-entry cache missed at every call of an AST walker's generic
;;; functions, which see nodes of many classes.)
(defun dispatch-cache-size (history-length)
  (let ((size 4))
    (loop while (and (< size history-length) (< size 256))
          do (setf size (+ size size)))
    size))

;;; kiln: slot readers. The effective method of a reader generic function
;;; for a class whose slot is local is a closure reading the slot's
;;; location (SPREAD-METHOD-CALL); a direct-mapped table maps such closures
;;; to their locations (a collision only loses the shortcut). The cache of
;;; a one-parameter discriminating closure then holds the location instead
;;; of the closure, and a hit reads the slot itself: one call less for each
;;; slot read through a reader.
(defvar *reader-closures* (kiln.kernel::make-simple-vector (* 2 4096) nil))

(defun reader-closure-index (closure)
  (* 2 (kiln.sys:%primop :fixnum-logand (kiln.sys:%primop :identity-hash closure) 4095)))

(defun note-reader-closure (closure location)
  (let ((index (reader-closure-index closure)))
    (setf (svref *reader-closures* index) closure
          (svref *reader-closures* (+ index 1)) location))
  closure)

(defun reader-closure-location (function)
  (let ((index (reader-closure-index function)))
    (and (eq (svref *reader-closures* index) function)
         (svref *reader-closures* (+ index 1)))))

(defun single-dispatch-miss (cache index stamp initial &optional fuse-readers)
  "The effective method function for STAMP from the automaton INITIAL,
entered in CACHE at INDEX; or NIL. Out of line, so that the
discriminating closure's hit path needs no frame for it. With
FUSE-READERS, a slot reader's closure is entered as its slot's location."
  (let ((state (automaton-transition initial stamp)))
    (if (consp state)
        (progn
          ;; The stamp last: a reader never sees it with another function.
          (setf (svref cache index) nil
                (svref cache (+ index 1)) (or (and fuse-readers
                                                   (reader-closure-location (cdr state)))
                                              (cdr state))
                (svref cache index) stamp)
          (cdr state))
        nil)))

(defmacro instance-stamp-or-nil (object)
  "OBJECT's stamp if it is a standard instance, a funcallable instance or a
structure (inline, no call); NIL for other objects."
  `(cond ((or (kiln.sys:%primop :standard-instance-p ,object)
              (kiln.sys:%primop :funcallable-instance-p ,object))
          (kiln.sys:%primop :standard-instance-access ,object -2))
         ((kiln.sys:%primop :structure-instance-p ,object)
          (svref (kiln.sys:%primop :structure-layout ,object) 1))
         (t nil)))

;;; kiln: the discriminating closure of a single-dispatch generic function
;;; is two closures. The fast one only probes the cache for an instance's
;;; stamp and tail-calls what it finds: it makes no other call, so it needs
;;; no frame of its own beyond the entry check, and the effective method
;;; runs as if called by the generic function's caller (as PCL's
;;; discriminating functions jump to the method). Everything else, other
;;; objects than instances (whose stamp takes a call), a miss and an
;;; unbound slot of a fused reader, is the slow closure, tail-called too.
(defun make-single-dispatch-closure
    (generic-function arity position profile initial history-length)
  (let* ((size (dispatch-cache-size history-length))
         (mask (- size 1))
         (cache (kiln.kernel::make-simple-vector (+ size size) nil)))
    (macrolet ((slow-dispatcher (n k)
                 (let ((parameters (spread-parameters n)))
                   `(lambda ,parameters
                      (let* ((stamp (argument-stamp ,(nth k parameters)))
                             (index (let ((i (kiln.sys:%primop :fixnum-logand stamp mask)))
                                      (+ i i))))
                        (if (eq (svref cache index) stamp)
                            (kiln.sys:%primop :tail-funcall-function
                                              (svref cache (+ index 1)) ,@parameters)
                            (let ((function (single-dispatch-miss cache index stamp initial)))
                              (if function
                                  (kiln.sys:%primop :tail-funcall-function function ,@parameters)
                                  (default-discriminating-function
                                   generic-function (list ,@parameters) profile))))))))
               (dispatcher (n k)
                 (let ((parameters (spread-parameters n)))
                   `(let ((slow (slow-dispatcher ,n ,k)))
                      (lambda ,parameters
                        (let ((stamp (instance-stamp-or-nil ,(nth k parameters))))
                          (if stamp
                              (let ((index (kiln.sys:%primop
                                            :fixnum-logand
                                            (kiln.sys:%primop :fixnum+ stamp stamp) mask2)))
                                (if (eq (kiln.sys:%primop :svref-unchecked cache index) stamp)
                                    (kiln.sys:%primop
                                     :tail-funcall-function
                                     (kiln.sys:%primop :svref-unchecked cache
                                                       (kiln.sys:%primop :fixnum+ index 1))
                                     ,@parameters)
                                    (kiln.sys:%primop :tail-funcall-function slow ,@parameters)))
                              (kiln.sys:%primop :tail-funcall-function slow ,@parameters)))))))
               (dispatchers ()
                 `(ecase arity
                    ,@(loop for n from 1 to 6
                            collect `(,n (ecase position
                                           ,@(loop for k from 0 below n
                                                   collect `(,k (dispatcher ,n ,k))))))))
               ;; One parameter: an entry may be a slot reader's location.
               (reader-dispatcher ()
                 `(let ((slow
                          (lambda (a0)
                            (let* ((stamp (argument-stamp a0))
                                   (index (let ((i (kiln.sys:%primop :fixnum-logand stamp mask)))
                                            (+ i i))))
                              (if (eq (svref cache index) stamp)
                                  (let ((entry (svref cache (+ index 1))))
                                    (if (kiln.sys:%primop :fixnump entry)
                                        (let ((value (kiln.sys:%primop :standard-instance-access a0 entry)))
                                          (if (eq value +unbound-slot-value+)
                                              (kiln.sys:%primop
                                               :tail-funcall-function
                                               (cdr (automaton-transition initial stamp)) a0)
                                              value))
                                        (kiln.sys:%primop :tail-funcall-function entry a0)))
                                  (let ((function (single-dispatch-miss cache index stamp initial t)))
                                    (if function
                                        (kiln.sys:%primop :tail-funcall-function function a0)
                                        (default-discriminating-function
                                         generic-function (list a0) profile))))))))
                    (lambda (a0)
                      (let ((stamp (instance-stamp-or-nil a0)))
                        (if stamp
                            (let ((index (kiln.sys:%primop
                                          :fixnum-logand
                                          (kiln.sys:%primop :fixnum+ stamp stamp) mask2)))
                              (if (eq (kiln.sys:%primop :svref-unchecked cache index) stamp)
                                  (let ((entry (kiln.sys:%primop
                                                :svref-unchecked cache
                                                (kiln.sys:%primop :fixnum+ index 1))))
                                    (if (kiln.sys:%primop :fixnump entry)
                                        (let ((value (kiln.sys:%primop
                                                      :standard-instance-access a0 entry)))
                                          (if (eq value +unbound-slot-value+)
                                              (kiln.sys:%primop :tail-funcall-function slow a0)
                                              value))
                                        (kiln.sys:%primop :tail-funcall-function entry a0)))
                                  (kiln.sys:%primop :tail-funcall-function slow a0)))
                            (kiln.sys:%primop :tail-funcall-function slow a0)))))))
      (let ((mask2 (+ mask mask)))
        (if (eql arity 1)
            (reader-dispatcher)
            (dispatchers))))))

(defun double-dispatch-miss (cache index s1 s2 initial)
  "As SINGLE-DISPATCH-MISS, for two stamps: entries are (S1 S2 function)."
  (let ((state (automaton-transition initial s1)))
    (when state
      (setf state (automaton-transition state s2)))
    (if (consp state)
        (progn
          ;; The first stamp last: a reader never sees a mixed entry.
          (setf (svref cache index) nil
                (svref cache (+ index 1)) s2
                (svref cache (+ index 2)) (cdr state)
                (svref cache index) s1)
          (cdr state))
        nil)))

(defun make-single-dispatch-list-closure
    (generic-function position profile initial history-length)
  ;; As MAKE-SINGLE-DISPATCH-CLOSURE, for a generic function whose lambda
  ;; list has &OPTIONAL, &REST or &KEY parameters: the effective method
  ;; function takes the argument list. (STREAM-WRITE-STRING,
  ;; SHARED-INITIALIZE and the builder protocol's RELATE took the automaton
  ;; at every call.) Too few arguments take the general way, which
  ;; signals the error.
  (let* ((size (dispatch-cache-size history-length))
         (mask (- size 1))
         (cache (kiln.kernel::make-simple-vector (+ size size) nil)))
    (lambda (&rest arguments)
      (let ((tail (nthcdr position arguments)))
        (if (null tail)
            (default-discriminating-function generic-function arguments profile)
            (let* ((stamp (argument-stamp (car tail)))
                   (index (let ((i (kiln.sys:%primop :fixnum-logand stamp mask)))
                            (+ i i))))
              (if (eq (svref cache index) stamp)
                  (funcall (svref cache (+ index 1)) arguments)
                  (let ((function (single-dispatch-miss cache index stamp initial)))
                    (if function
                        (funcall function arguments)
                        (default-discriminating-function
                         generic-function arguments profile))))))))))

(defun make-double-dispatch-closure
    (generic-function arity first second profile initial history-length)
  ;; As MAKE-SINGLE-DISPATCH-CLOSURE, for two specialized parameters,
  ;; FIRST < SECOND (SLOT-VALUE-USING-CLASS, AST walkers with a client).
  (let* ((size (dispatch-cache-size history-length))
         (mask (- size 1))
         (cache (kiln.kernel::make-simple-vector (* 3 size) nil)))
    (macrolet ((dispatcher (n j k)
                 (let ((parameters (spread-parameters n)))
                   `(lambda ,parameters
                      (let* ((s1 (argument-stamp ,(nth j parameters)))
                             (s2 (argument-stamp ,(nth k parameters)))
                             (index (* 3 (kiln.sys:%primop
                                          :fixnum-logand
                                          (kiln.sys:%primop :fixnum-logxor (+ s1 s1 s1) s2)
                                          mask))))
                        (if (and (eq (svref cache index) s1)
                                 (eq (svref cache (+ index 1)) s2))
                            (funcall (svref cache (+ index 2)) ,@parameters)
                            (let ((function (double-dispatch-miss cache index s1 s2 initial)))
                              (if function
                                  (funcall function ,@parameters)
                                  (default-discriminating-function
                                   generic-function (list ,@parameters) profile))))))))
               (dispatchers ()
                 `(ecase arity
                    ,@(loop for n from 2 to 6
                            collect `(,n (ecase first
                                           ,@(loop for j from 0 below n
                                                   collect `(,j (ecase second
                                                                  ,@(loop for k from (1+ j) below n
                                                                          collect `(,k (dispatcher ,n ,j ,k))))))))))))
      (dispatchers))))

(defun make-discriminating-closure (generic-function)
  (let* ((specializer-profile (specializer-profile generic-function))
         (active-arg-count (loop for x in specializer-profile count x))
         (call-history (call-history generic-function))
         (arity (spread-arity generic-function))
         (eql-cache (eql-dispatch-cache-if-any generic-function)))
    (note-built-history generic-function (length call-history))
    (when (and (null call-history) (null eql-cache))
      (return-from make-discriminating-closure
        (lambda (&rest arguments)
          (default-discriminating-function
           generic-function arguments (specializer-profile generic-function)))))
    (when (and call-history (small-integer= active-arg-count 0))
      (let ((effective-method (effective-method-cache (first call-history))))
        (return-from make-discriminating-closure
          (if arity
              effective-method
              (lambda (&rest arguments)
                (funcall effective-method arguments))))))
    (let ((initial
            (and call-history
                 (let ((automaton (make-automaton (1+ active-arg-count))))
                   (loop for call-cache in call-history
                         do (add-path automaton
                                      (class-cache call-cache)
                                      (effective-method-cache call-cache)))
                   (automaton-states (extract-transition-information automaton))))))
      (if arity
          (cond ((and initial (null eql-cache) (small-integer= active-arg-count 1))
                 (make-single-dispatch-closure generic-function arity
                                               (position-if #'identity specializer-profile)
                                               specializer-profile initial
                                               (length call-history)))
                ((and initial (null eql-cache) (small-integer= active-arg-count 2))
                 (let ((first (position-if #'identity specializer-profile)))
                   (make-double-dispatch-closure
                    generic-function arity first
                    (position-if #'identity specializer-profile :start (1+ first))
                    specializer-profile initial (length call-history))))
                (t
                 (make-spread-discriminating-closure
                  generic-function arity specializer-profile initial eql-cache)))
          (if (and initial (null eql-cache) (small-integer= active-arg-count 1))
              (make-single-dispatch-list-closure
               generic-function (position-if #'identity specializer-profile)
               specializer-profile initial (length call-history))
          (lambda (&rest arguments)
            (let ((state initial))
              (loop for p in specializer-profile
                    for remaining on arguments
                    when (and p state)
                      do (setf state (automaton-transition
                                      state (argument-stamp (car remaining)))))
              (if (consp state)
                  (funcall (cdr state) arguments)
                  (let ((function (and eql-cache (eql-dispatch-lookup eql-cache arguments))))
                    (if function
                        (funcall function arguments)
                        (default-discriminating-function
                         generic-function arguments specializer-profile)))))))))))

(defun make-cdr (n)
  (if (small-integer= n 0)
      'arguments
      (list 'cdr (make-cdr (1- n)))))

(defun make-car-cdr (n)
  (list 'car (make-cdr n)))

(defun make-discriminating-function-lambda (generic-function)
  (let* ((specializer-profile (specializer-profile generic-function))
         ;; We do not use the Common Lisp function COUNT here, because
         ;; we might want to define it as a generic function.
         (active-arg-count (loop for x in specializer-profile
                                 count x))
         (argument-vars (loop for x in specializer-profile
                                  when x collect (gensym)))
         (call-history (call-history generic-function)))
    ;; Check for the special case when the call history is empty.  In
    ;; that case, we just generate a call to the default
    ;; discriminating function.
    (when (null call-history)
      (return-from make-discriminating-function-lambda
        `(lambda (&rest arguments)
           (let ((profile (specializer-profile ,generic-function)))
             (default-discriminating-function ,generic-function
                                              arguments
                                              profile)))))
    ;; Come here when the call history is not empty.  Create a
    ;; dictionary, mapping effective methods to forms containing APPLY
    ;; that call those methods.
    (let ((dico '()))
      (loop for call-cache in call-history
            for effective-method = (effective-method-cache call-cache)
            do (when (null (assoc effective-method dico :test #'eq))
                 (push (cons effective-method
                             `(return-from b
                                (funcall ,effective-method arguments)))
                       dico)))
      ;; While the call history is not empty at this point, it is
      ;; possible that the ACTIVE-ARG-COUNT is 0, meaning that no
      ;; method specializes on any parameter.  In that case, the call
      ;; history contains a single entry, with the list of active
      ;; classes being empty.  So we test for that particular case,
      ;; and skip the construction of the automaton.  Instead, we just
      ;; generate a call to the only effective method in the single
      ;; entry.
      ;;
      ;; We do not use ZEROP because it may call = which is a generic
      ;; function.
      (when (small-integer= active-arg-count 0)
        (let* ((call-cache (first call-history))
               (effective-method (effective-method-cache call-cache)))
          (return-from make-discriminating-function-lambda
            `(lambda (&rest arguments)
               (funcall ,effective-method arguments)))))
      ;; Come here when there is at least one active argument, i.e. at
      ;; least one element T in the specializer profile, AND the call
      ;; history is not empty.  Create a discriminating automaton with
      ;; the entries in the call history.
      (let ((automaton (make-automaton (1+ active-arg-count))))
        (loop for call-cache in call-history
              for active-classes = (class-cache call-cache)
              for effective-method = (effective-method-cache call-cache)
              for action = (cdr (assoc effective-method dico :test #'eq))
              do (add-path automaton active-classes action))
        (let* ((info (extract-transition-information automaton))
               (tagbody (compute-discriminating-tagbody info argument-vars)))
          `(lambda (&rest arguments)
             (block b
               (let ,(loop with i = 0
                           for x in specializer-profile
                           for j from 0
                           when x
                             collect `(,(nth i argument-vars)
                                       ,(make-car-cdr j))
                             and do (incf i))
                 ,tagbody
                 (default-discriminating-function
                  ,generic-function
                  arguments
                  ',specializer-profile)))))))))

;;; This function takes a generic function an returns a discriminating
;;; function for it that has the GENERIC-FUNCTION argument compiled in
;;; as a constant, so that the discriminating function can pass the
;;; generic function to the default discriminating function.
(defun make-default-discriminating-function (generic-function)
  ;; kiln: a closure, not a compiled lambda expression.
  (make-discriminating-closure generic-function))

(defmethod compute-discriminating-function
    ((generic-function standard-generic-function))
  (make-default-discriminating-function generic-function))
