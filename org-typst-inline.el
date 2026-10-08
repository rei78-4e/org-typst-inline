;;; org-typst-inline.el --- Inline Typst previews for Org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 rei78

;; Author: rei78 <senox78.am2@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Keywords: outlines, tex, multimedia
;; URL: https://github.com/rei78-4e/org-typst-inline

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `org-typst-inline-mode' renders Typst fragments in Org buffers as
;; inline SVG images and shows their source again while the cursor is
;; inside them, in the same way org-appear toggles emphasis markers and
;; links.
;;
;; Previewed elements:
;;
;; - LaTeX fragments `$...$', `\(...\)', `$$...$$' and `\[...\]', and
;;   LaTeX environments.  Their contents are read as Typst math, which
;;   is what ox-typst's `org-typst-from-latex-with-naive' assumes.
;; - Export snippets `@@typst:...@@', rendered as Typst markup.
;;
;; Only visible text is processed (through jit-lock), Typst runs
;; asynchronously, and results are cached in memory and on disk.
;;
;; When org-appear is loaded its `org-appear-trigger', `org-appear-delay'
;; and `org-appear-manual-linger' settings are followed, and
;; `org-appear-manual-start' / `org-appear-manual-stop' also toggle
;; Typst previews.  Without org-appear the `org-typst-inline-trigger',
;; `org-typst-inline-delay' and `org-typst-inline-manual-linger'
;; options are used.

;;; Code:

