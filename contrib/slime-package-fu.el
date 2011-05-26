
(defvar slime-package-fu-init-undo-stack nil)

(define-slime-contrib slime-package-fu
  "Exporting/Unexporting symbols at point."
  (:authors "Tobias C. Rittweiler <tcr@freebits.de>")
  (:license "GPL")
  (:swank-dependencies swank-package-fu)
  (:on-load 
   (push `(progn (define-key slime-mode-map "\C-cx"
                   ',(lookup-key slime-mode-map "\C-cx")))
         slime-package-fu-init-undo-stack)
   (define-key slime-mode-map "\C-cx"  'slime-export-symbol-at-point))
  (:on-unload
   (while slime-c-p-c-init-undo-stack
     (eval (pop slime-c-p-c-init-undo-stack)))))


(defvar slime-package-file-candidates
  (mapcar #'file-name-nondirectory
	  '("package.lisp" "packages.lisp" "pkgdcl.lisp" "defpackage.lisp")))

(defvar slime-export-symbol-representation-function
  #'(lambda (n) (format "#:%s" n)))

(defvar slime-defpackage-regexp
  "^(\\(cl:\\|common-lisp:\\)?defpackage\\>[ \t']*")


(defun slime-find-package-definition-rpc (package)
  (slime-eval `(swank:find-definition-for-thing (swank::guess-package ,package))))

(defun slime-find-package-definition-regexp (package)
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (block nil
	(while (re-search-forward slime-defpackage-regexp nil t)
	  (when (slime-package-equal package (slime-sexp-at-point))
            (backward-sexp)
	    (return (make-slime-file-location (buffer-file-name)
                                              (1- (point))))))))))

