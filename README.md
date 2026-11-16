# pogemini - a Gemini server in Oberon-2 for poc

This software is developed with the aid of AI.

A server for the [Gemini protocol](https://geminiprotocol.net/), written
in Oberon-2 for poc, the
[Peaseblossom](https://github.com/tkurtbond/peaseblossom) Oberon
compiler. It uses [polibtls](https://github.com/tkurtbond/polibtls) for
TLS (LibreTLS's libtls) and
[posockets](https://github.com/tkurtbond/posockets) for sockets, and
serves every connection in a task of poc's cooperative `Tasks`, in one
thread. It is meant for Linux and the BSDs (FreeBSD, OpenBSD, NetBSD)
alike; so far it is built only on Linux.

**Status:** early. It checks each request, refusing what the
specification forbids, and serves one fixed page to the rest, for one
certificate given on the command line and the host names given by
`-host` (any, with none):

    build/pogemini -cert server.crt -key server.key [-host example.org] [-port 1965]

[PLAN.md](PLAN.md) has the design and the roadmap, and
[AGENTS.md](AGENTS.md) the working notes.

## Requirements

- poc 0.13.0 or later, with its runtime library, on `PATH`; override
  with `make POC=/path/to/poc`.
- clang, which poc runs, and GNU make (`gmake` on the BSDs).
- LibreTLS (Fedora's `libretls`), which polibtls links.
- polibtls and posockets, installed by `make install` in each, in
  `~/.local/lib/poc` by default (`make POCLIBDIR=<dir>` otherwise), and
  built by the same poc as this: poc refuses a library another poc
  built. After upgrading poc, reinstall both.

`make deps` says whether they are there.

## License

BSD 3-Clause; see [LICENSE](LICENSE).
