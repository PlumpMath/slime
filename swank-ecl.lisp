;;;; -*- indent-tabs-mode: nil -*-
;;;
;;; swank-ecl.lisp --- SLIME backend for ECL.
;;;
;;; This code has been placed in the Public Domain.  All warranties
;;; are disclaimed.
;;;

;;; Administrivia

(in-package :swank-backend)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((version (find-symbol "+ECL-VERSION-NUMBER+" :EXT)))
    (when (or (not version) (< (symbol-value version) 100201))
      (error "~&IMPORTANT:~%  ~
              The version of ECL you're using (~A) is too old.~%  ~
              Please upgrade to at least 10.2.1.~%  ~
              Sorry for the inconvenience.~%~%"
             (lisp-implementation-version)))))

;; Hard dependencies.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require 'sockets))

;; Soft dependencies.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (probe-file "sys:profile.fas")
    (require :profile)
    (pushnew :profile *features*))
  (when (probe-file "sys:serve-event.fas")
    (require :serve-event)
    (pushnew :serve-event *features*)))

(declaim (optimize (debug 3)))

;;; Swank-mop

(eval-when (:compile-toplevel :load-toplevel :execute)
  (import-from :gray *gray-stream-symbols* :swank-backend)

  (import-swank-mop-symbols :clos
    '(:eql-specializer
      :eql-specializer-object
      :generic-function-declarations
      :specializer-direct-methods
      :compute-applicable-methods-using-classes)))


;;;; TCP Server

(defimplementation preferred-communication-style ()
  ;; While ECL does provide threads, some parts of it are not
  ;; thread-safe (2010-02-23), including the compiler and CLOS.
  nil
  ;; ECL on Windows does not provide condition-variables
  ;; (or #+(and threads (not windows)) :spawn
  ;;     nil)
  )

(defun resolve-hostname (name)
  (car (sb-bsd-sockets:host-ent-addresses
        (sb-bsd-sockets:get-host-by-name name))))

(defimplementation create-socket (host port)
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket
			       :type :stream
			       :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (sb-bsd-sockets:socket-bind socket (resolve-hostname host) port)
    (sb-bsd-sockets:socket-listen socket 5)
    socket))

(defimplementation local-port (socket)
  (nth-value 1 (sb-bsd-sockets:socket-name socket)))

(defimplementation close-socket (socket)
  (sb-bsd-sockets:socket-close socket))

(defimplementation accept-connection (socket
                                      &key external-format
                                      buffering timeout)
  (declare (ignore timeout))
  (sb-bsd-sockets:socket-make-stream (accept socket)
                                     :output t
                                     :input t
                                     :buffering buffering
                                     :external-format external-format))
(defun accept (socket)
  "Like socket-accept, but retry on EAGAIN."
  (loop (handler-case
            (return (sb-bsd-sockets:socket-accept socket))
          (sb-bsd-sockets:interrupted-error ()))))

(defimplementation socket-fd (socket)
  (etypecase socket
    (fixnum socket)
    (two-way-stream (socket-fd (two-way-stream-input-stream socket)))
    (sb-bsd-sockets:socket (sb-bsd-sockets:socket-file-descriptor socket))
    (file-stream (si:file-stream-fd socket))))

(defvar *external-format-to-coding-system*
  '((:latin-1
     "latin-1" "latin-1-unix" "iso-latin-1-unix" 
     "iso-8859-1" "iso-8859-1-unix")
    (:utf-8 "utf-8" "utf-8-unix")))

