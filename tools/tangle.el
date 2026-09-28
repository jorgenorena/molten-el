;;; tangle.el --- Generate or check the literate source -*- lexical-binding: t; -*-
;; Generated from molten.org; edit that file, then run the tangle command.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Run with emacs --batch -Q -l tools/tangle.el [--check].
;;; Code:
(require 'org)
(require 'ob-tangle)
(defconst molten-tangle-files
  '("molten-core.el" "molten-jupyter.el" "molten-store.el"
    "molten-display.el" "molten.el" "test/molten-test.el"
    "test/load-minimal.el" "test/restart.el" "test/integration.el"
    "test/integration-restore.el" "test/doom-quarto-smoke.el"
    "examples/molten-smoke.qmd" "test/run-tests.sh" "tools/tangle.el" "Makefile")
  "Expected generated files, relative to the repository root.")
(defun molten-tangle--bytes (file)
  "Return the literal bytes of FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))
(let* ((root (file-name-directory
              (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))
       (check (member "--check" command-line-args-left))
       (temporary (and check (make-temp-file "molten-tangle-" t)))
       (default-directory (or temporary root))
       (org-confirm-babel-evaluate t)
       (org-babel-pre-tangle-hook nil)
       (org-babel-post-tangle-hook nil)
       (org-babel-tangle-body-hook nil)
       (coding-system-for-write 'utf-8-unix))
  (unless (or (null command-line-args-left) (equal command-line-args-left '("--check")))
    (error "Usage: emacs --batch -Q -l tools/tangle.el [--check]"))
  (setq command-line-args-left nil)
  (unwind-protect
      (progn
        (when check (copy-file (expand-file-name "molten.org" root) "molten.org"))
        (let* ((outputs (org-babel-tangle-file (expand-file-name "molten.org")))
               (relative (mapcar (lambda (file) (file-relative-name file default-directory)) outputs)))
          (unless (equal (sort relative #'string<) (sort (copy-sequence molten-tangle-files) #'string<))
            (error "Tangle targets differ from molten-tangle-files: %S" relative))
          (if check
              (let (different)
                (dolist (file molten-tangle-files)
                  (let ((committed (expand-file-name file root)))
                    (unless (and (file-exists-p committed)
                                 (equal (molten-tangle--bytes file)
                                        (molten-tangle--bytes committed)))
                      (push file different))))
                (when different
                  (error "Generated files out of date: %s; run the tangle command"
                         (mapconcat #'identity (nreverse different) ", ")))
                (princ "Literate source and generated files agree.\n"))
            (princ (format "Generated %d files from molten.org.\n" (length outputs))))))
    (when temporary (delete-directory temporary t))))
;;; tangle.el ends here
