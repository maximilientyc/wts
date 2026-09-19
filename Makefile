PREFIX ?= /usr/local

BINDIR     = $(DESTDIR)$(PREFIX)/bin
LIBEXECDIR = $(DESTDIR)$(PREFIX)/libexec/wts
SHAREDIR   = $(DESTDIR)$(PREFIX)/share/wts
ZSHCOMPDIR = $(DESTDIR)$(PREFIX)/share/zsh/site-functions

HELPERS  = $(wildcard libexec/wts/wts-*)
LAYOUTS  = $(wildcard share/wts/layouts/*.yml)
EXAMPLES = $(wildcard examples/layouts/*.yml)

.PHONY: install uninstall lint test bench demo

install:
	install -d "$(BINDIR)" "$(LIBEXECDIR)" "$(SHAREDIR)/layouts" "$(SHAREDIR)/examples/layouts" "$(ZSHCOMPDIR)"
	install -m 755 bin/wts "$(BINDIR)/wts"
	install -m 755 $(HELPERS) "$(LIBEXECDIR)/"
	install -m 644 $(LAYOUTS) "$(SHAREDIR)/layouts/"
	install -m 644 $(EXAMPLES) "$(SHAREDIR)/examples/layouts/"
	install -m 644 completions/_wts "$(ZSHCOMPDIR)/_wts"

uninstall:
	rm -f "$(BINDIR)/wts" "$(ZSHCOMPDIR)/_wts"
	rm -rf "$(LIBEXECDIR)" "$(SHAREDIR)"

lint:
	@for f in bin/wts $(HELPERS) completions/_wts test/smoke.zsh test/bench-big.zsh; do zsh -n "$$f" || exit 1; done
	@echo "zsh -n: ok"

test: lint
	zsh test/smoke.zsh

bench:
	zsh test/bench-big.zsh --tier $(or $(TIER),large)

demo:
	zsh docs/demo/record.zsh
