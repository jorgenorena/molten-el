;;; integration-restore.el --- Offline restoration of real kernel output -*- lexical-binding: t; -*-
;; Generated from molten.org; edit that file, then run the tangle command.
(require 'ert)
(require 'molten)
(setq molten-state-directory (expand-file-name "state/" (getenv "MOLTEN_TEST_DIR")))
(ert-deftest molten-real-output-offline ()
  (find-file (expand-file-name "real.py" (getenv "MOLTEN_TEST_DIR")))
  (should-not molten-current-session)
  (should molten-mode)
  (should (= 1 (length molten-display-overlays)))
  (let ((e (car molten-executions)))
    (should (eq 'fresh (molten-execution-freshness e)))
    (should (string-match-p "hello from kernel" (molten-execution-stdout e)))
    (should (cl-some (lambda (o) (assoc "image/png" (molten-output-data o)))
                     (molten-execution-outputs e))))
  (should-not (buffer-modified-p)))
(ert-run-tests-batch-and-exit)
;;; integration-restore.el ends here
