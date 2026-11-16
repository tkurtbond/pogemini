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

As of 2026-11-16, Phase 0 of PLAN.md (the skeleton) is done. Next is
Phase 1, a first server.

**poc 0.13.0 or later, and polibtls and posockets built by the same
poc.** A poc library works only with the poc that built it. Both were
installed in `~/.local/lib/poc` on 2026-11-16 (polibtls at 06e31a5,
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
program to `PROGS`, a test to `TESTS`.

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
  the BSD hosts", once polibtls is ported (Phase 7).
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
