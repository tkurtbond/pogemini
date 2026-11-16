# pogemini -- a Gemini server in Oberon-2 for poc, the Peaseblossom
# Oberon Compiler, on polibtls and posockets. See AGENTS.md; adapted from
# polibtls's GNUmakefile.
#
# polibtls and posockets are taken installed, from $(POCLIBDIR), and must
# have been built by the poc in use, since poc refuses a library another
# poc built: make deps checks. poc writes each module's .sym, .ll and .o,
# and the programs, into $(BUILD), so make must not build two at once.

POC      ?= poc
PREFIX ?= $(HOME)/.local
POCLIBDIR ?= $(PREFIX)/lib/poc
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
DEPLIBS := polibtls posockets

# Programs (src/<name>.Mod, each a main module). None yet: PLAN.md,
# "Roadmap".
PROGS :=
# Test programs (test/<name>.Mod, each a main module), run from test/.
TESTS :=

PROGBINS := $(PROGS:%=$(BUILD)/%)
TESTBINS := $(TESTS:%=$(BUILD)/%)

.PHONY: all deps test clean
.NOTPARALLEL:

all: deps $(PROGBINS) $(TESTBINS)

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

$(BUILD)/%: src/%.Mod | $(BUILD)
	cd src && $(POC) $(POCFLAGS) -library-path $(POCLIBDIR) -output-dir $(abspath $(BUILD)) -o $(abspath $@) $*.Mod

test: all
	@status=0; for t in $(TESTS); do \
	  echo "== $$t"; (cd test && ../$(BUILD)/$$t < /dev/null) || status=1; \
	done; exit $$status

clean:
	rm -rf $(BUILD)
