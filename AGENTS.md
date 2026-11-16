# AGENTS.md

pogemini is a server for the Gemini protocol, in Oberon-2, compiled
with poc, the Peaseblossom Oberon Compiler, on two libraries of its own
family: **polibtls** (`~/Repos/Oberon/polibtls`), a binding to libtls
as LibreTLS provides it, and **posockets** (`~/Repos/Oberon/posockets`).
PLAN.md is the design and roadmap; this file is operational notes for
an agent working in this repo, not a design doc.

Read polibtls's `AGENTS.md` and `README.md` before designing anything:
their "Confirmed facts" and "Things to know" are what is known about
poc, libtls, OpenSSL and the Gemini clients this must work with, and
apply here unchanged. Its `examples/GeminiHello.Mod` is this server's
starting point.

## Status

As of 2026-11-16, Phases 0 to 7 of PLAN.md are done: `src/GemServer`
and `src/pogemini` serve a page naming the capsule asked for, tested by
`TestServe` with our own client; `src/GemRequest` parses and checks each
request (`TestParse` on its own, `TestRequests` through the server, with
openssl s_client, OpenBSD's nc, gemget and gnutls-cli as clients); and
`src/GemConfig` reads the configuration file and `src/GemCert` makes a
self-signed certificate for a capsule given none (`TestConfig` on its
own, `TestCapsules` through the server: SNI and hosts picking capsules,
a made certificate reused, and what stops the server); and
`src/GemFiles` (with its C part, `src/GemFiles.c`) serves the files
under a capsule's root (`TestFiles`: MIME types, directories and
redirects, links in and out of the root, hidden names, a FIFO, a large
file); and `src/GemAccess` refuses paths inside a capsule's requires
without a fit client certificate, 60, 61 or 62 (`TestCerts`, with the
tests' client certificates); and running it (`src/GemServer.c`,
`src/GemUser`): the time in the log, a clean stop on SIGTERM or
SIGINT, a limit on connections at once, `-user`, and a systemd unit in
`contrib/` (`TestRun`); and `gmake test` passes on FreeBSD, NetBSD and
OpenBSD, amd64 and i386 ("Testing on the BSD hosts"); and the
documentation and install: README.md (the user's guide),
`doc/pogemini.1` (the manual page, mdoc), `contrib/pogemini.conf` (an
example configuration, which `TestConfig` reads), and `make install`,
checked on Linux and all five BSD hosts. Every phase of PLAN.md's
roadmap is done. Since then, rc scripts for the BSDs,
`contrib/{freebsd,netbsd,openbsd}/pogemini`, checked as root on the
amd64 hosts (PLAN.md, "rc scripts for the BSDs").

**poc 0.13.0 or later, and polibtls and posockets built by the same
poc.** A poc library works only with the poc that built it. Both were
installed in `~/.local/lib/poc` on 2026-11-16 (polibtls at b828a53,
posockets at 059b47d), each from a `git archive` of its commit by
`make install`. After a poc upgrade, reinstall both the same way;
`make deps` says whether they match.

## Reference material

| What | Where |
|---|---|
| polibtls | `~/Repos/Oberon/polibtls`: README.md (the user's guide), `doc/Tls.md`, `doc/TlsTasks.md` |
| posockets | `~/Repos/Oberon/posockets`: its README and `doc/` |
| poc | `/usr/bin/poc` (0.13.0); its source `~/Repos/Oberon/Peaseblossom` (`doc/users-guide.md`, `doc/reference-guide.md`; `rtl/llvm/Tasks.Mod`) |
| Oberon-2 report | `~/Reference/Computer/Languages/Oberon/Oberon2.pdf` |
| Gemini protocol | `gemini://geminiprotocol.net/docs/protocol-specification.gmi` (https mirror: https://geminiprotocol.net/docs/protocol-specification.gmi) |
| Clients to test against | `openssl s_client`; OpenBSD's `nc` as `/usr/bin/netcat`; gemget (`~/go/bin/gemget`); `gnutls-cli`. polibtls's `test/TestGemini.Mod` shows how to drive each |

## Build

`GNUmakefile`: `make` (checks the dependencies, then builds), `make
deps`, `make test`, `make clean`, with `POC` from `PATH`, output under
`build/`, `.NOTPARALLEL`, and `POC_LIBRARY_PATH` unexported. polibtls
and posockets are taken from `POCLIBDIR` (`~/.local/lib/poc`). The
integer size model is `-OC`, the one they are installed in. Add a
program to `PROGS`, a test to `TESTS`. `make` also makes the tests'
certificates (`test/make-certs.sh`, polibtls's) into `build/certs`.
`make install` (and `uninstall`) puts the program, `doc/pogemini.1`
and the documentation under `PREFIX` (`~/.local`), honouring
`DESTDIR`, `BINDIR`, `MANDIR` and `DOCDIR`; `MANDIR` is
`$(PREFIX)/man` on NetBSD and OpenBSD, `$(PREFIX)/share/man`
elsewhere. It doesn't build. `POCLIBDIR` doesn't follow `PREFIX`.
After changing an option or setting, update `doc/pogemini.1`,
README.md and `contrib/pogemini.conf` to match; check the page with
`mandoc -T lint -W warning doc/pogemini.1`.

## Test

As polibtls's: one main module per concern in `test/`, run from
`test/`, printing `ok   - `/`FAIL - ` through `test/Check.Mod` and a
summary. The server runs as a child process (`test/Child.Mod`), as a
user runs it: `-port 0`, its port read from its first line, `-n count`
so it exits by itself, and its log, the rest of its output, checked
after `Child.Wait`. `test/GemClient.Mod` is the client, in tasks, with a
deadline of its own. A test task that passes a whole response by value
needs a bigger stack than `TlsTasks.stackSize` (PLAN.md, Phase 1).
Tests import `src/` modules (`-import-path ../src`), so a module can be
tested on its own, as `TestParse` tests `GemRequest`. `TestRequests`
finds the other clients as polibtls's `TestGemini` does (`$OPENSSL`,
`$LIBTLS_NC`, `$GEMGET`, `$GNUTLS_CLI`, else on `PATH`) and skips, saying
so, a client it can't find. `GemClient.servername` is the SNI it sends
(a numeric address sends none), and a response carries the server
certificate's hash. A test that needs files of its own (a configuration,
a certificate directory) makes them under `build/test-<name>`, afresh,
and removes them at the end; nothing a test runs may fall back to
`~/.local/share/pogemini`, so give the server `-certdir` or a capsule
with `-cert`. A capsule without a root answers only `/`, with a page
naming it, so tests that need no files give none. `GemClient`'s
responses grow as they come, up to 16 MiB.

## Testing on the BSD hosts

As polibtls's AGENTS.md says, and the same hosts (not rackhir without
asking). Copy the working tree there (`tar` less `build/` and `.git`)
into a directory under `~/tmp`, with polibtls and posockets from `git
archive`s, each installed by `gmake install POCLIBDIR=<dir>` there and
used by `gmake test POCLIBDIR=<dir>`; remove it all when done. Judge a
run by make's exit status, and count `assertion failed` and core files
as well as `FAIL`. Run TestRun a few more times: its faults were races.

Found in Phase 7 (PLAN.md):

- **C called in a task must fit its stack**, and libc may need far more
  than it seems: the first `gmtime_r` loads the UTC zone, needing more
  than 64 KiB of stack on NetBSD and 32 on OpenBSD, and overran a
  connection's task, corrupting the heap without touching the guard
  page. So the log's time is worked out by arithmetic.
- **Catch a signal before anyone can learn the port**: Listen installs
  the handler, since a test sends SIGINT as soon as it reads `port`.

## Conventions

As polibtls's, in short:

- **Claim only what has been verified**: a throwaway program, run,
  before a comment or decision depends on how something behaves.
  Throwaway work goes in a session directory under `/usr/local/sw/tmp`
  (`/tmp` is a RAM disk here), removed when done.
- **Portable to the BSDs** (PLAN.md, "Portability"): nothing
  Linux-only (`/proc`, `accept4`, `epoll`, GNU options of commands,
  Linux paths); differences between systems go in a module's C part.
  Testing on the BSD hosts follows posockets' AGENTS.md, "Testing on
  the BSD hosts", and polibtls's (Phase 7).
- **Secrets**: never print, log or commit a key; test certificates are
  generated into `build/certs`.
- **Bad outside data never halts** (a client's request, a missing file,
  a network error); programmer errors halt, with codes 100..109
  (PLAN.md, "Halt codes").
- **Comments explain why.**
- **Record decisions and findings in PLAN.md as they happen**, mark
  finished phases `[done]`, strike through decided open questions.
- **Commit only when asked.** Commit messages are short and say why.
- When the server needs something polibtls or posockets lacks, change
  it there, with its tests, and reinstall it; don't work around it
  here.
