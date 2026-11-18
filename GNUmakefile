# pogemini -- a Gemini server in Oberon-2 for poc, the Peaseblossom
# Oberon Compiler, on polibtls and posockets. See AGENTS.md; adapted from
# polibtls's GNUmakefile.
#
# polibtls and posockets are taken installed, from $(POCLIBDIR), and must
# have been built by the poc in use, since poc refuses a library another
# poc built: make deps checks. poc writes each module's .sym, .ll and .o,
# and the programs, into $(BUILD), so make must not build two at once.
#
# make install puts the program, its manual page and its documentation
# (README, the example configuration, the systemd unit, and on a BSD its
# rc script, as rc.d/pogemini) under $(PREFIX),
# ~/.local by default, or under $(DESTDIR)$(PREFIX) for a package.
# POCLIBDIR doesn't follow PREFIX: it is where the libraries were
# installed, not where this goes. Build first as yourself, then install
# as whoever may write there: install doesn't build.

POC      ?= poc
PREFIX ?= $(HOME)/.local
POCLIBDIR ?= $(HOME)/.local/lib/poc
BINDIR ?= $(PREFIX)/bin
DOCDIR ?= $(PREFIX)/share/doc/pogemini
# Where each system's man looks under a prefix: share/man on Linux and
# FreeBSD, man on OpenBSD and NetBSD.
ifneq ($(filter OpenBSD NetBSD,$(shell uname -s)),)
MANDIR ?= $(PREFIX)/man
else
MANDIR ?= $(PREFIX)/share/man
endif
# The rc script for this system, contrib/<system>/pogemini, if there is one.
RCSCRIPT := $(wildcard contrib/$(shell uname -s | tr A-Z a-z)/pogemini)
# The size model, the one polibtls and posockets are installed in.
POCFLAGS := -OC

# An installed library on POC_LIBRARY_PATH could shadow the one in
# $(POCLIBDIR), or stop the build if another poc wrote it.
unexport POC_LIBRARY_PATH

BUILD := build

# poc's version and target, as a library's manifest records them.
POCVERSION := $(shell $(POC) -version | sed -n '1s/^poc \([^ ]*\).*/\1/p')
TRIPLE := $(shell $(POC) -version | sed -n 's/^target \([^ ]*\).*/\1/p')
# The installed libraries this needs.
DEPLIBS := pounix polibtls posockets podatetime

# Programs (src/<name>.Mod, each a main module).
PROGS := pogemini
# Test programs (test/<name>.Mod, each a main module), run from test/.
TESTS := TestParse TestConfig TestServe TestRequests TestCapsules TestFiles TestCerts TestRun

# Any module may be imported by any program, so each is rebuilt when one
# changes; poc itself recompiles only what it must.
SRCMODS := $(wildcard src/*.Mod src/*.c)
TESTMODS := $(wildcard test/*.Mod test/*.c)

PROGBINS := $(PROGS:%=$(BUILD)/%)
TESTBINS := $(TESTS:%=$(BUILD)/%)

.PHONY: all deps certs test clean install uninstall
.NOTPARALLEL:

all: deps $(PROGBINS) $(TESTBINS) certs

# Each library in DEPLIBS must be installed, by this poc.
deps:
	@status=0; for l in $(DEPLIBS); do \
	  m=$(POCLIBDIR)/$(TRIPLE)/OC/$$l.library; \
	  if [ ! -f $$m ]; then echo "deps: $$l is not installed in $(POCLIBDIR)"; status=1; \
	  elif ! grep -qx 'poc $(POCVERSION)' $$m; then \
	    echo "deps: $$l in $(POCLIBDIR) was built by $$(sed -n 's/^poc //p' $$m), not poc $(POCVERSION): reinstall it"; status=1; \
	  else echo "deps: $$l ok"; fi; \
	done; exit $$status

$(BUILD):
	mkdir -p $@

$(PROGBINS): $(BUILD)/%: src/%.Mod $(SRCMODS) | $(BUILD)
	cd src && $(POC) $(POCFLAGS) -library-path $(POCLIBDIR) -output-dir $(abspath $(BUILD)) -o $(abspath $@) $*.Mod

$(TESTBINS): $(BUILD)/%: test/%.Mod $(TESTMODS) $(SRCMODS) | $(BUILD)
	cd test && $(POC) $(POCFLAGS) -import-path ../src -library-path $(POCLIBDIR) -output-dir $(abspath $(BUILD)) -o $(abspath $@) $*.Mod

# The tests' certificates and keys, made afresh, never committed
# (test/make-certs.sh).
certs: $(BUILD)/certs/self-ec.crt
$(BUILD)/certs/self-ec.crt: test/make-certs.sh | $(BUILD)
	sh test/make-certs.sh $(BUILD)/certs

test: all
	@status=0; for t in $(TESTS); do \
	  echo "== $$t"; (cd test && ../$(BUILD)/$$t < /dev/null) || status=1; \
	done; exit $$status

clean:
	rm -rf $(BUILD)

install:
	@test -x $(BUILD)/pogemini || { echo "install: run make first"; exit 1; }
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(MANDIR)/man1 $(DESTDIR)$(DOCDIR)
	install -m 755 $(BUILD)/pogemini $(DESTDIR)$(BINDIR)/pogemini
	install -m 644 docs/pogemini.1 $(DESTDIR)$(MANDIR)/man1/pogemini.1
	install -m 644 README.md LICENSE contrib/pogemini.conf contrib/pogemini.service $(DESTDIR)$(DOCDIR)
ifneq ($(RCSCRIPT),)
	install -d $(DESTDIR)$(DOCDIR)/rc.d
	install -m 555 $(RCSCRIPT) $(DESTDIR)$(DOCDIR)/rc.d/pogemini
endif

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/pogemini $(DESTDIR)$(MANDIR)/man1/pogemini.1
	rm -f $(DESTDIR)$(DOCDIR)/README.md $(DESTDIR)$(DOCDIR)/LICENSE
	rm -f $(DESTDIR)$(DOCDIR)/pogemini.conf $(DESTDIR)$(DOCDIR)/pogemini.service
ifneq ($(RCSCRIPT),)
	rm -f $(DESTDIR)$(DOCDIR)/rc.d/pogemini
	-rmdir $(DESTDIR)$(DOCDIR)/rc.d
endif
	-rmdir $(DESTDIR)$(DOCDIR)
