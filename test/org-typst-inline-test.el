;;; org-typst-inline-test.el --- Tests for org-typst-inline -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the package directory with Emacs in batch mode:
;;   -Q --batch -L . -l test/org-typst-inline-test.el
;;   -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-typst-inline)

(defconst org-typst-inline-test--document
  "Inline $a + b$ and \\(c\\).

\\[ sum_(i=1)^n i \\]

\\begin{equation}
x^2
\\end{equation}

Snippet @@typst:#emoji.face@@ and @@html:<b>@@.

Verbatim =$v$= and code ~$w$~.

# comment $z$

#+begin_src emacs-lisp
\"$s$\"
#+end_src

#+begin_example
$e$
#+end_example
"
  "Org text exercising every kind of element.")

(defmacro org-typst-inline-test--with-buffer (text &rest body)
  "Run BODY in an Org buffer containing TEXT."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (org-mode)
     (goto-char (point-min))
     ,@body))

(defun org-typst-inline-test--candidate (needle)
  "Return the candidate at the first occurrence of NEEDLE."
  (goto-char (point-min))
  (search-forward needle)
  (org-typst-inline--candidate-at (match-beginning 0)))

;;;; Element detection

(ert-deftest org-typst-inline-test-candidates ()
  (org-typst-inline-test--with-buffer org-typst-inline-test--document
    (let ((c (org-typst-inline-test--candidate "$a + b$")))
      (should (eq (plist-get c :kind) 'inline))
      (should (equal (plist-get c :body) "a + b"))
      ;; Trailing blanks are not part of the element's range.
      (should (equal (buffer-substring (plist-get c :begin) (plist-get c :end))
                     "$a + b$")))
    (should (eq (plist-get (org-typst-inline-test--candidate "\\(c\\)") :kind)
                'inline))
    (let ((c (org-typst-inline-test--candidate "\\[ sum")))
      (should (eq (plist-get c :kind) 'display))
      (should (equal (plist-get c :body) "sum_(i=1)^n i")))
    (let ((c (org-typst-inline-test--candidate "\\begin{equation}")))
      (should (eq (plist-get c :kind) 'display))
      (should (equal (plist-get c :body) "x^2"))
      (should (equal (buffer-substring (plist-get c :begin) (plist-get c :end))
                     "\\begin{equation}\nx^2\n\\end{equation}")))
    (let ((c (org-typst-inline-test--candidate "@@typst:")))
      (should (eq (plist-get c :kind) 'snippet))
      (should (equal (plist-get c :body) "#emoji.face")))))

(ert-deftest org-typst-inline-test-candidates-excluded ()
  (org-typst-inline-test--with-buffer org-typst-inline-test--document
    (dolist (needle '("@@html:" "$v$" "$w$" "$z$" "$s$" "$e$"))
      (should-not (org-typst-inline-test--candidate needle)))))

(ert-deftest org-typst-inline-test-latex-command-excluded ()
  (org-typst-inline-test--with-buffer "A \\foo{bar} command.\n"
    (should-not (org-typst-inline-test--candidate "\\foo"))))

(ert-deftest org-typst-inline-test-split-math ()
  (should (equal (org-typst-inline--split-math "$x$") '(inline . "x")))
  (should (equal (org-typst-inline--split-math "$$x$$") '(display . "x")))
  (should (equal (org-typst-inline--split-math "\\[x\\]") '(display . "x")))
  (should (equal (org-typst-inline--split-math "\\(x\\)") '(inline . "x")))
  (should-not (org-typst-inline--split-math "\\alpha")))

;;;; Cache keys

(ert-deftest org-typst-inline-test-cache-key ()
  (let ((key (org-typst-inline--cache-key 'inline "x" "#000000" 10.0)))
    (should (string-match-p "\\`[0-9a-f]\\{40\\}\\'" key))
    (should (equal key (org-typst-inline--cache-key 'inline "x" "#000000" 10.0)))
    (dolist (other (list (org-typst-inline--cache-key 'inline "y" "#000000" 10.0)
                         (org-typst-inline--cache-key 'display "x" "#000000" 10.0)
                         (org-typst-inline--cache-key 'inline "x" "#ffffff" 10.0)
                         (org-typst-inline--cache-key 'inline "x" "#000000" 12.0)
                         (let ((org-typst-inline-preamble "#set text(font: \"A\")"))
                           (org-typst-inline--cache-key 'inline "x" "#000000" 10.0))))
      (should-not (equal key other)))))

(ert-deftest org-typst-inline-test-source ()
  (let ((org-typst-inline-preamble "// pre"))
    (let ((source (org-typst-inline--source 'inline "x" "#112233" 11.0)))
      (should (string-match-p "#set page(width: auto, height: auto, margin: 2pt" source))
      (should (string-match-p "size: 11.00pt, fill: rgb(\"#112233\")" source))
      (should (string-match-p "^// pre$" source))
      (should (string-match-p "^\\$x\\$$" source)))
    (should (string-match-p "^\\$ x \\$$"
                            (org-typst-inline--source 'display "x" "#000000" 10.0)))
    (should (string-match-p "^#emoji.face$"
                            (org-typst-inline--source 'snippet "#emoji.face"
                                                      "#000000" 10.0)))))

;;;; Overlay state

(defmacro org-typst-inline-test--with-mode (text trigger &rest body)
  "Run BODY in an Org buffer with TEXT, the mode on and TRIGGER.
Compilation is stubbed out, and every element is given an overlay."
  (declare (indent 2) (debug t))
  `(let ((org-typst-inline-follow-org-appear nil)
         (org-typst-inline-trigger ,trigger)
         (org-typst-inline-delay 0.0)
         (org-typst-inline-manual-linger nil)
         (org-typst-inline--results (make-hash-table :test #'equal)))
     (cl-letf (((symbol-function 'org-typst-inline--request) #'ignore))
       (org-typst-inline-test--with-buffer ,text
         (org-typst-inline-mode 1)
         (org-typst-inline--fontify (point-min) (point-max))
         ,@body))))

(defun org-typst-inline-test--revealed-p (needle)
  "Return non-nil if the overlay at NEEDLE shows its source."
  (save-excursion
    (goto-char (point-min))
    (search-forward needle)
    (let ((ov (org-typst-inline--overlay-at (match-beginning 0))))
      (should ov)
      (overlay-get ov 'org-typst-inline-revealed))))

(defun org-typst-inline-test--move (needle)
  "Move to the start of NEEDLE and run the post-command logic."
  (goto-char (point-min))
  (search-forward needle)
  (goto-char (match-beginning 0))
  (org-typst-inline--post-command))

(ert-deftest org-typst-inline-test-overlays-created ()
  (org-typst-inline-test--with-mode org-typst-inline-test--document 'always
    ;; $a + b$, \(c\), \[...\], equation, typst snippet.
    (should (= (length (org-typst-inline--all-overlays)) 5))
    (dolist (ov (org-typst-inline--all-overlays))
      (should-not (overlay-get ov 'org-typst-inline-revealed))
      ;; No result yet: the dimmed source is the placeholder.
      (should (eq (overlay-get ov 'face) 'org-typst-inline-pending)))))

(ert-deftest org-typst-inline-test-trigger-always ()
  (org-typst-inline-test--with-mode "x $a$ y $b$\n" 'always
    (org-typst-inline-test--move "$a$")
    (should (org-typst-inline-test--revealed-p "$a$"))
    (should-not (org-typst-inline-test--revealed-p "$b$"))
    (org-typst-inline-test--move "$b$")
    (should-not (org-typst-inline-test--revealed-p "$a$"))
    (should (org-typst-inline-test--revealed-p "$b$"))
    (org-typst-inline-test--move "x")
    (should-not (org-typst-inline-test--revealed-p "$b$"))))

(ert-deftest org-typst-inline-test-element-bounds ()
  (org-typst-inline-test--with-mode "x $a$ y\n" 'always
    ;; Right after the closing delimiter still counts as inside.
    (goto-char (point-min))
    (search-forward "$a$")
    (org-typst-inline--post-command)
    (should (org-typst-inline-test--revealed-p "$a$"))
    ;; One character further does not.
    (forward-char 1)
    (org-typst-inline--post-command)
    (should-not (org-typst-inline-test--revealed-p "$a$"))))

(ert-deftest org-typst-inline-test-trigger-on-change ()
  (org-typst-inline-test--with-mode "x $a$ y\n" 'on-change
    (org-typst-inline-test--move "$a$")
    (should-not (org-typst-inline-test--revealed-p "$a$"))
    (org-typst-inline--after-change)
    (org-typst-inline--post-command)
    (should (org-typst-inline-test--revealed-p "$a$"))
    (org-typst-inline-test--move "x")
    (should-not (org-typst-inline-test--revealed-p "$a$"))
    (org-typst-inline-test--move "$a$")
    (should-not (org-typst-inline-test--revealed-p "$a$"))))

(ert-deftest org-typst-inline-test-trigger-manual ()
  (org-typst-inline-test--with-mode "x $a$ y\n" 'manual
    (org-typst-inline-test--move "$a$")
    (should-not (org-typst-inline-test--revealed-p "$a$"))
    (org-typst-inline-manual-start)
    (org-typst-inline--post-command)
    (should (org-typst-inline-test--revealed-p "$a$"))
    (org-typst-inline-manual-stop)
    (should-not (org-typst-inline-test--revealed-p "$a$"))))

(ert-deftest org-typst-inline-test-delay ()
  (org-typst-inline-test--with-mode "x $a$ y\n" 'always
    (let ((org-typst-inline-delay 10.0))
      (org-typst-inline-test--move "$a$")
      (should-not (org-typst-inline-test--revealed-p "$a$"))
      (should (timerp org-typst-inline--timer))
      (org-typst-inline--reveal-delayed (current-buffer) org-typst-inline--prev)
      (should (org-typst-inline-test--revealed-p "$a$")))))

(ert-deftest org-typst-inline-test-edit-keeps-revealed ()
  (org-typst-inline-test--with-mode "x $a$ y $b$\n" 'always
    (org-typst-inline-test--move "$a$")
    (let ((old (org-typst-inline--overlay-at (point)))
          (other (save-excursion
                   (search-forward "$b$")
                   (org-typst-inline--overlay-at (point)))))
      (forward-char 1)
      (insert "c")
      (org-typst-inline--fontify (line-beginning-position) (line-end-position))
      ;; The edited element gets a new overlay that stays revealed...
      (should-not (overlay-buffer old))
      (should (org-typst-inline-test--revealed-p "$ca$"))
      (should (equal (overlay-get (org-typst-inline--overlay-at (point))
                                  'org-typst-inline-body)
                     "ca"))
      ;; ...and the untouched one is kept as is.
      (should (overlay-buffer other)))))

(ert-deftest org-typst-inline-test-render-result ()
  (org-typst-inline-test--with-mode "x $a$ y\n" 'always
    (let ((ov (car (org-typst-inline--all-overlays))))
      (puthash (overlay-get ov 'org-typst-inline-key) '(error . "boom")
               org-typst-inline--results)
      (org-typst-inline--render ov)
      (should (eq (overlay-get ov 'face) 'org-typst-inline-error))
      (should (equal (overlay-get ov 'help-echo) "boom"))
      (let ((file (make-temp-file "org-typst-inline" nil ".svg"
                                  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"/>")))
        (unwind-protect
            (progn
              (puthash (overlay-get ov 'org-typst-inline-key) file
                       org-typst-inline--results)
              (org-typst-inline--render ov)
              (should (eq (car-safe (overlay-get ov 'display)) 'image))
              (should (eq (plist-get (cdr (overlay-get ov 'display)) :ascent)
                          'center)))
          (delete-file file))))))

(ert-deftest org-typst-inline-test-align ()
  (dolist (case '((left . 0.0) (center . 0.5) (right . 1.0)))
    (let ((org-typst-inline-display-align (car case)))
      (should (= (org-typst-inline--align-fraction) (cdr case)))))
  (let ((org-typst-inline-display-align 'center))
    (should (equal (org-typst-inline--align-spec 'img)
                   '(+ left (- (0.5 . text) (0.5 . img)))))))

;;;; Typst integration

(ert-deftest org-typst-inline-test-compile ()
  (skip-unless (executable-find org-typst-inline-typst-program))
  (let* ((org-typst-inline-cache-directory (make-temp-file "org-typst-inline" t))
         (org-typst-inline--results (make-hash-table :test #'equal))
         (good (org-typst-inline--cache-key 'inline "x^2" "#000000" 10.0))
         (bad (org-typst-inline--cache-key 'inline "#" "#000000" 10.0)))
    (unwind-protect
        (progn
          (org-typst-inline--request
           good (org-typst-inline--source 'inline "x^2" "#000000" 10.0))
          (org-typst-inline--request
           bad (org-typst-inline--source 'inline "#" "#000000" 10.0))
          (with-timeout (30 (ert-fail "Typst timed out"))
            (while (or (not (gethash good org-typst-inline--results))
                       (not (gethash bad org-typst-inline--results)))
              (accept-process-output nil 0.1)))
          (let ((file (gethash good org-typst-inline--results)))
            (should (stringp file))
            (should (file-exists-p file))
            (should (with-temp-buffer
                      (insert-file-contents file)
                      (search-forward "<svg" nil t))))
          (let ((result (gethash bad org-typst-inline--results)))
            (should (eq (car-safe result) 'error))
            (should (string-match-p "error" (cdr result)))))
      (delete-directory org-typst-inline-cache-directory t))))

;;; org-typst-inline-test.el ends here