(defun slime-package-equal (designator1 designator2)
  ;; First try to be lucky and compare the strings themselves (for the
  ;; case when one of the designated packages isn't loaded in the
  ;; image.) Then try to do it properly using the inferior Lisp which
  ;; will also resolve nicknames for us &c.
  (or (equalp (slime-cl-symbol-name designator1)
	      (slime-cl-symbol-name designator2))
      (slime-eval `(swank:package= ,designator1 ,designator2))))

(defun slime-export-symbol (symbol package)
  "Unexport `symbol' from `package' in the Lisp image."
  (slime-eval `(swank:export-symbol-for-emacs ,symbol ,package)))

(defun slime-unexport-symbol (symbol package)
  "Export `symbol' from `package' in the Lisp image."
  (slime-eval `(swank:unexport-symbol-for-emacs ,symbol ,package)))


(defun slime-find-possible-package-file (buffer-file-name)
  (flet ((file-name-subdirectory (dirname)
	   (expand-file-name
	    (concat (file-name-as-directory (slime-to-lisp-filename dirname))
		    (file-name-as-directory ".."))))
	 (try (dirname)
	   (dolist (package-file-name slime-package-file-candidates)
	     (let ((f (slime-to-lisp-filename (concat dirname package-file-name))))
	       (when (file-readable-p f)
		 (return f))))))
    (when buffer-file-name
      (let ((buffer-cwd (file-name-directory buffer-file-name)))
	(or (try buffer-cwd)
	    (try (file-name-subdirectory buffer-cwd))
	    (try (file-name-subdirectory (file-name-subdirectory buffer-cwd))))))))

(defun slime-goto-package-source-definition (package)
  "Tries to find the DEFPACKAGE form of `package'. If found,
places the cursor at the start of the DEFPACKAGE form."
  (flet ((try (location)
	   (when (slime-location-p location)
	     (slime-goto-source-location location)
	     t)))
    (or (try (slime-find-package-definition-rpc package))
	(try (slime-find-package-definition-regexp package))
	(try (when-let (package-file (slime-find-possible-package-file (buffer-file-name)))
	       (with-current-buffer (find-file-noselect package-file t)
		 (slime-find-package-definition-regexp package))))
	(error "Couldn't find source definition of package: %s" package))))

(defun slime-at-expression-p (pattern)
  (when (ignore-errors
          ;; at a list?
          (= (point) (progn (down-list 1)
                            (backward-up-list 1)
                            (point))))
    (save-excursion
      (down-list 1)
      (slime-in-expression-p pattern))))

(defun slime-goto-next-export-clause ()
  ;; Assumes we're inside the beginning of a DEFPACKAGE form.
  (let ((point))
    (save-excursion
      (block nil
	(while (ignore-errors (slime-forward-sexp) t)
          (skip-chars-forward " \n\t")
	  (when (slime-at-expression-p '(:export *))
	    (setq point (point))
	    (return)))))
    (if point
	(goto-char point)
	(error "No next (:export ...) clause found"))))

(defun slime-search-exports-in-defpackage (symbol-name)
  "Look if `symbol-name' is mentioned in one of the :EXPORT clauses."
  ;; Assumes we're inside the beginning of a DEFPACKAGE form.
  (flet ((target-symbol-p (symbol)
           (string-match-p (format "^\\(\\(#:\\)\\|:\\)?%s$"
                                   (regexp-quote symbol-name))
                           symbol)))
    (save-excursion
      (block nil
        (while (ignore-errors (slime-goto-next-export-clause) t)
          (let ((clause-end (save-excursion (forward-sexp) (point))))
            (save-excursion
              (while (search-forward symbol-name clause-end t)
                (when (target-symbol-p (slime-symbol-at-point))
                  (return (point)))))))))))

(defun slime-defpackage-exports ()
  "Return a list of symbols inside :export clause of a defpackage."
  ;; Assumes we're inside the beginning of a DEFPACKAGE form.
  (flet ((normalize-name (name)
           (replace-regexp-in-string "^\\(\\(#:\\)\\|:\\)"
                                     "" name)))
   (save-excursion
     (loop while (ignore-errors (slime-goto-next-export-clause) t)
           do (down-list) (forward-sexp)
           append
           (loop while (ignore-errors (forward-sexp) t)
                 collect (normalize-name (slime-symbol-at-point)))
           do (up-list) (backward-sexp)))))

(defun slime-symbol-exported-p (name symbols)
  (member* name symbols :test 'equalp))

(defun slime-frob-defpackage-form (current-package do-what symbols)
  "Adds/removes `symbol' from the DEFPACKAGE form of `current-package'
depending on the value of `do-what' which can either be `:export',
or `:unexport'.

Returns t if the symbol was added/removed. Nil if the symbol was
already exported/unexported."
  (save-excursion
    (slime-goto-package-source-definition current-package)
    (down-list 1)			; enter DEFPACKAGE form
    (forward-sexp)			; skip DEFPACKAGE symbol
    (forward-sexp)			; skip package name
    (let ((exported-symbols (slime-defpackage-exports))
          (symbols (if (consp symbols)
                       symbols
                       (list symbols)))
          (number-of-actions 0))
      (ecase do-what
        (:export
         (slime-add-export)
         (dolist (symbol symbols)
           (let ((symbol-name (slime-cl-symbol-name symbol)))
             (unless (slime-symbol-exported-p symbol-name exported-symbols)
               (incf number-of-actions)
               (slime-insert-export symbol-name)))))
        (:unexport
         (dolist (symbol symbols)
           (let ((symbol-name (slime-cl-symbol-name symbol)))
             (when (slime-symbol-exported-p symbol-name exported-symbols)
               (slime-remove-export symbol-name)
               (incf number-of-actions))))))
      number-of-actions)))

(defun slime-add-export ()
  (let (point)
    (save-excursion
      (while (ignore-errors (slime-goto-next-export-clause) t)
        (setq point (point))))
    (cond (point
           (goto-char point)
           (down-list)
           (slime-end-of-list))
          (t
           (slime-end-of-list)
           (unless (looking-back "^\\s-*")
             (newline-and-indent))
           (insert "(:export ")
           (save-excursion (insert ")"))))))

(defun slime-insert-export (symbol-name)
  ;; Assumes we're at the inside :export after the last symbol
  (let ((symbol-name (funcall slime-export-symbol-representation-function
                              symbol-name)))
    (unless (looking-back "^\\s-*")
      (newline-and-indent))
    (insert symbol-name)))

(defun slime-remove-export (symbol-name)
  ;; Assumes we're inside the beginning of a DEFPACKAGE form.
  (let ((point))
    (while (setq point (slime-search-exports-in-defpackage symbol-name))
      (save-excursion
	(goto-char point)
	(backward-sexp)
	(delete-region (point) point)
	(beginning-of-line)
	(when (looking-at "^\\s-*$")
	  (join-line))))))

(defun slime-export-symbol-at-point ()
  "Add the symbol at point to the defpackage source definition
belonging to the current buffer-package. With prefix-arg, remove
the symbol again. Additionally performs an EXPORT/UNEXPORT of the
symbol in the Lisp image if possible."
  (interactive)
  (let ((package (slime-current-package))
	(symbol (slime-symbol-at-point)))
    (unless symbol (error "No symbol at point."))
    (cond (current-prefix-arg
	   (if (plusp (slime-frob-defpackage-form package :unexport symbol))
	       (message "Symbol `%s' no longer exported form `%s'" symbol package)
	       (message "Symbol `%s' is not exported from `%s'" symbol package))
	   (slime-unexport-symbol symbol package))
	  (t
	   (if (plusp (slime-frob-defpackage-form package :export symbol))
	       (message "Symbol `%s' now exported from `%s'" symbol package)
	       (message "Symbol `%s' already exported from `%s'" symbol package))
	   (slime-export-symbol symbol package)))))

(defun slime-export-class (name)
  "Export acessors, constructors, etc. associated with a structure or a class"
  (interactive (list (slime-read-from-minibuffer "Export structure named: "
                                                 (slime-symbol-at-point))))
  (let* ((package (slime-current-package))
         (symbols (slime-eval `(swank:export-structure ,name ,package))))
    (message "%s symbols exported from `%s'"
             (slime-frob-defpackage-form package :export symbols)
             package)))

(defalias 'slime-export-structure 'slime-export-class)

(provide 'slime-package-fu)