(require 'org)
(require 'org-element)
(require 'color)
(require 'face-remap)
(require 'jit-lock)
(require 'seq)
(require 'subr-x)

(defvar org-appear-trigger)
(defvar org-appear-delay)
(defvar org-appear-manual-linger)
(defvar org-fragtog-mode)

;;;; Customization

(defgroup org-typst-inline nil
  "Inline Typst previews for Org buffers."
  :group 'org
  :prefix "org-typst-inline-")

(defcustom org-typst-inline-typst-program "typst"
  "Name or absolute file name of the Typst executable."
  :type 'string)

(defcustom org-typst-inline-preamble ""
  "Typst source inserted after the generated page and text settings.
Use it for fonts or show rules, for example:

  #set text(font: \"New Computer Modern\")
  #show math.equation: set text(font: \"New Computer Modern Math\")"
  :type 'string)

(defcustom org-typst-inline-scale 1.0
  "Factor applied to the height of the `default' face when rendering."
  :type 'number)

(defcustom org-typst-inline-placeholder nil
  "What to display while a fragment is being compiled.
nil shows the source text with the `org-typst-inline-pending' face.
A string is displayed in place of the source text."
  :type '(choice (const :tag "Dimmed source text" nil)
                 (string :tag "Placeholder string")))

(defcustom org-typst-inline-cache-directory
  (locate-user-emacs-file "org-typst-inline/")
  "Directory where rendered SVG files are stored."
  :type 'directory)

(defcustom org-typst-inline-max-processes 4
  "Maximum number of Typst processes running at the same time."
  :type 'natnum)

(defcustom org-typst-inline-follow-org-appear t
  "Non-nil means use org-appear's settings when org-appear is loaded.
The settings are `org-appear-trigger', `org-appear-delay' and
`org-appear-manual-linger'."
  :type 'boolean)

(defcustom org-typst-inline-trigger 'always
  "When fragments under the cursor show their source.
`always' means every time the cursor enters a fragment.  `on-change'
means only after the buffer is modified or clicked with the mouse.
`manual' means between `org-typst-inline-manual-start' and
`org-typst-inline-manual-stop'.  Ignored when
`org-typst-inline-follow-org-appear' applies."
  :type '(choice (const :tag "Always" always)
                 (const :tag "Only on change" on-change)
                 (const :tag "Manual" manual)))

(defcustom org-typst-inline-delay 0.0
  "Seconds of idle time before the source of a fragment is shown.
Ignored when `org-typst-inline-follow-org-appear' applies."
  :type 'number)

(defcustom org-typst-inline-manual-linger nil
  "Non-nil means `org-typst-inline-manual-stop' keeps the source shown.
The fragment is then hidden when the cursor leaves it.  Ignored when
`org-typst-inline-follow-org-appear' applies."
  :type 'boolean)

(defface org-typst-inline-pending
  '((t :inherit shadow))
  "Face for fragments that are being compiled.")

(defface org-typst-inline-error
  '((t :inherit error :underline (:style wave)))
  "Face for fragments that failed to compile.")

;;;; State

(defvar org-typst-inline--results (make-hash-table :test #'equal)
  "Map from cache key to an SVG file name or (error . MESSAGE).")

(defvar org-typst-inline--running (make-hash-table :test #'equal)
  "Map from cache key to the Typst process compiling it.")

(defvar org-typst-inline--queue nil
  "Compilation jobs waiting to start, oldest first.
Each job is a list (KEY SOURCE DIRECTORY).")

(defvar-local org-typst-inline--prev nil
  "Overlay the cursor was in after the previous command.")

(defvar-local org-typst-inline--timer nil
  "Idle timer that will reveal an overlay, if any.")

(defvar-local org-typst-inline--do-buffer nil
  "Non-nil means the overlay at point should be revealed.
Set by buffer changes when the trigger is `on-change' and by
`org-typst-inline-manual-start'.")

(defvar-local org-typst-inline--toggled nil
  "Non-nil means `org-typst-inline--prev' is being revealed.")

(defvar-local org-typst-inline--changed nil
  "Non-nil means the current command modified the buffer.")

(defvar org-typst-inline-mode)

;;;; Settings

(defun org-typst-inline--appear-p ()
  "Return non-nil if org-appear's settings should be used."
  (and org-typst-inline-follow-org-appear (featurep 'org-appear)))

(defun org-typst-inline--trigger ()
  "Return the effective trigger method."
  (if (org-typst-inline--appear-p) org-appear-trigger org-typst-inline-trigger))

(defun org-typst-inline--delay ()
  "Return the effective reveal delay in seconds."
  (if (org-typst-inline--appear-p) org-appear-delay org-typst-inline-delay))

(defun org-typst-inline--linger-p ()
  "Return the effective value of the manual linger option."
  (if (org-typst-inline--appear-p)
      org-appear-manual-linger
    org-typst-inline-manual-linger))

;;;; Elements

(defconst org-typst-inline--delimiters
  '(("$$" "$$" display) ("\\[" "\\]" display) ("$" "$" inline) ("\\(" "\\)" inline))
  "Math delimiters as (OPEN CLOSE KIND), longest first.")

(defun org-typst-inline--split-math (value)
  "Return (KIND . BODY) for the LaTeX fragment VALUE, or nil.
KIND is `inline' or `display'.  Fragments that are LaTeX commands
such as \\foo{bar} return nil."
  (seq-some (pcase-lambda (`(,open ,close ,kind))
              (and (string-prefix-p open value)
                   (string-suffix-p close value)
                   (>= (length value) (+ (length open) (length close)))
                   (cons kind (substring value (length open) (- (length close))))))
            org-typst-inline--delimiters))

(defun org-typst-inline--environment-body (value)
  "Return the contents of the LaTeX environment VALUE.
The \\begin and \\end lines are dropped."
  (let ((lines (split-string (string-trim value) "\n")))
    (string-join (butlast (cdr lines)) "\n")))

(defun org-typst-inline--make-candidate (element kind body)
  "Return a candidate plist for ELEMENT of KIND whose Typst text is BODY.
The region covers ELEMENT without affiliated keywords and trailing
blanks.  Return nil if BODY is empty."
  (let* ((begin (or (org-element-property :post-affiliated element)
                    (org-element-property :begin element)))
         (end (save-excursion
                (goto-char (org-element-property :end element))
                (skip-chars-backward " \t\n" begin)
                (point))))
    (unless (or (string-empty-p body) (<= end begin))
      (list :kind kind :begin begin :end end :body body))))

(defun org-typst-inline--element-candidate (element)
  "Return a preview candidate for the Org ELEMENT, or nil.
A candidate is a plist with the keys :kind (`inline', `display' or
`snippet'), :begin, :end and :body (the Typst text to render).
Elements inside source blocks, example blocks, comments, verbatim
and code are parsed as those containers, so they never qualify."
  (let ((value (org-element-property :value element)))
    (pcase (org-element-type element)
      ('latex-fragment
       (when-let* ((math (org-typst-inline--split-math value)))
         (org-typst-inline--make-candidate
          element (car math) (string-trim (cdr math)))))
      ('latex-environment
       (org-typst-inline--make-candidate
        element 'display
        (string-trim (org-typst-inline--environment-body value))))
      ('export-snippet
       (when (equal (org-element-property :back-end element) "typst")
         (org-typst-inline--make-candidate element 'snippet value))))))

(defun org-typst-inline--candidate-at (pos)
  "Return the preview candidate for the Org object at POS, or nil."
  (save-excursion
    (goto-char pos)
    (org-typst-inline--element-candidate (org-element-context))))

;;;; Typst source and cache

(defun org-typst-inline--style ()
  "Return (COLOR . SIZE) for rendering, from the `default' face.
COLOR is a #RRGGBB string and SIZE a font size in points."
  (let* ((fg (face-attribute 'default :foreground nil t))
         (rgb (and (stringp fg) (ignore-errors (color-name-to-rgb fg))))
         (height (face-attribute 'default :height nil t)))
    (cons (if rgb (apply #'color-rgb-to-hex (append rgb '(2))) "#000000")
          (* org-typst-inline-scale
             (if (integerp height) (/ height 10.0) 10.0)))))

(defun org-typst-inline--source (kind body color size)
  "Return a Typst document rendering BODY of KIND with COLOR and SIZE."
  (concat "#set page(width: auto, height: auto, margin: 2pt, fill: none)\n"
          (format "#set text(size: %.2fpt, fill: rgb(\"%s\"))\n" size color)
          ;; Size the page by the glyphs' real extent.  The default
          ;; cap-height/baseline edges let descenders, subscripts and
          ;; denominators overflow the margin and get clipped.
          "#set text(top-edge: \"bounds\", bottom-edge: \"bounds\")\n"
          org-typst-inline-preamble "\n"
          (pcase kind
            ('inline (format "$%s$" body))
            ('display (format "$ %s $" body))
            (_ body))
          "\n"))

(defconst org-typst-inline--template-version 2
  "Version of the template in `org-typst-inline--source'.
Bump it whenever the template changes so stale images are not reused.")

(defun org-typst-inline--cache-key (kind body color size)
  "Return the cache key for BODY of KIND rendered with COLOR and SIZE."
  (secure-hash 'sha1 (prin1-to-string
                      (list org-typst-inline--template-version
                            kind body color (format "%.2f" size)
                            org-typst-inline-preamble
                            org-typst-inline-typst-program))))

(defun org-typst-inline--cache-file (key)
  "Return the SVG file name for cache KEY."
  (expand-file-name (concat key ".svg") org-typst-inline-cache-directory))

;;;; Compilation

(defun org-typst-inline--request (key source)
  "Make sure the image for KEY is compiled from SOURCE.
If the image is already on disk it is registered immediately,
otherwise a Typst process is queued."
  (let ((file (org-typst-inline--cache-file key)))
    (cond
     ((gethash key org-typst-inline--results))
     ((file-exists-p file) (puthash key file org-typst-inline--results))
     ((or (gethash key org-typst-inline--running)
          (assoc key org-typst-inline--queue)))
     (t
      (setq org-typst-inline--queue
            (append org-typst-inline--queue
                    (list (list key source
                                (unless (file-remote-p default-directory)
                                  default-directory)))))
      (org-typst-inline--drain)))))

(defun org-typst-inline--drain ()
  "Start queued jobs while fewer than the maximum are running."
  (while (and org-typst-inline--queue
              (< (hash-table-count org-typst-inline--running)
                 (max 1 org-typst-inline-max-processes)))
    (pcase-let ((`(,key ,source ,dir) (pop org-typst-inline--queue)))
      (org-typst-inline--start key source dir))))

(defun org-typst-inline--start (key source dir)
  "Compile SOURCE into the cache file for KEY, running in DIR."
  (let* ((file (org-typst-inline--cache-file key))
         (tmp (concat file ".tmp"))
         (buffer (generate-new-buffer " *org-typst-inline*"))
         (default-directory (if (and dir (file-directory-p dir))
                                dir
                              temporary-file-directory)))
    (condition-case err
        (let ((proc (make-process
                     :name "org-typst-inline"
                     :buffer buffer
                     :command (list org-typst-inline-typst-program
                                    "compile" "--format" "svg"
                                    "--diagnostic-format" "short"
                                    "-" tmp)
                     :connection-type 'pipe
                     :noquery t
                     :sentinel #'org-typst-inline--sentinel)))
          (make-directory (file-name-directory file) t)
          (process-put proc 'org-typst-inline-key key)
          (process-put proc 'org-typst-inline-tmp tmp)
          (process-put proc 'org-typst-inline-file file)
          (puthash key proc org-typst-inline--running)
          (process-send-string proc source)
          (process-send-eof proc))
      (error
       (kill-buffer buffer)
       (org-typst-inline--finish key (cons 'error (error-message-string err)))))))

(defun org-typst-inline--sentinel (proc _event)
  "Handle the end of the Typst process PROC."
  (unless (process-live-p proc)
    (let* ((key (process-get proc 'org-typst-inline-key))
           (tmp (process-get proc 'org-typst-inline-tmp))
           (file (process-get proc 'org-typst-inline-file))
           (buffer (process-buffer proc))
           (output (if (buffer-live-p buffer)
                       (with-current-buffer buffer (string-trim (buffer-string)))
                     ""))
           (result
            (if (and (eq (process-status proc) 'exit)
                     (zerop (process-exit-status proc))
                     (file-exists-p tmp))
                (progn (rename-file tmp file t) file)
              (when (file-exists-p tmp) (delete-file tmp))
              (cons 'error
                    (if (string-empty-p output)
                        (format "%s exited with status %d"
                                org-typst-inline-typst-program
                                (process-exit-status proc))
                      output)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (org-typst-inline--finish key result))))

(defun org-typst-inline--finish (key result)
  "Record RESULT for KEY and update the overlays that show it."
  (remhash key org-typst-inline--running)
  (puthash key result org-typst-inline--results)
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'org-typst-inline-mode buffer)
      (with-current-buffer buffer
        (dolist (ov (org-typst-inline--all-overlays))
          (when (equal (overlay-get ov 'org-typst-inline-key) key)
            (org-typst-inline--render ov))))))
  (org-typst-inline--drain))

;;;; Overlays

(defun org-typst-inline--overlays-in (start end)
  "Return the preview overlays between START and END."
  (seq-filter (lambda (ov) (overlay-get ov 'org-typst-inline))
              (overlays-in start end)))

(defun org-typst-inline--all-overlays ()
  "Return all preview overlays in the current buffer."
  (save-restriction
    (widen)
    (org-typst-inline--overlays-in (point-min) (point-max))))

(defun org-typst-inline--remove-overlays ()
  "Delete all preview overlays in the current buffer."
  (mapc #'delete-overlay (org-typst-inline--all-overlays)))

(defun org-typst-inline--overlay-at (pos)
  "Return the preview overlay whose element contains POS, or nil.
Both ends count as inside, so the cursor right after a fragment
also reveals it."
  (seq-find (lambda (ov) (<= (overlay-start ov) pos (overlay-end ov)))
            (org-typst-inline--overlays-in (max (point-min) (1- pos))
                                           (min (point-max) (1+ pos)))))

(defun org-typst-inline--text-scale ()
  "Return the image scale for the current `text-scale-mode' amount."
  (if (bound-and-true-p text-scale-mode)
      (expt text-scale-mode-step text-scale-mode-amount)
    1.0))

(defun org-typst-inline--display-strings (ov image)
  "Return (BEFORE . AFTER) strings that center IMAGE of OV on its own line."
  (let ((bol (save-excursion
               (goto-char (overlay-start ov))
               (skip-chars-backward " \t")
               (bolp)))
        (eol (save-excursion
               (goto-char (overlay-end ov))
               (skip-chars-forward " \t")
               (eolp))))
    (cons (concat (unless bol "\n")
                  (propertize " " 'display
                              `(space :align-to (- center (0.5 . ,image)))))
          (unless eol "\n"))))

(defun org-typst-inline--render (ov)
  "Update the display properties of OV from its state and result."
  (when (overlay-buffer ov)
    (dolist (prop '(display face help-echo before-string after-string))
      (overlay-put ov prop nil))
    (unless (overlay-get ov 'org-typst-inline-revealed)
      (let ((source (buffer-substring-no-properties (overlay-start ov)
                                                    (overlay-end ov))))
        (pcase (gethash (overlay-get ov 'org-typst-inline-key)
                        org-typst-inline--results)
          ((and (pred stringp) file)
           (let ((image (create-image file 'svg nil
                                      :ascent 'center
                                      :scale (org-typst-inline--text-scale))))
             (overlay-put ov 'display image)
             (overlay-put ov 'help-echo source)
             (when (eq (overlay-get ov 'org-typst-inline-kind) 'display)
               (let ((strings (org-typst-inline--display-strings ov image)))
                 (overlay-put ov 'before-string (car strings))
                 (overlay-put ov 'after-string (cdr strings))))))
          (`(error . ,message)
           (overlay-put ov 'face 'org-typst-inline-error)
           (overlay-put ov 'help-echo message))
          (_
           (if org-typst-inline-placeholder
               (overlay-put ov 'display org-typst-inline-placeholder)
             (overlay-put ov 'face 'org-typst-inline-pending))
           (overlay-put ov 'help-echo "Compiling with Typst...")))))))

(defun org-typst-inline--reveal (ov)
  "Show the source text of OV."
  (when (and (overlay-buffer ov)
             (not (overlay-get ov 'org-typst-inline-revealed)))
    (overlay-put ov 'org-typst-inline-revealed t)
    (org-typst-inline--render ov)))

(defun org-typst-inline--conceal (ov)
  "Show the rendered preview of OV, compiling it if needed."
  (when (overlay-buffer ov)
    (overlay-put ov 'org-typst-inline-revealed nil)
    (org-typst-inline--request (overlay-get ov 'org-typst-inline-key)
                               (overlay-get ov 'org-typst-inline-source))
    (org-typst-inline--render ov)))

(defun org-typst-inline--reveal-on-create-p (ov pos)
  "Return non-nil if OV, created with the cursor at POS, starts revealed."
  (and (<= (overlay-start ov) pos (overlay-end ov))
       (pcase (org-typst-inline--trigger)
         ('always t)
         ('on-change (or org-typst-inline--changed
                         org-typst-inline--do-buffer
                         org-typst-inline--toggled))
         (_ (or org-typst-inline--do-buffer org-typst-inline--toggled)))))

(defun org-typst-inline--create (candidate pos revealed)
  "Create an overlay for CANDIDATE with the cursor at POS.
REVEALED is a list of (BEGIN . END) ranges of revealed overlays that
were just replaced; an overlapping new overlay stays revealed."
  (let* ((begin (plist-get candidate :begin))
         (end (plist-get candidate :end))
         (kind (plist-get candidate :kind))
         (body (plist-get candidate :body))
         (style (org-typst-inline--style))
         (ov (make-overlay begin end nil t nil)))
    (overlay-put ov 'org-typst-inline t)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'org-typst-inline-kind kind)
    (overlay-put ov 'org-typst-inline-body body)
    (overlay-put ov 'org-typst-inline-key
                 (org-typst-inline--cache-key kind body (car style) (cdr style)))
    (overlay-put ov 'org-typst-inline-source
                 (org-typst-inline--source kind body (car style) (cdr style)))
    (if (or (seq-some (lambda (range)
                        (and (<= (car range) end) (>= (cdr range) begin)))
                      revealed)
            (org-typst-inline--reveal-on-create-p ov pos))
        (progn
          (org-typst-inline--reveal ov)
          (setq org-typst-inline--prev ov
                org-typst-inline--toggled t))
      (org-typst-inline--conceal ov))
    ov))

(defun org-typst-inline--current-p (ov candidate)
  "Return non-nil if OV still matches CANDIDATE."
  (and candidate
       (= (overlay-start ov) (plist-get candidate :begin))
       (= (overlay-end ov) (plist-get candidate :end))
       (eq (overlay-get ov 'org-typst-inline-kind) (plist-get candidate :kind))
       (equal (overlay-get ov 'org-typst-inline-body) (plist-get candidate :body))))

(defconst org-typst-inline--search-regexp
  "\\$\\|\\\\[[(]\\|@@typst:\\|^[ \t]*\\\\begin{"
  "Regexp matching text that may start a previewed element.")

(defun org-typst-inline--update (start end pos)
  "Synchronize preview overlays between START and END.
POS is the cursor position.  Overlays whose element changed are
replaced; elements without an overlay get one."
  (let (revealed)
    (dolist (ov (org-typst-inline--overlays-in start end))
      (unless (org-typst-inline--current-p
               ov (org-typst-inline--candidate-at (overlay-start ov)))
        (when (overlay-get ov 'org-typst-inline-revealed)
          (push (cons (overlay-start ov) (overlay-end ov)) revealed))
        (delete-overlay ov)))
    (goto-char start)
    (while (re-search-forward org-typst-inline--search-regexp end t)
      (when-let* ((candidate (org-typst-inline--candidate-at (match-beginning 0))))
        (unless (seq-find (lambda (ov) (org-typst-inline--current-p ov candidate))
                          (org-typst-inline--overlays-in
                           (plist-get candidate :begin) (plist-get candidate :end)))
          (org-typst-inline--create candidate pos revealed))
        (goto-char (max (point) (plist-get candidate :end)))))))

(defun org-typst-inline--fontify (start end)
  "Jit-lock function updating previews between START and END."
  (let ((pos (point)))
    (condition-case-unless-debug err
        (save-excursion
          (save-match-data
            (org-typst-inline--update start end pos)))
      (error (message "org-typst-inline: %s" (error-message-string err)))))
  nil)

;;;; Cursor tracking

(defun org-typst-inline--reveal-delayed (buffer ov)
  "Reveal OV in BUFFER after the idle delay."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq org-typst-inline--timer nil)
      (when (eq ov org-typst-inline--prev)
        (org-typst-inline--reveal ov)))))

(defun org-typst-inline--post-command ()
  "Reveal the preview at point and conceal the one the cursor left."
  (condition-case-unless-debug err
      (let* ((prev org-typst-inline--prev)
             (current (org-typst-inline--overlay-at (point)))
             (trigger (org-typst-inline--trigger)))
        (when (and prev (not (eq prev current)))
          (when org-typst-inline--timer
            (cancel-timer org-typst-inline--timer)
            (setq org-typst-inline--timer nil))
          (when org-typst-inline--toggled
            (setq org-typst-inline--toggled nil)
            (org-typst-inline--conceal prev)))
        (when (and current (or (eq trigger 'always)
                               org-typst-inline--do-buffer
                               org-typst-inline--toggled))
          (setq org-typst-inline--toggled t)
          (let ((delay (org-typst-inline--delay)))
            (if (and (eq trigger 'always)
                     (> delay 0)
                     (not (eq prev current)))
                (setq org-typst-inline--timer
                      (run-with-idle-timer delay nil
                                           #'org-typst-inline--reveal-delayed
                                           (current-buffer) current))
              (unless org-typst-inline--timer
                (org-typst-inline--reveal current)))))
        (setq org-typst-inline--prev current)
        (unless (eq trigger 'manual)
          (setq org-typst-inline--do-buffer nil)))
    (error (message "org-typst-inline: %s" (error-message-string err)))))

(defun org-typst-inline--pre-command ()
  "Forget that the previous command changed the buffer."
  (setq org-typst-inline--changed nil))

(defun org-typst-inline--after-change (&rest _)
  "Record a buffer change or mouse click for the trigger logic."
  (setq org-typst-inline--changed t)
  (when (eq (org-typst-inline--trigger) 'on-change)
    (setq org-typst-inline--do-buffer t)))

;;;###autoload
(defun org-typst-inline-manual-start ()
  "Start revealing the preview under the cursor.
Used when the trigger is `manual'."
  (interactive)
  (when org-typst-inline-mode
    (setq org-typst-inline--do-buffer t)))

;;;###autoload
(defun org-typst-inline-manual-stop ()
  "Stop revealing the preview under the cursor.
Used when the trigger is `manual'."
  (interactive)
  (when org-typst-inline-mode
    (unless (org-typst-inline--linger-p)
      (when-let* ((ov (org-typst-inline--overlay-at (point))))
        (org-typst-inline--conceal ov))
      (setq org-typst-inline--toggled nil))
    (setq org-typst-inline--do-buffer nil)))

(defun org-typst-inline--appear-manual-start ()
  "Follow `org-appear-manual-start'."
  (when org-typst-inline-follow-org-appear
    (org-typst-inline-manual-start)))

(defun org-typst-inline--appear-manual-stop ()
  "Follow `org-appear-manual-stop'."
  (when org-typst-inline-follow-org-appear
    (org-typst-inline-manual-stop)))

(defun org-typst-inline--install-appear-advice ()
  "Make org-appear's manual commands toggle previews too."
  (when (fboundp 'org-appear-manual-start)
    (advice-add 'org-appear-manual-start :after
                #'org-typst-inline--appear-manual-start)
    (advice-add 'org-appear-manual-stop :after
                #'org-typst-inline--appear-manual-stop)))

;;;; Global events

(defun org-typst-inline--rerender ()
  "Redisplay every preview in the current buffer."
  (mapc #'org-typst-inline--render (org-typst-inline--all-overlays)))

(defun org-typst-inline--mode-buffers ()
  "Return the buffers where `org-typst-inline-mode' is enabled."
  (seq-filter (lambda (buffer)
                (buffer-local-value 'org-typst-inline-mode buffer))
              (buffer-list)))

(defun org-typst-inline--theme-changed (&rest _)
  "Re-render all previews with the colors of the new theme."
  (dolist (buffer (org-typst-inline--mode-buffers))
    (with-current-buffer buffer
      (org-typst-inline-refresh))))

(defun org-typst-inline--check-fragtog ()
  "Warn if `org-fragtog-mode' is enabled together with this mode."
  (when (and org-typst-inline-mode (bound-and-true-p org-fragtog-mode))
    (display-warning
     'org-typst-inline
     (format "`org-fragtog-mode' is enabled in %s; it also toggles LaTeX \
fragment previews and conflicts with `org-typst-inline-mode'"
             (buffer-name))
     :warning)))

;;;; Commands

;;;###autoload
(defun org-typst-inline-refresh ()
  "Re-render every Typst preview in the current buffer.
Failed compilations are retried."
  (interactive)
  (unless org-typst-inline-mode
    (user-error "`org-typst-inline-mode' is not enabled"))
  (maphash (lambda (key result)
             (when (consp result)
               (remhash key org-typst-inline--results)))
           org-typst-inline--results)
  (org-typst-inline--remove-overlays)
  (setq org-typst-inline--prev nil
        org-typst-inline--toggled nil)
  (jit-lock-refontify))

;;;###autoload
(defun org-typst-inline-clear-cache ()
  "Delete cached previews from memory and disk, then re-render."
  (interactive)
  (clrhash org-typst-inline--results)
  (when (file-directory-p org-typst-inline-cache-directory)
    (dolist (file (directory-files org-typst-inline-cache-directory t
                                   "\\.svg\\'"))
      (delete-file file)))
  (clear-image-cache)
  (dolist (buffer (org-typst-inline--mode-buffers))
    (with-current-buffer buffer
      (org-typst-inline-refresh))))

;;;###autoload
(define-minor-mode org-typst-inline-mode
  "Render Typst fragments inline and reveal them under the cursor.
LaTeX fragments and environments are rendered as Typst math and
`@@typst:...@@' export snippets as Typst markup.  The source of an
element is shown while the cursor is inside it, following
`org-appear-trigger' and `org-appear-delay' when org-appear is
loaded."
  :lighter " Typ"
  (cond
   (org-typst-inline-mode
    (add-hook 'post-command-hook #'org-typst-inline--post-command nil t)
    (add-hook 'pre-command-hook #'org-typst-inline--pre-command nil t)
    (add-hook 'after-change-functions #'org-typst-inline--after-change nil t)
    (add-hook 'mouse-leave-buffer-hook #'org-typst-inline--after-change nil t)
    (add-hook 'text-scale-mode-hook #'org-typst-inline--rerender nil t)
    (add-hook 'enable-theme-functions #'org-typst-inline--theme-changed)
    (add-hook 'disable-theme-functions #'org-typst-inline--theme-changed)
    (add-hook 'org-fragtog-mode-hook #'org-typst-inline--check-fragtog)
    (add-hook 'org-appear-mode-hook #'org-typst-inline--install-appear-advice)
    (org-typst-inline--install-appear-advice)
    (org-typst-inline--check-fragtog)
    (jit-lock-register #'org-typst-inline--fontify))
   (t
    (jit-lock-unregister #'org-typst-inline--fontify)
    (remove-hook 'post-command-hook #'org-typst-inline--post-command t)
    (remove-hook 'pre-command-hook #'org-typst-inline--pre-command t)
    (remove-hook 'after-change-functions #'org-typst-inline--after-change t)
    (remove-hook 'mouse-leave-buffer-hook #'org-typst-inline--after-change t)
    (remove-hook 'text-scale-mode-hook #'org-typst-inline--rerender t)
    (when org-typst-inline--timer
      (cancel-timer org-typst-inline--timer))
    (org-typst-inline--remove-overlays)
    (setq org-typst-inline--prev nil
          org-typst-inline--timer nil
          org-typst-inline--do-buffer nil
          org-typst-inline--toggled nil
          org-typst-inline--changed nil))))

(provide 'org-typst-inline)
;;; org-typst-inline.el ends here