(defun external-format (coding-system)
  (or (car (rassoc-if (lambda (x) (member coding-system x :test #'equal))
                      *external-format-to-coding-system*))
      (find coding-system (ext:all-encodings) :test #'string-equal)))

(defimplementation find-external-format (coding-system)
  #+unicode (external-format coding-system)
  ;; Without unicode support, ECL uses the one-byte encoding of the
  ;; underlying OS, and will barf on anything except :DEFAULT.  We
  ;; return NIL here for known multibyte encodings, so
  ;; SWANK:CREATE-SERVER will barf.
  #-unicode (let ((xf (external-format coding-system)))
              (if (member xf '(:utf-8))
                  nil
                  :default)))


;;;; Unix Integration

(defvar *original-sigint-handler* #'si:terminal-interrupt)

(defimplementation install-sigint-handler (handler)
  (declare (function handler))
  (let ((old-handler (symbol-function 'si:terminal-interrupt)))
    (setf (symbol-function 'si:terminal-interrupt)
          (if (eq handler *original-sigint-handler*)
              handler
              (lambda (&rest args)
                (declare (ignore args))
                (funcall handler)
                (continue))))
    old-handler))

(defimplementation getpid ()
  (si:getpid))

(defimplementation set-default-directory (directory)
  (ext:chdir (namestring directory))  ; adapts *DEFAULT-PATHNAME-DEFAULTS*.
  (default-directory))

(defimplementation default-directory ()
  (namestring (ext:getcwd)))

(defimplementation quit-lisp ()
  (ext:quit))



;;; Instead of busy waiting with communication-style NIL, use select()
;;; on the sockets' streams.
#+serve-event
(progn
  (defun poll-streams (streams timeout)
    (let* ((serve-event::*descriptor-handlers*
            (copy-list serve-event::*descriptor-handlers*))
           (active-fds '())
           (fd-stream-alist
            (loop for s in streams
                  for fd = (socket-fd s)
                  collect (cons (socket-fd s) s)
                  do (serve-event:add-fd-handler fd :input
                                                 #'(lambda (fd)
                                                     (push fd active-fds))))))
      (serve-event:serve-event timeout)
      (loop for fd in active-fds collect (cdr (assoc fd fd-stream-alist)))))

  (defimplementation wait-for-input (streams &optional timeout)
    (assert (member timeout '(nil t)))
    (loop
      (cond ((check-slime-interrupts) (return :interrupt))
            (timeout (return (poll-streams streams 0)))
            (t
             (let ((ready (poll-streams streams 0.2)))
               (when ready
                 (return ready)))))))  

) ; #+serve-event (progn ...


;;;; Compilation

(defvar *buffer-name* nil)
(defvar *buffer-start-position*)

(defun signal-compiler-condition (&rest args)
  (signal (apply #'make-condition 'compiler-condition args)))

(defun handle-compiler-message (condition)
  ;; ECL emits lots of noise in compiler-notes, like "Invoking
  ;; external command".
  (unless (typep condition 'c::compiler-note)
    (signal-compiler-condition
     :original-condition condition
     :message (princ-to-string condition)
     :severity (etypecase condition
                 (c:compiler-fatal-error :error)
                 (c:compiler-error       :error)
                 (error                  :error)
                 (style-warning          :style-warning)
                 (warning                :warning))
     :location (condition-location condition))))

(defun make-file-location (file file-position)
  ;; File positions in CL start at 0, but Emacs' buffer positions
  ;; start at 1. We specify (:ALIGN T) because the positions comming
  ;; from ECL point at right after the toplevel form appearing before
  ;; the actual target toplevel form; (:ALIGN T) will DTRT in that case.
  (make-location `(:file ,(namestring file))
                 `(:position ,(1+ file-position))
                 `(:align t)))

(defun make-buffer-location (buffer-name start-position offset)
  (make-location `(:buffer ,buffer-name)
                 `(:offset ,start-position ,offset)
                 `(:align t)))

(defun condition-location (condition)
  (let ((file     (c:compiler-message-file condition))
        (position (c:compiler-message-file-position condition)))
    (if (and position (not (minusp position)))
        (if *buffer-name*
            (make-buffer-location *buffer-name*
                                  *buffer-start-position*
                                  position)
            (make-file-location file position))
        (make-error-location "No location found."))))

(defimplementation call-with-compilation-hooks (function)
  (handler-bind ((c:compiler-message #'handle-compiler-message))
    (funcall function)))

(defimplementation swank-compile-file (input-file output-file
                                       load-p external-format)
  (with-compilation-hooks ()
    (compile-file input-file :output-file output-file
                  :load load-p
                  :external-format external-format)))

(defimplementation swank-compile-string (string &key buffer position filename
                                                policy)
  (declare (ignore filename policy))
  (with-compilation-hooks ()
    (let ((*buffer-name* buffer)        ; for compilation hooks
          (*buffer-start-position* position))
      (let ((file (si:mkstemp "TMP:ECL-SWANK-"))
            (fasl-file)
            (warnings-p)
            (failure-p))
        (unwind-protect
             (with-open-file (file-stream file :direction :output
                                               :if-exists :supersede)
               (write-string string file-stream)
               (finish-output file-stream)
               (multiple-value-setq (fasl-file warnings-p failure-p)
                 (compile-file file :load t)))
          (when (probe-file file)
            (delete-file file))
          (when fasl-file
            (delete-file fasl-file)))
        (not failure-p)))))

;;;; Documentation

(defimplementation arglist (name)
  (multiple-value-bind (arglist foundp)
      (si::function-lambda-list name)
    (if foundp arglist :not-available)))

(defimplementation function-name (f)
  (typecase f
    (generic-function (clos:generic-function-name f))
    (function (si:compiled-function-name f))))

;; FIXME
;; (defimplementation macroexpand-all (form))

(defimplementation describe-symbol-for-emacs (symbol)
  (let ((result '()))
    (dolist (type '(:VARIABLE :FUNCTION :CLASS))
      (let ((doc (describe-definition symbol type)))
        (when doc
          (setf result (list* type doc result)))))
    result))

(defimplementation describe-definition (name type)
  (case type
    (:variable (documentation name 'variable))
    (:function (documentation name 'function))
    (:class (documentation name 'class))
    (t nil)))


;;; Debugging

(eval-when (:compile-toplevel :load-toplevel :execute)
  (import
   '(si::*break-env*
     si::*ihs-top*
     si::*ihs-current*
     si::*ihs-base*
     si::*frs-base*
     si::*frs-top*
     si::*tpl-commands*
     si::*tpl-level*
     si::frs-top
     si::ihs-top
     si::ihs-fun
     si::ihs-env
     si::sch-frs-base
     si::set-break-env
     si::set-current-ihs
     si::tpl-commands)))

(defun make-invoke-debugger-hook (hook)
  (when hook
    #'(lambda (condition old-hook)
        ;; Regard *debugger-hook* if set by user.
        (if *debugger-hook*
            nil         ; decline, *DEBUGGER-HOOK* will be tried next.
            (funcall hook condition old-hook)))))

(defimplementation install-debugger-globally (function)
  (setq *debugger-hook* function)
  (setq ext:*invoke-debugger-hook* (make-invoke-debugger-hook function)))

(defimplementation call-with-debugger-hook (hook fun)
  (let ((*debugger-hook* hook)
        (ext:*invoke-debugger-hook* (make-invoke-debugger-hook hook)))
    (funcall fun)))

(defvar *backtrace* '())

;;; Commented out; it's not clear this is a good way of doing it. In
;;; particular because it makes errors stemming from this file harder
;;; to debug, and given the "young" age of ECL's swank backend, that's
;;; a bad idea.

;; (defun in-swank-package-p (x)
;;   (and
;;    (symbolp x)
;;    (member (symbol-package x)
;;            (list #.(find-package :swank)
;;                  #.(find-package :swank-backend)
;;                  #.(ignore-errors (find-package :swank-mop))
;;                  #.(ignore-errors (find-package :swank-loader))))
;;    t))

;; (defun is-swank-source-p (name)
;;   (setf name (pathname name))
;;   (pathname-match-p
;;    name
;;    (make-pathname :defaults swank-loader::*source-directory*
;;                   :name (pathname-name name)
;;                   :type (pathname-type name)
;;                   :version (pathname-version name))))

;; (defun is-ignorable-fun-p (x)
;;   (or
;;    (in-swank-package-p (frame-name x))
;;    (multiple-value-bind (file position)
;;        (ignore-errors (si::bc-file (car x)))
;;      (declare (ignore position))
;;      (if file (is-swank-source-p file)))))

(defimplementation call-with-debugging-environment (debugger-loop-fn)
  (declare (type function debugger-loop-fn))
  (let* ((*tpl-commands* si::tpl-commands)
         (*ihs-top* (ihs-top))
         (*ihs-current* *ihs-top*)
         (*frs-base* (or (sch-frs-base *frs-top* *ihs-base*) (1+ (frs-top))))
         (*frs-top* (frs-top))
         (*read-suppress* nil)
         (*tpl-level* (1+ *tpl-level*))
         (*backtrace* (loop for ihs from 0 below *ihs-top*
                            collect (list (si::ihs-fun ihs)
                                          (si::ihs-env ihs)
                                          nil))))
    (declare (special *ihs-current*))
    (loop for f from *frs-base* until *frs-top*
          do (let ((i (- (si::frs-ihs f) *ihs-base* 1)))
               (when (plusp i)
                 (let* ((x (elt *backtrace* i))
                        (name (si::frs-tag f)))
                   (unless (si::fixnump name)
                     (push name (third x)))))))
    (setf *backtrace* (nreverse *backtrace*))
    (set-break-env)
    (set-current-ihs)
    (let ((*ihs-base* *ihs-top*))
      (funcall debugger-loop-fn))))

(defimplementation compute-backtrace (start end)
  (when (numberp end)
    (setf end (min end (length *backtrace*))))
  (loop for f in (subseq *backtrace* start end)
        collect f))

(defun frame-name (frame)
  (let ((x (first frame)))
    (if (symbolp x)
      x
      (function-name x))))

(defun function-position (fun)
  (multiple-value-bind (file position)
      (si::bc-file fun)
    (when file
      (make-file-location file position))))

(defun frame-function (frame)
  (let* ((x (first frame))
         fun position)
    (etypecase x
      (symbol (and (fboundp x)
                   (setf fun (fdefinition x)
                         position (function-position fun))))
      (function (setf fun x position (function-position x))))
    (values fun position)))

(defun frame-decode-env (frame)
  (let ((functions '())
        (blocks '())
        (variables '()))
    (setf frame (si::decode-ihs-env (second frame)))
    (dolist (record frame)
      (let* ((record0 (car record))
	     (record1 (cdr record)))
	(cond ((or (symbolp record0) (stringp record0))
	       (setq variables (acons record0 record1 variables)))
	      ((not (si::fixnump record0))
	       (push record1 functions))
	      ((symbolp record1)
	       (push record1 blocks))
	      (t
	       ))))
    (values functions blocks variables)))

(defimplementation print-frame (frame stream)
  (format stream "~A" (first frame)))

(defimplementation frame-source-location (frame-number)
  (nth-value 1 (frame-function (elt *backtrace* frame-number))))

(defimplementation frame-catch-tags (frame-number)
  (third (elt *backtrace* frame-number)))

(defimplementation frame-locals (frame-number)
  (loop for (name . value) in (nth-value 2 (frame-decode-env (elt *backtrace* frame-number)))
        with i = 0
        collect (list :name name :id (prog1 i (incf i)) :value value)))

(defimplementation frame-var-value (frame-number var-id)
  (elt (nth-value 2 (frame-decode-env (elt *backtrace* frame-number)))
       var-id))

(defimplementation disassemble-frame (frame-number)
  (let ((fun (frame-function (elt *backtrace* frame-number))))
    (disassemble fun)))

(defimplementation eval-in-frame (form frame-number)
  (let ((env (second (elt *backtrace* frame-number))))
    (si:eval-with-env form env)))


;;;; Inspector

;;; FIXME: Would be nice if it was possible to inspect objects
;;; implemented in C.


;;;; Definitions

;;; FIXME: There ought to be a better way.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun c-function-p (object)
    (and (functionp object)
         (let ((fn-name (function-name object)))
           (and fn-name (si:mangle-name fn-name t) t)))))

(deftype c-function ()
  `(satisfies c-function-p))

(defvar +TAGS+ (namestring (translate-logical-pathname #P"SYS:TAGS")))

(defun assert-source-directory ()
  (unless (probe-file #P"SRC:")
    (error "ECL's source directory ~A does not exist. ~
            You can specify a different location via the environment ~
            variable `ECLSRCDIR'."
           (namestring (translate-logical-pathname #P"SYS:"))))) 

(defun assert-TAGS-file ()
  (unless (probe-file +TAGS+)
    (error "No TAGS file ~A found. It should have been installed with ECL."
           +TAGS+)))

(defun classify-definition-name (name)
  (let ((types '()))
    (when (fboundp name)
      (cond ((special-operator-p name)
             (push :special-operator types))
            ((macro-function name)
             (push :macro types))
            ((typep (fdefinition name) 'generic-function)
             (push :generic-function types))
            ((si:mangle-name name t)
             (push :c-function types))
            (t
             (push :lisp-function types))))
    types))

(defun find-definitions-for-type (name type)
  (ecase type
    (:lisp-function
     (list `((defun ,name) ,(source-location (fdefinition name)))))
    (:c-function
     (list `((c-source ,name) ,(source-location (fdefinition name)))))
    (:generic-function
     (loop for method in (clos:generic-function-methods (fdefinition name))
           for specs = (clos:method-specializers method)
           for loc   = (source-location method)
           when loc
             collect `((defmethod ,name ,specs) ,loc)))
    (:macro
     (list `((defmacro ,name) ,(source-location (macro-function name)))))
    (:special-operator)))

(defimplementation find-definitions (name)
  (mapcan #'(lambda (type) (find-definitions-for-type name type))
          (classify-definition-name name)))


(defun source-location (object)
  (converting-errors-to-error-location
    (typecase object
      (c-function
       (assert-source-directory)
       (assert-TAGS-file)
       (let ((lisp-name (function-name object)))
         (assert lisp-name)
         (multiple-value-bind (flag c-name) (si:mangle-name lisp-name t)
           (assert flag)
           ;; In ECL's code base sometimes the mangled name is used
           ;; directly, sometimes ECL's DPP magic of @LISP:SYMBOL is used.
           ;; We cannot predict here, so we just provide two candidates.
           (let* ((candidate1 c-name)
                  (candidate2 (format nil "~A::~A"
                                      (package-name (symbol-package lisp-name))
                                      (symbol-name lisp-name))))
             (make-location `(:etags-file ,+TAGS+)
                            `(:tag ,candidate1 ,candidate2))))))
      (function
       ;; FIXME: EXT:C-F-FILE may return "/tmp/ECL_SWANK_KMOXtm" which
       ;; are the temporary files stemming from C-c C-c.
       (multiple-value-bind (file pos) (ext:compiled-function-file object)
         (when file
           (assert (probe-file file))
           (assert (not (minusp pos)))
           (make-file-location file pos))))
      (method
       ;; FIXME: This will always return NIL at the moment; ECL does not
       ;; store debug information for methods yet.
       (source-location (clos:method-function object))))))

(defimplementation find-source-location (object)
  (or (source-location object)
      (make-error-location "Source definition of ~S not found" object)))


;;;; Profiling

#+profile
(progn

(defimplementation profile (fname)
  (when fname (eval `(profile:profile ,fname))))

(defimplementation unprofile (fname)
  (when fname (eval `(profile:unprofile ,fname))))

(defimplementation unprofile-all ()
  (profile:unprofile-all)
  "All functions unprofiled.")

(defimplementation profile-report ()
  (profile:report))

(defimplementation profile-reset ()
  (profile:reset)
  "Reset profiling counters.")

(defimplementation profiled-functions ()
  (profile:profile))

(defimplementation profile-package (package callers methods)
  (declare (ignore callers methods))
  (eval `(profile:profile ,(package-name (find-package package)))))
) ; #+profile (progn ...


;;;; Threads

#+threads
(progn
  (defvar *thread-id-counter* 0)

  (defparameter *thread-id-map* (make-hash-table))

  (defvar *thread-id-map-lock*
    (mp:make-lock :name "thread id map lock"))

  (defimplementation spawn (fn &key name)
    (mp:process-run-function name fn))

  (defimplementation thread-id (target-thread)
    (block thread-id
      (mp:with-lock (*thread-id-map-lock*)
        ;; Does TARGET-THREAD have an id already?
        (maphash (lambda (id thread-pointer)
                   (let ((thread (si:weak-pointer-value thread-pointer)))
                     (cond ((not thread)
                            (remhash id *thread-id-map*))
                           ((eq thread target-thread)
                            (return-from thread-id id)))))
                 *thread-id-map*)
        ;; TARGET-THREAD not found in *THREAD-ID-MAP*
        (let ((id (incf *thread-id-counter*))
              (thread-pointer (si:make-weak-pointer target-thread)))
          (setf (gethash id *thread-id-map*) thread-pointer)
          id))))

  (defimplementation find-thread (id)
    (mp:with-lock (*thread-id-map-lock*)
      (let* ((thread-ptr (gethash id *thread-id-map*))
             (thread (and thread-ptr (si:weak-pointer-value thread-ptr))))
        (unless thread
          (remhash id *thread-id-map*))
        thread)))

  (defimplementation thread-name (thread)
    (mp:process-name thread))

  (defimplementation thread-status (thread)
    (if (mp:process-active-p thread)
        "RUNNING"
        "STOPPED"))

  (defimplementation make-lock (&key name)
    (mp:make-lock :name name))

  (defimplementation call-with-lock-held (lock function)
    (declare (type function function))
    (mp:with-lock (lock) (funcall function)))

  (defimplementation current-thread ()
    mp:*current-process*)

  (defimplementation all-threads ()
    (mp:all-processes))

  (defimplementation interrupt-thread (thread fn)
    (mp:interrupt-process thread fn))

  (defimplementation kill-thread (thread)
    (mp:process-kill thread))

  (defimplementation thread-alive-p (thread)
    (mp:process-active-p thread))

  (defvar *mailbox-lock* (mp:make-lock :name "mailbox lock"))
  (defvar *mailboxes* (list))
  (declaim (type list *mailboxes*))

  (defstruct (mailbox (:conc-name mailbox.))
    thread
    (mutex (mp:make-lock))
    (cvar  (mp:make-condition-variable))
    (queue '() :type list))

  (defun mailbox (thread)
    "Return THREAD's mailbox."
    (mp:with-lock (*mailbox-lock*)
      (or (find thread *mailboxes* :key #'mailbox.thread)
          (let ((mb (make-mailbox :thread thread)))
            (push mb *mailboxes*)
            mb))))

  (defimplementation send (thread message)
    (let* ((mbox (mailbox thread))
           (mutex (mailbox.mutex mbox)))
      (mp:with-lock (mutex)
        (setf (mailbox.queue mbox)
              (nconc (mailbox.queue mbox) (list message)))
        (mp:condition-variable-broadcast (mailbox.cvar mbox)))))

  (defimplementation receive-if (test &optional timeout)
    (let* ((mbox (mailbox (current-thread)))
           (mutex (mailbox.mutex mbox)))
      (assert (or (not timeout) (eq timeout t)))
      (loop
         (check-slime-interrupts)
         (mp:with-lock (mutex)
           (let* ((q (mailbox.queue mbox))
                  (tail (member-if test q)))
             (when tail
               (setf (mailbox.queue mbox) (nconc (ldiff q tail) (cdr tail)))
               (return (car tail))))
           (when (eq timeout t) (return (values nil t)))
           (mp:condition-variable-timedwait (mailbox.cvar mbox)
                                            mutex
                                            0.2)))))

  ) ; #+threads (progn ...
