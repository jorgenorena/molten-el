;;; molten-core.el --- Execution records and source anchors -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Transport-independent records.  Presentation and storage subscribe to updates.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(defgroup molten nil "Source region execution on Jupyter servers." :group 'tools)
(cl-defstruct molten-session id url token kernel-id kernel-name socket
              (state 'disconnected) (executions (make-hash-table :test #'equal)))
(cl-defstruct molten-anchor file line end-line source hash before after)
(cl-defstruct molten-output kind name text data metadata)
(cl-defstruct molten-execution id buffer file start end anchor timestamp
              session-id kernel-id kernel-name (state 'queued) count
              (stdout "") (stderr "") traceback outputs reply idle
              (freshness 'fresh) slot-id hidden)
(defvar molten-execution-updated-hook nil
  "Functions called with an execution whenever its record changes.")
(defvar-local molten-executions nil "Execution history, newest first.")
(defun molten-id ()
  "Return a unique opaque identifier without external programs."
  (secure-hash 'sha256 (format "%s:%s:%s:%s" (current-time) (emacs-pid)
                               (random) (buffer-name))))
(defun molten-hash (source)
  "Return the SHA256 of UTF-8 SOURCE."
  (secure-hash 'sha256 (encode-coding-string source 'utf-8-unix)))
(defun molten-anchor-create (beg end)
  "Capture a persistent anchor for BEG through END in the current buffer."
  (save-restriction
    (widen)
    (let ((source (buffer-substring-no-properties beg end)))
      (make-molten-anchor
       :file (and buffer-file-name (expand-file-name buffer-file-name))
       :line (line-number-at-pos beg) :end-line (line-number-at-pos end)
       :source source :hash (molten-hash source)
       :before (buffer-substring-no-properties (max (point-min) (- beg 120)) beg)
       :after (buffer-substring-no-properties end (min (point-max) (+ end 120)))))))
(defun molten--occurrences (text)
  "Return all start positions of nonempty TEXT in the widened buffer."
  (when (and text (not (string-empty-p text)))
    (save-excursion
      (goto-char (point-min))
      (let (positions)
        (while (search-forward text nil t)
          (push (- (point) (length text)) positions)
          (goto-char (1+ (- (point) (length text)))))
        (nreverse positions)))))
(defun molten-anchor-locate (anchor)
  "Return (BEG END FRESHNESS) for ANCHOR, or nil if ambiguous.
Unique exact source wins unless enclosing context identifies an expanded
range.  Changed source requires unique nonempty context on both sides;
line numbers alone never justify attachment."
  (save-restriction
    (widen)
    (let* ((source (molten-anchor-source anchor))
           (matches (molten--occurrences source))
           (before (molten-anchor-before anchor))
           (left (molten--occurrences before))
           (right (molten--occurrences (molten-anchor-after anchor)))
           (beg (and (= (length left) 1) (+ (car left) (length before))))
           (end (and (= (length right) 1) (car right)))
           (context (and beg end (<= beg end))))
      (cond
       ((= (length matches) 1)
        (let ((exact-beg (car matches)) (exact-end (+ (car matches) (length source))))
          (if (and context (<= beg exact-beg) (<= exact-end end)
                   (or (/= beg exact-beg) (/= end exact-end)))
              (list beg end 'stale)
            (list exact-beg exact-end 'fresh))))
       ;; Duplicate exact matches are intentionally orphaned.
       ((and (null matches) context) (list beg end 'stale))))))
(defun molten-execution-create (session beg end)
  "Create an execution in SESSION for BEG through END, preserving history."
  (when (>= beg end) (user-error "Select a nonempty source region"))
  (let* ((previous (cl-find-if
                    (lambda (e) (and (markerp (molten-execution-start e))
                                     (equal (marker-position (molten-execution-start e)) beg)
                                     (equal (marker-position (molten-execution-end e)) end)))
                    molten-executions))
         (id (molten-id))
         (e (make-molten-execution
             :id id :buffer (current-buffer) :file buffer-file-name
             :start (copy-marker beg) :end (copy-marker end t)
             :anchor (molten-anchor-create beg end) :timestamp (float-time)
             :session-id (molten-session-id session)
             :kernel-id (molten-session-kernel-id session)
             :kernel-name (molten-session-kernel-name session)
             :slot-id (if previous (molten-execution-slot-id previous) id))))
    (push e molten-executions)
    (puthash id e (molten-session-executions session))
    e))
(defun molten-execution-refresh (e)
  "Recompute source-only freshness of live execution E."
  (let ((start (molten-execution-start e)) (end (molten-execution-end e)))
    (when (and (markerp start) (marker-buffer start) (marker-position end))
      (with-current-buffer (marker-buffer start)
        (save-restriction
          (widen)
          (setf (molten-execution-freshness e)
                (if (equal (molten-anchor-hash (molten-execution-anchor e))
                           (molten-hash (buffer-substring-no-properties start end)))
                    'fresh 'stale)))))))
(defun molten-execution-notify (e)
  "Publish an update to E."
  (molten-execution-refresh e)
  (run-hook-with-args 'molten-execution-updated-hook e))
(defun molten-execution-add-output (e output)
  "Append OUTPUT to E in arrival order."
  (setf (molten-execution-outputs e)
        (nconc (molten-execution-outputs e) (list output)))
  (when (eq (molten-output-kind output) 'stream)
    (if (equal (molten-output-name output) "stderr")
        (setf (molten-execution-stderr e)
              (concat (molten-execution-stderr e) (molten-output-text output)))
      (setf (molten-execution-stdout e)
            (concat (molten-execution-stdout e) (molten-output-text output))))))
(defun molten-json-read (text)
  "Parse TEXT using only the built-in Elisp JSON reader."
  (let ((json-object-type 'alist) (json-array-type 'list)
        (json-key-type 'string) (json-false nil) (json-null nil))
    (json-read-from-string text)))
(defun molten-get (key object) "Get string KEY from JSON OBJECT." (cdr (assoc key object)))
(provide 'molten-core)
;;; molten-core.el ends here
