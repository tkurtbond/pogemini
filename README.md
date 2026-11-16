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
specification forbids, and serves the files under the root of the
capsule asked for: the MIME type by extension (`text/gemini` for
`.gmi`), a directory's `index.gmi`, never a hidden name (`.git`) or
anything outside the root, even by a symbolic link. Capsules come from
a configuration file, or one from the command line:

    build/pogemini -host example.org -root /srv/gemini [-cert server.crt -key server.key] [-port 1965]
    build/pogemini -config pogemini.conf

A capsule given no certificate gets a self-signed one, made by
`openssl` the first time and kept in `~/.local/share/pogemini/certs`
(or `certdir`) for later runs, since clients pin it. The file's format:

    # global settings first
    port 1965
    certdir /var/lib/pogemini/certs

    capsule example.org
      alias www.example.org
      root /srv/gemini/example.org
      cert /etc/pogemini/example.org.crt
      key /etc/pogemini/example.org.key

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
