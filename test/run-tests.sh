#!/bin/sh
# Generated from molten.org; edit that file, then run the tangle command.
set -eu
cd "$(dirname "$0")/.."
EMACS=${EMACS:-emacs}
"$EMACS" --batch -Q -l tools/tangle.el --check
"$EMACS" --batch -Q -L . -l test/load-minimal.el
"$EMACS" --batch -Q -L . -l test/molten-test.el -f ert-run-tests-batch-and-exit
MOLTEN_TEST_DIR=$(mktemp -d)
export MOLTEN_TEST_DIR
trap 'rm -rf "$MOLTEN_TEST_DIR"' EXIT HUP INT TERM
for phase in seed fresh stale orphan; do
    MOLTEN_TEST_PHASE="molten-process-$phase" "$EMACS" --batch -Q -L . -l test/restart.el
done
