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

(defun effective-method-function (generic-function effective-method)
  (let ((form (if (and (consp effective-method)
                       (eq (first effective-method) 'lambda)
                       (consp (third effective-method))
                       (eq (first (third effective-method)) 'macrolet)
                       (consp (third (third effective-method)))
                       (eq (first (third (third effective-method))) 'macrolet))
                  (third (third (third effective-method)))
                  (error "unsupported effective method form" effective-method))))
    (effective-method-closure
     form (generic-function-method-class generic-function))))

(defun make-method-form-p (form)
  (and (consp form) (eq (first form) 'make-method)))

(defun call-method-closure (method next-methods method-class)
  (if (make-method-form-p method)
      (effective-method-closure (second method) method-class)
      (let ((function (method-function method))
            (keyp (member '&key (method-lambda-list method)))
            (next-methods
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
                        next))))
        (if keyp
            (lambda (arguments)
              (funcall function (append arguments '(:allow-other-keys t)) next-methods))
            (lambda (arguments)
              (funcall function arguments next-methods))))))

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
                    (closures (mapcar #'sub (rest form))))
                (unless (and (symbolp operator) (fboundp operator))
                  (error "unsupported operator in an effective method form" operator))
                (lambda (arguments)
                  (apply (fdefinition operator)
                         (loop for closure in closures
                               collect (funcall closure arguments)))))))))))

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
               ;; kiln: interpreted.
               (effective-method-function
                 (effective-method-function generic-function effective-method)))
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
         (entry (car (member relevant-classes (call-history generic-function)
                             :key #'class-cache :test #'equal))))
    (unless (null entry)
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
          (set-funcallable-instance-function
           generic-function
           (compute-discriminating-function generic-function))
          (return-from default-discriminating-function
            (apply generic-function arguments))))
      ;; Come here if we can't compute the applicable methods using
      ;; only the classes of the arguments.
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

;;; kiln: the discriminating function interprets the automaton instead
;;; of compiling the TAGBODY that COMPUTE-DISCRIMINATING-TAGBODY makes.  An
;;; internal state is a simple vector of entries (START END TARGET),
;;; sorted by START, for the stamps START <= stamp < END (the transfer
;;; groups of MAKE-TRANSFER-GROUPS); a final state is (:FINAL . effective
;;; method).  Each specialized required argument takes one transition,
;;; found by binary search; a miss calls the default discriminating
;;; function.

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
                                             collect (list start end
                                                           (cdr (assoc target states))))
                                       'simple-vector)))
                            states))
             (setf final-layer-p nil))
    (cdr (first states))))

(defun automaton-transition (state stamp)
  (let ((low 0)
        (high (length state)))
    (loop while (small-integer< low high)
          do (let* ((middle (floor (+ low high) 2))
                    (entry (svref state middle)))
               (cond ((small-integer< stamp (first entry))
                      (setf high middle))
                     ((small-integer< stamp (second entry))
                      (return-from automaton-transition (third entry)))
                     (t
                      (setf low (1+ middle))))))
    nil))

(defun make-discriminating-closure (generic-function)
  (let* ((specializer-profile (specializer-profile generic-function))
         (active-arg-count (loop for x in specializer-profile count x))
         (call-history (call-history generic-function)))
    (when (null call-history)
      (return-from make-discriminating-closure
        (lambda (&rest arguments)
          (default-discriminating-function
           generic-function arguments (specializer-profile generic-function)))))
    (when (small-integer= active-arg-count 0)
      (let ((effective-method (effective-method-cache (first call-history))))
        (return-from make-discriminating-closure
          (lambda (&rest arguments)
            (funcall effective-method arguments)))))
    (let ((automaton (make-automaton (1+ active-arg-count))))
      (loop for call-cache in call-history
            do (add-path automaton
                         (class-cache call-cache)
                         (effective-method-cache call-cache)))
      (let ((initial (automaton-states (extract-transition-information automaton))))
        (lambda (&rest arguments)
          (let ((state initial))
            (loop for p in specializer-profile
                  for remaining on arguments
                  when p
                    do (setf state (automaton-transition state (stamp+1 (car remaining))))
                       (when (null state) (loop-finish)))
            (if (and (consp state) (eq (car state) :final))
                (funcall (cdr state) arguments)
                (default-discriminating-function
                 generic-function arguments specializer-profile))))))))

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
