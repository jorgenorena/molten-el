;;; molten-display.el --- Overlay and full-buffer presentation -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Displays execution records without inserting into source buffers.
;;; Code:
(require 'molten-core)
(require 'ansi-color)
(require 'button)
(defcustom molten-inline-limit 500 "Maximum text characters shown inline."
  :type 'integer :group 'molten)
(defcustom molten-inline-lines 6 "Maximum text lines shown inline."
  :type 'integer :group 'molten)
(defvar-local molten-display-overlays nil)
(defun molten-display--image (data)
  "Return the richest supported Emacs image from DATA, or nil."
  (catch 'image
    (dolist (entry '(("image/svg+xml" . svg) ("image/png" . png)))
      (let ((payload (cdr (assoc (car entry) data))))
        (when (and payload (display-images-p) (image-type-available-p (cdr entry)))
          (let ((image (condition-case nil
                           (create-image payload (cdr entry) t :max-width 600 :max-height 300)
                         (error nil))))
            (when image (throw 'image image))))))))
(defun molten-display--output (o)
  "Return a display string for output O."
  (let* ((data (molten-output-data o)) (image (molten-display--image data)))
    (if image (propertize " " 'display image)
      (ansi-color-filter-apply
       (or (molten-output-text o) (cdr (assoc "text/plain" data))
           (and data "[Image saved; this Emacs cannot display it]") "")))))
(defun molten-display-text (e)
  "Return all output for E in arrival order."
  (concat
   (mapconcat (lambda (o)
                (let ((text (molten-display--output o)))
                  (if (or (eq (molten-output-kind o) 'stream) (string-suffix-p "\n" text))
                      text (concat text "\n"))))
              (molten-execution-outputs e) "")
   (when (and (molten-execution-traceback e)
              (not (cl-find 'error (molten-execution-outputs e) :key #'molten-output-kind)))
     (ansi-color-filter-apply (molten-execution-traceback e)))))
(defun molten-display-remove ()
  "Remove Molten overlays from the current buffer."
  (mapc #'delete-overlay molten-display-overlays)
  (setq molten-display-overlays nil))
(defun molten-display-render ()
  "Render the newest visible record for each source slot in this buffer."
  (molten-display-remove)
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (e molten-executions)
      (let ((slot (molten-execution-slot-id e)))
        (unless (gethash slot seen)
          (puthash slot t seen)
          (when (and (not (molten-execution-hidden e))
                     (markerp (molten-execution-start e))
                     (marker-buffer (molten-execution-start e)))
            (molten-execution-refresh e)
            (let* ((text (molten-display-text e))
                   (large (or (molten-execution-traceback e)
                              (> (length text) molten-inline-limit)
                              (> (cl-count ?\n text) molten-inline-lines)))
                   (ov (make-overlay (molten-execution-start e) (molten-execution-end e)
                                     nil nil t)))
              (overlay-put ov 'molten-execution e)
              (overlay-put ov 'evaporate nil)
              (overlay-put ov 'after-string
                           (concat (propertize
                                    (format "\n[Molten %s · %s%s]%s\n"
                                            (molten-execution-state e) (molten-execution-freshness e)
                                            (if (molten-execution-count e)
                                                (format " · %s" (molten-execution-count e)) "")
                                            (if large "  M-x molten-show-output" ""))
                                    'face 'shadow)
                                   (unless large text)))
              (push ov molten-display-overlays))))))))
(defun molten-display-updated (e)
  "Refresh the live presentation of E."
  (when (buffer-live-p (molten-execution-buffer e))
    (with-current-buffer (molten-execution-buffer e)
      (when (bound-and-true-p molten-mode) (molten-display-render)))))
(defun molten-display-show (e)
  "Show E in an ordinary read-only output buffer."
  (let ((buffer (get-buffer-create (format "*Molten %s*" (substring (molten-execution-id e) 0 12)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Execution %s\n%s · %s · kernel %s\n%s\n\nSource:\n%s\n\nOutput:\n"
                        (molten-execution-id e) (molten-execution-state e)
                        (molten-execution-freshness e) (or (molten-execution-kernel-name e) "unknown")
                        (format-time-string "%F %T" (seconds-to-time (molten-execution-timestamp e)))
                        (molten-anchor-source (molten-execution-anchor e))))
        (insert (molten-display-text e))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buffer)))
(provide 'molten-display)
;;; molten-display.el ends here
