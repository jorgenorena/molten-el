;;; molten-store.el --- Persistent execution records -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; One atomic JSON document per execution; payloads are content-addressed blobs.
;;; Code:
(require 'molten-core)
(require 'json)
(defcustom molten-state-directory
  (expand-file-name "molten/" (or (getenv "XDG_STATE_HOME")
                                 (expand-file-name "~/.local/state/")))
  "Directory containing private execution records and blobs."
  :type 'directory :group 'molten)
(defun molten-store--write (path bytes)
  "Atomically write BYTES to PATH with private permissions."
  (let ((dir (file-name-directory path)) temp)
    (make-directory dir t)
    (set-file-modes dir #o700)
    (unwind-protect
        (progn
          (setq temp (make-temp-file (expand-file-name ".write-" dir)))
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil temp nil 'silent))
          (set-file-modes temp #o600)
          (rename-file temp path t)
          (setq temp nil))
      (when (and temp (file-exists-p temp)) (delete-file temp)))))
(defun molten-store--blob (text &optional binary)
  "Store TEXT, optionally BINARY, and return a blob reference."
  (let* ((bytes (if binary text (encode-coding-string text 'utf-8-unix)))
         (hash (secure-hash 'sha256 bytes))
         (path (expand-file-name (concat "blobs/" hash) molten-state-directory)))
    (unless (file-exists-p path) (molten-store--write path bytes))
    `(("blob" . ,hash) ("binary" . ,(if binary t :json-false)))))
(defun molten-store--read-blob (ref)
  "Read and verify REF."
  (let ((hash (molten-get "blob" ref)))
    (unless (and (stringp hash) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" hash))
      (error "Invalid Molten blob reference"))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally
       (expand-file-name (concat "blobs/" hash) molten-state-directory))
      (unless (equal hash (secure-hash 'sha256 (current-buffer)))
        (error "Corrupt Molten blob %s" hash))
      (if (molten-get "binary" ref) (buffer-string)
        (decode-coding-string (buffer-string) 'utf-8-unix)))))
(defun molten-store--fields (prefix fields record)
  "Extract allowlisted FIELDS using PREFIX accessors from RECORD."
  (mapcar (lambda (field)
            (cons (symbol-name field)
                  (funcall (intern (concat prefix (symbol-name field))) record))) fields))
(defun molten-store-save (e)
  "Persist execution E without session objects, transport handles or credentials."
  (when (molten-execution-file e)
    (let* ((a (molten-execution-anchor e))
           (record
            (append
             `(("version" . 1)
               ("state" . ,(symbol-name (molten-execution-state e)))
               ("anchor" . ,(molten-store--fields
                              "molten-anchor-" '(file line end-line source hash before after) a))
               ("outputs" .
                ,(vconcat
                  (mapcar
                   (lambda (o)
                     `(("kind" . ,(symbol-name (molten-output-kind o)))
                       ("name" . ,(molten-output-name o))
                       ("metadata" . ,(molten-output-metadata o))
                       ("text" . ,(and (molten-output-text o)
                                        (molten-store--blob (molten-output-text o))))
                       ("data" . ,(mapcar
                                    (lambda (pair)
                                      (cons (car pair) (molten-store--blob
                                                        (cdr pair) (equal (car pair) "image/png"))))
                                    (molten-output-data o)))))
                   (molten-execution-outputs e))))
               ("traceback" . ,(and (molten-execution-traceback e)
                                     (molten-store--blob (molten-execution-traceback e)))))
             (molten-store--fields "molten-execution-"
                                  '(id file timestamp session-id kernel-id kernel-name count slot-id hidden) e))))
      (molten-store--write
       (expand-file-name (concat "records/" (molten-execution-id e) ".json")
                         molten-state-directory)
       (encode-coding-string (json-encode record) 'utf-8-unix)))))
(defun molten-store--decode (r)
  "Decode stored record R into an execution."
  (unless (equal (molten-get "version" r) 1) (error "Unknown Molten storage version"))
  (let* ((a (molten-get "anchor" r))
         (e (make-molten-execution
             :id (molten-get "id" r) :file (molten-get "file" r)
             :timestamp (molten-get "timestamp" r)
             :session-id (molten-get "session-id" r)
             :kernel-id (molten-get "kernel-id" r) :kernel-name (molten-get "kernel-name" r)
             :slot-id (molten-get "slot-id" r) :hidden (molten-get "hidden" r)
             :state (intern (molten-get "state" r)) :count (molten-get "count" r)
             :traceback (and (molten-get "traceback" r)
                             (molten-store--read-blob (molten-get "traceback" r)))
             :anchor (make-molten-anchor
                      :file (molten-get "file" a) :line (molten-get "line" a)
                      :end-line (molten-get "end-line" a) :source (molten-get "source" a)
                      :hash (molten-get "hash" a) :before (molten-get "before" a)
                      :after (molten-get "after" a)))))
    (when (memq (molten-execution-state e) '(queued busy running))
      (setf (molten-execution-state e) 'disconnected))
    (dolist (o (molten-get "outputs" r))
      (molten-execution-add-output
       e (make-molten-output
          :kind (intern (molten-get "kind" o)) :name (molten-get "name" o)
          :metadata (molten-get "metadata" o)
          :text (and (molten-get "text" o) (molten-store--read-blob (molten-get "text" o)))
          :data (mapcar (lambda (pair) (cons (car pair) (molten-store--read-blob (cdr pair))))
                        (molten-get "data" o)))))
    e))
(defun molten-store-load (file)
  "Load execution history for FILE, newest first; skip damaged records."
  (let ((dir (expand-file-name "records/" molten-state-directory)) records)
    (when (file-directory-p dir)
      (dolist (path (directory-files dir t "\\.json\\'"))
        (condition-case err
            (let ((r (with-temp-buffer (insert-file-contents path)
                                      (molten-json-read (buffer-string)))))
              (when (equal (molten-get "file" r) (expand-file-name file))
                (push (molten-store--decode r) records)))
          (error (display-warning 'molten (format "Cannot restore %s: %s" path
                                                   (error-message-string err)))))))
    (sort records (lambda (a b) (> (molten-execution-timestamp a)
                                   (molten-execution-timestamp b))))))
(defun molten-store-restore ()
  "Restore current file history and confidently located live anchors."
  (when buffer-file-name
    (setq molten-executions (molten-store-load buffer-file-name))
    (dolist (e molten-executions)
      (let ((location (molten-anchor-locate (molten-execution-anchor e))))
        (setf (molten-execution-buffer e) (current-buffer)
              (molten-execution-freshness e) (or (nth 2 location) 'orphaned))
        (when location
          (setf (molten-execution-start e) (copy-marker (nth 0 location))
                (molten-execution-end e) (copy-marker (nth 1 location) t)))))))
(provide 'molten-store)
;;; molten-store.el ends here
