;;; molten.el --- Persistent source-region execution on Jupyter -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (websocket "1.12"))
;; Keywords: processes, tools
;;; Commentary:
;; Execute arbitrary source regions on an existing Jupyter Server, with pure
;; Elisp HTTP/WebSocket transport.  Require this package to restore file outputs
;; offline.  See README.md for setup and the SSH forwarding workflow.
;;; Code:
(require 'molten-core)
(require 'molten-store)
(require 'molten-display)
(require 'molten-jupyter)
(defcustom molten-server-url "http://127.0.0.1:8888"
  "Jupyter Server base URL, including any deployment path prefix."
  :type 'string :group 'molten)
(defcustom molten-auto-restore t "Restore saved outputs when visiting files."
  :type 'boolean :group 'molten)
(defvar molten-current-session nil "Current server/kernel session; token stays in memory.")
(defun molten--session ()
  "Return the current session or signal a useful error."
  (or molten-current-session (user-error "Run molten-connect first")))
(defun molten--persist (e)
  "Save E, reporting storage failures without breaking transport callbacks."
  (condition-case err (molten-store-save e)
    (error (display-warning 'molten (format "Output was not saved: %s" (error-message-string err))))))
(add-hook 'molten-execution-updated-hook #'molten--persist)
(add-hook 'molten-execution-updated-hook #'molten-display-updated)
(defun molten--after-change (&rest _)
  "Update source-only freshness after an edit."
  (molten-display-render))
;;;###autoload
(define-minor-mode molten-mode
  "Display and restore execution records in the current source buffer."
  :lighter " Molten"
  (if molten-mode
      (progn
        (unless molten-executions (molten-store-restore))
        (add-hook 'after-change-functions #'molten--after-change nil t)
        (molten-display-render))
    (remove-hook 'after-change-functions #'molten--after-change t)
    (molten-display-remove)))
(defun molten--maybe-restore ()
  "Restore saved records for a visited file without connecting to a server."
  (when (and molten-auto-restore buffer-file-name)
    (molten-store-restore)
    (when molten-executions (molten-mode 1))))
(add-hook 'find-file-hook #'molten--maybe-restore)
;;;###autoload
(defun molten-connect (url token)
  "Connect to server base URL using memory-only TOKEN (empty for no auth)."
  (interactive (list (read-string "Jupyter Server URL: " molten-server-url)
                     (read-passwd "Jupyter token (empty for none): ")))
  (let ((s (molten-jupyter-session url token)))
    (molten-jupyter-list-kernels s)
    (when molten-current-session (molten-jupyter-close molten-current-session))
    (setq molten-current-session s)
    (message "Molten server connected; select or start a kernel")))
;;;###autoload
(defun molten-start-kernel (name)
  "Start kernel spec NAME on the connected server."
  (interactive (list (read-string "Kernel spec: " "python3")))
  (molten-jupyter-start (molten--session) name))
;;;###autoload
(defun molten-select-kernel ()
  "List existing kernels and connect to the selected one."
  (interactive)
  (let* ((s (molten--session))
         (choices (mapcar (lambda (model)
                            (cons (format "%s (%s)" (molten-get "name" model) (molten-get "id" model)) model))
                          (molten-jupyter-list-kernels s))))
    (unless choices (user-error "No running kernels; use molten-start-kernel"))
    (molten-jupyter-select s (cdr (assoc (completing-read "Kernel: " choices nil t) choices)))))
;;;###autoload
(defun molten-eval-region (beg end)
  "Execute exactly BEG through END asynchronously on the selected kernel."
  (interactive "r")
  (let ((s (molten--session)))
    (unless (eq (molten-session-state s) 'ready) (user-error "Wait for kernel channels or select a kernel"))
    (unless molten-mode (molten-mode 1))
    (let ((e (molten-execution-create s beg end)))
      (molten-execution-notify e)
      (molten-jupyter-execute s e)
      e)))
;;;###autoload
(defun molten-eval-line ()
  "Execute the current line."
  (interactive)
  (molten-eval-region (line-beginning-position) (line-end-position)))
(defun molten--at-point ()
  "Return the newest execution containing point or signal an error."
  (or (cl-find-if (lambda (e)
                    (and (markerp (molten-execution-start e))
                         (marker-buffer (molten-execution-start e))
                         (<= (molten-execution-start e) (point) (molten-execution-end e))))
                  molten-executions)
      (user-error "No execution at point; use molten-output-history")))
;;;###autoload
(defun molten-reeval ()
  "Execute the current live source range of the record at point."
  (interactive)
  (let ((e (molten--at-point)))
    (molten-eval-region (marker-position (molten-execution-start e))
                        (marker-position (molten-execution-end e)))))
;;;###autoload
(defun molten-show-output ()
  "Show full output for the execution at point."
  (interactive)
  (molten-display-show (molten--at-point)))
;;;###autoload
(defun molten-clear-output ()
  "Hide the current output at point, preserving its saved execution history."
  (interactive)
  (let ((e (molten--at-point)))
    (setf (molten-execution-hidden e) t)
    (molten-execution-notify e)))
;;;###autoload
(defun molten-output-history ()
  "Show current buffer execution history, including orphaned and hidden records."
  (interactive)
  (let ((records molten-executions) (buffer (get-buffer-create "*Molten history*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Molten execution history (newest first)\n\n")
        (dolist (e records)
          (molten-execution-refresh e)
          (insert-text-button
           (format "%s  %s/%s  line %s  %s"
                   (format-time-string "%F %T" (seconds-to-time (molten-execution-timestamp e)))
                   (molten-execution-state e) (molten-execution-freshness e)
                   (molten-anchor-line (molten-execution-anchor e))
                   (truncate-string-to-width (replace-regexp-in-string "\n" " "
                                              (molten-anchor-source (molten-execution-anchor e))) 60 nil nil t))
           'follow-link t 'action (lambda (_) (molten-display-show e)))
          (insert "\n"))
        (goto-char (point-min)) (special-mode)))
    (pop-to-buffer buffer)))
;;;###autoload
(defun molten-interrupt () "Interrupt the selected kernel." (interactive)
  (molten-jupyter-interrupt (molten--session)))
;;;###autoload
(defun molten-restart-kernel () "Restart the selected kernel, losing its variables." (interactive)
  (molten-jupyter-restart (molten--session)))
;;;###autoload
(defun molten-kill-kernel () "Shut down the selected kernel; preserve saved outputs." (interactive)
  (molten-jupyter-kill (molten--session)))
(provide 'molten)
;;; molten.el ends here
