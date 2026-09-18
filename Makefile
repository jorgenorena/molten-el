# Generated from molten.org; edit that file, then run the tangle command.
EMACS ?= emacs
.PHONY: tangle check-tangle test compile clean
tangle:
	$(EMACS) --batch -Q -l tools/tangle.el
check-tangle:
	$(EMACS) --batch -Q -l tools/tangle.el --check
test:
	EMACS=$(EMACS) sh test/run-tests.sh
compile: check-tangle
	$(EMACS) --batch -Q -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile molten-core.el molten-store.el molten-jupyter.el molten-display.el molten.el
clean:
	rm -f molten*.elc
