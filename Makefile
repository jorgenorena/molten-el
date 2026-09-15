EMACS ?= emacs
.PHONY: test compile clean
test:
	EMACS=$(EMACS) sh test/run-tests.sh
compile:
	$(EMACS) --batch -Q -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile molten-core.el molten-store.el molten-jupyter.el molten-display.el molten.el
clean:
	rm -f molten*.elc
