;;; molten-jupyter.el --- Jupyter Server REST and channels -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; No client-side Python or ZMQ.  websocket.el is needed only when connecting.
;;; Code:
(require 'molten-core)
(require 'url)
(require 'url-http)
(declare-function websocket-open "websocket" (url &rest args))
(declare-function websocket-close "websocket" (websocket))
(declare-function websocket-send-text "websocket" (websocket text))
(declare-function websocket-frame-opcode "websocket" (frame))
(declare-function websocket-frame-payload "websocket" (frame))
(defcustom molten-http-timeout 15 "Seconds to wait for REST operations."
  :type 'number :group 'molten)
(defun molten-jupyter-session (url token)
  "Create a session for server base URL and memory-only TOKEN."
  (let ((parsed (url-generic-parse-url url)))
    (unless (and (member (url-type parsed) '("http" "https"))
                 (url-host parsed) (not (url-user parsed))
                 (not (url-target parsed))
                 (not (string-match-p "[?\n\r]" url)))
      (user-error "Use an http(s) base URL without credentials, query or fragment"))
    (when (string-match-p "[\n\r]" token) (user-error "Invalid token"))
    (make-molten-session :id (molten-id) :url (string-remove-suffix "/" url) :token token)))
(defun molten-jupyter--headers (s)
  "Return authentication headers for S."
  (unless (string-empty-p (or (molten-session-token s) ""))
    `(("Authorization" . ,(concat "token " (molten-session-token s))))))
(defun molten-jupyter-rest (s method path &optional data)
  "Call METHOD on PATH for S with optional JSON DATA.
Control operations are bounded and synchronous; code execution is asynchronous."
  (let* ((url-request-method method)
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json")) (molten-jupyter--headers s)))
         (url-request-data (and data (encode-coding-string (json-encode data) 'utf-8)))
         (url-max-redirections 0)
         (buffer (url-retrieve-synchronously (concat (molten-session-url s) path)
                                            t t molten-http-timeout)))
    (unless buffer (error "Jupyter REST connection failed or timed out"))
    (unwind-protect
        (with-current-buffer buffer
          (unless (and (boundp 'url-http-response-status)
                       (numberp url-http-response-status)
                       (<= 200 url-http-response-status) (< url-http-response-status 300))
            (error "Jupyter REST %s %s failed (HTTP %s)" method path
                   (if (boundp 'url-http-response-status) url-http-response-status "unknown")))
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t) (error "Malformed HTTP response"))
          (unless (= (point) (point-max))
            (molten-json-read (decode-coding-string
                               (buffer-substring-no-properties (point) (point-max)) 'utf-8))))
      (kill-buffer buffer))))
(defun molten-jupyter-list-kernels (s)
  "Return existing kernel models for S."
  (molten-jupyter-rest s "GET" "/api/kernels"))
(defun molten-jupyter--path (s &optional suffix)
  "Return the current kernel path for S with SUFFIX."
  (unless (molten-session-kernel-id s) (user-error "Select or start a kernel first"))
  (concat "/api/kernels/" (url-hexify-string (molten-session-kernel-id s)) suffix))
(defun molten-jupyter-disconnected (s)
  "Mark S and unfinished executions disconnected, preserving partial output."
  (setf (molten-session-state s) 'disconnected)
  (maphash (lambda (_ e)
             (when (memq (molten-execution-state e) '(queued busy running))
               (setf (molten-execution-state e) 'disconnected)
               (molten-execution-notify e)))
           (molten-session-executions s)))
(defun molten-jupyter-close (s)
  "Close S's transport without shutting down its kernel."
  (let ((ws (molten-session-socket s)))
    (setf (molten-session-socket s) nil)
    (when ws (websocket-close ws)))
  (molten-jupyter-disconnected s))
(defun molten-jupyter--u32 (bytes pos)
  "Read a big-endian uint32 in BYTES at POS."
  (when (> (+ pos 4) (length bytes)) (error "Truncated Jupyter binary frame"))
  (let ((value 0))
    (dotimes (i 4) (setq value (+ (ash value 8) (aref bytes (+ pos i)))))
    value))
(defun molten-jupyter-decode (payload &optional binary)
  "Decode default-protocol PAYLOAD; BINARY uses the legacy offset table.
Auxiliary binary buffers are not interpreted by this MVP."
  (when binary
    (let* ((n (molten-jupyter--u32 payload 0))
           (start (molten-jupyter--u32 payload 4))
           (end (if (> n 1) (molten-jupyter--u32 payload 8) (length payload))))
      (unless (and (> n 0) (= start (* 4 (1+ n)))
                   (<= start end) (<= end (length payload)))
        (error "Invalid Jupyter binary offsets"))
      (let ((last start))
        (dotimes (i n)
          (let ((offset (molten-jupyter--u32 payload (* 4 (1+ i)))))
            (unless (<= last offset (length payload)) (error "Invalid Jupyter binary offset"))
            (setq last offset))))
      (setq payload (substring payload start end))))
  (molten-json-read (decode-coding-string payload 'utf-8)))
(defun molten-jupyter-open (s)
  "Open the default channels WebSocket for S."
  (unless (require 'websocket nil t)
    (user-error "Install the pure-Elisp websocket package to connect"))
  (molten-jupyter-close s)
  (setf (molten-session-state s) 'connecting)
  (condition-case err
      (setf (molten-session-socket s)
            (websocket-open
             (concat (replace-regexp-in-string "\\`http" "ws" (molten-session-url s))
                     (molten-jupyter--path s "/channels")
                     "?session_id=" (molten-session-id s))
             :custom-header-alist (molten-jupyter--headers s)
             :on-open (lambda (_ws) (setf (molten-session-state s) 'ready)
                        (message "Molten kernel connected"))
             :on-message
             (lambda (ws frame)
               (when (eq ws (molten-session-socket s))
                 (molten-jupyter-dispatch
                  s (molten-jupyter-decode (websocket-frame-payload frame)
                                           (eq (websocket-frame-opcode frame) 'binary)))))
             :on-close (lambda (ws)
                         (when (eq ws (molten-session-socket s))
                           (molten-jupyter-disconnected s)))
             :on-error (lambda (ws type _err)
                         (when (eq ws (molten-session-socket s))
                           (molten-jupyter-disconnected s)
                           (message "Molten WebSocket error (%s); reconnect the kernel" type)))))
    (error (molten-jupyter-disconnected s) (signal (car err) (cdr err)))))
(defun molten-jupyter-select (s model)
  "Connect S to kernel MODEL."
  (molten-jupyter-close s)
  (clrhash (molten-session-executions s))
  (setf (molten-session-kernel-id s) (molten-get "id" model)
        (molten-session-kernel-name s) (molten-get "name" model))
  (molten-jupyter-open s))
(defun molten-jupyter-start (s name)
  "Start kernel NAME for S and open its channels."
  (molten-jupyter-select s (molten-jupyter-rest s "POST" "/api/kernels" `(("name" . ,name)))))
(defun molten-jupyter-interrupt (s)
  "Interrupt S's kernel."
  (molten-jupyter-rest s "POST" (molten-jupyter--path s "/interrupt")))
(defun molten-jupyter-restart (s)
  "Restart S's kernel and reconnect."
  (molten-jupyter-rest s "POST" (molten-jupyter--path s "/restart"))
  (molten-jupyter-close s)
  (clrhash (molten-session-executions s))
  (molten-jupyter-open s))
(defun molten-jupyter-kill (s)
  "Shut down S's kernel."
  (molten-jupyter-rest s "DELETE" (molten-jupyter--path s))
  (molten-jupyter-close s)
  (clrhash (molten-session-executions s))
  (setf (molten-session-kernel-id s) nil))
(defun molten-jupyter-execute (s e)
  "Send asynchronous execute_request for E over S."
  (unless (eq (molten-session-state s) 'ready) (user-error "Kernel channels are not ready"))
  (puthash (molten-execution-id e) e (molten-session-executions s))
  (condition-case err
      (websocket-send-text
       (molten-session-socket s)
       (json-encode
        `(("header" . (("msg_id" . ,(molten-execution-id e))
                        ("username" . "molten") ("session" . ,(molten-session-id s))
                        ("date" . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
                        ("msg_type" . "execute_request") ("version" . "5.3")))
          ("parent_header" . ,(make-hash-table)) ("metadata" . ,(make-hash-table))
          ("channel" . "shell") ("buffers" . [])
          ("content" . (("code" . ,(molten-anchor-source (molten-execution-anchor e)))
                         ("silent" . :json-false) ("store_history" . t)
                         ("user_expressions" . ,(make-hash-table))
                         ("allow_stdin" . :json-false) ("stop_on_error" . t))))))
    (error (setf (molten-execution-state e) 'disconnected)
           (molten-execution-notify e) (signal (car err) (cdr err)))))
(defun molten-jupyter--mime (data)
  "Normalize supported DATA, decoding PNG to bytes."
  (let (result)
    (dolist (mime '("text/plain" "image/png" "image/svg+xml"))
      (let ((value (molten-get mime data)))
        (when value
          (when (listp value) (setq value (apply #'concat value)))
          (when (equal mime "image/png") (setq value (base64-decode-string value)))
          (push (cons mime value) result))))
    (nreverse result)))
(defun molten-jupyter-dispatch (s message)
  "Apply correlated MESSAGE to S's execution records."
  (let* ((id (molten-get "msg_id" (molten-get "parent_header" message)))
         (e (and id (gethash id (molten-session-executions s))))
         (kind (molten-get "msg_type" (molten-get "header" message)))
         (channel (molten-get "channel" message))
         (c (molten-get "content" message))
         changed)
    (when e
      (cond
       ((and (equal channel "iopub")
             (member kind '("status" "stream" "execute_result" "display_data" "error")))
        (setq changed t)
        (pcase kind
          ("status"
           (pcase (molten-get "execution_state" c)
             ("busy" (setf (molten-execution-state e) 'running))
             ("idle" (setf (molten-execution-idle e) t))))
          ("stream"
           (molten-execution-add-output e (make-molten-output
                                          :kind 'stream :name (molten-get "name" c)
                                          :text (molten-get "text" c))))
          ((or "execute_result" "display_data")
           (when (molten-get "execution_count" c)
             (setf (molten-execution-count e) (molten-get "execution_count" c)))
           (molten-execution-add-output
            e (make-molten-output :kind (intern kind) :data (molten-jupyter--mime (molten-get "data" c))
                                  :metadata (molten-get "metadata" c))))
          ("error"
           (setf (molten-execution-traceback e)
                 (mapconcat #'identity (molten-get "traceback" c) "\n"))
           (molten-execution-add-output e (make-molten-output
                                          :kind 'error :text (molten-execution-traceback e))))))
       ((and (equal channel "shell") (equal kind "execute_reply"))
        (setq changed t)
        (setf (molten-execution-reply e) (molten-get "status" c)
              (molten-execution-count e) (molten-get "execution_count" c))
        (when (and (molten-get "traceback" c) (not (molten-execution-traceback e)))
          (setf (molten-execution-traceback e)
                (mapconcat #'identity (molten-get "traceback" c) "\n")))))
      (when changed
        (when (and (molten-execution-reply e) (molten-execution-idle e))
          (setf (molten-execution-state e)
                (pcase (molten-execution-reply e) ("ok" 'done) ("aborted" 'aborted) (_ 'error))))
        ;; Keep the mapping to accept late background output after idle.
        (molten-execution-notify e)))))
(provide 'molten-jupyter)
;;; molten-jupyter.el ends here
