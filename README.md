# pogemini - a Gemini server in Oberon-2 for poc

This software is developed with the aid of AI.

A server for the [Gemini protocol](https://geminiprotocol.net/), written
in Oberon-2 for poc, the
[Peaseblossom](https://github.com/tkurtbond/peaseblossom) Oberon
compiler. It uses [polibtls](https://github.com/tkurtbond/polibtls) for
TLS (libtls: LibreTLS's on Linux, FreeBSD and NetBSD, the system's own
on OpenBSD) and [posockets](https://github.com/tkurtbond/posockets) for
sockets, and serves every connection in a task of poc's cooperative
`Tasks`, in one thread. It runs on Linux, FreeBSD, NetBSD and OpenBSD,
amd64 and i386.

What it does:

- serves several capsules, chosen by the host the client names (SNI and
  the request's URL), each with its own certificate, or a self-signed
  one made for it the first time and kept;
- checks each request, refusing what the specification forbids;
- serves the files under a capsule's root: the MIME type by extension
  (`text/gemini` for `.gmi`), a directory's `index.gmi`, never a hidden
  name (`.git`) or anything outside the root, even by a symbolic link;
- requires a client certificate for parts of a capsule, any or only
  those listed (status 60, 61, and 62 for one outside its dates);
- logs a line per connection, with the time, on standard output;
- gives each connection a deadline, serves at most a set number at
  once, stops cleanly on SIGTERM, and, started as root, serves as
  another user.

It serves only static files: no CGI, no proxying, no directory listings.

[`pogemini(1)`](doc/pogemini.1) is the reference: every option and
setting. [PLAN.md](PLAN.md) has the design and the roadmap, and
[AGENTS.md](AGENTS.md) the working notes.

## Requirements

- poc 0.13.0 or later, with its runtime library, on `PATH`; override
  with `make POC=/path/to/poc`.
- clang, which poc runs, and GNU make (`gmake` on the BSDs).
- libtls: Fedora's `libretls` and `libretls-devel`, the `libretls`
  package on FreeBSD and NetBSD; OpenBSD's is in base.
- polibtls and posockets, installed by `make install` in each, in
  `~/.local/lib/poc` by default (`make POCLIBDIR=<dir>` otherwise), and
  built by the same poc as this: poc refuses a library another poc
  built. After upgrading poc, reinstall both, then rebuild this.
- `openssl` (OpenSSL's or LibreSSL's) at run time, to make self-signed
  certificates: only for a capsule given no certificate.

`make deps` says whether the libraries are there. The program links
libtls and nothing of poc's, so once built it needs only libtls (and
`openssl`, as above).

## Building and installing

    make            # gmake on the BSDs: the program, the tests, test certificates
    make test       # runs the tests
    make install    # into ~/.local: bin/pogemini, the manual page, share/doc/pogemini

`make install PREFIX=/usr/local` installs for everyone: run it as root
after `make` as yourself, since install doesn't build. `DESTDIR` is
honoured, for packaging, and `BINDIR`, `MANDIR` and `DOCDIR` can be set
apart. `make uninstall`, with the same settings, removes it all.

The tests need `openssl`. They use OpenBSD's `nc` (one linked with
libtls), `gemget` and `gnutls-cli` as other clients if they are there,
and skip them, saying so, if not.

## A first capsule

    mkdir -p ~/gemini
    printf '# Hello\n\nA capsule served by pogemini.\n' > ~/gemini/index.gmi
    pogemini -host localhost -root ~/gemini -port 1965

The first run makes a self-signed certificate for `localhost` in
`~/.local/share/pogemini/certs`, and later runs use the same one:
Gemini clients pin the certificate they first see, so keep it. The
server prints `port 1965`, then a line per connection:

    2026-11-16T12:34:56Z 127.0.0.1 20 gemini://localhost/ -

Point a Gemini client at `gemini://localhost/`. With a certificate of
your own, give `-cert file -key file`.

## A configuration

For more than one capsule, or to keep the settings in one place, use a
configuration file, `pogemini -config /etc/pogemini.conf`:

    # global settings first
    port 1965
    user gemini                     # to serve as, if started as root
    certdir /var/lib/pogemini/certs # where self-signed ones are kept

    # the first capsule is shown to a client that sends no SNI
    capsule example.org
      alias www.example.org
      root /srv/gemini/example.org
      cert /etc/pogemini/example.org.crt
      key /etc/pogemini/example.org.key
      require /private              # a client certificate needed below here,
        identity SHA256:3f0c...     # and only these (any, if none listed)

    capsule example.net             # a self-signed certificate, made once
      root /srv/gemini/example.net

A capsule answers its name and its aliases; a request for any other
host, or another port, is refused (53). An identity is a client
certificate's SHA-256 hash, as the log shows it. Options on the command
line override the file. `contrib/pogemini.conf`, installed in
`share/doc/pogemini`, is a commented example, and `pogemini(1)`
describes every setting.

## Running it as a service

Started as root, pogemini reads its keys, listens (so port 1965, or
one below 1024, is fine), then becomes `user`, with that user's groups,
and serves files as them. Started as root without a `user` it refuses
to run: a server reading files as root is one mistake from serving any
of them. Make a user of its own, give it read access to the capsules'
roots, and keep the keys readable by root only.

Its log is standard output, one line per connection, each beginning
with the time, UTC; mistakes in the configuration go to standard error,
with exit status 1. SIGTERM or SIGINT stops it: new clients are refused
at once, the connections in progress finish within their deadline (10
s by default), and it exits 0. A second signal ends it at once.

On Linux with systemd, `contrib/pogemini.service` starts it as the user
`gemini`, logs to the journal, keeps self-signed certificates in
`/var/lib/pogemini`, and sandboxes it; its comments say how to install
it. On the BSDs, start it from the system's rc as root, with `-user`
(or `user` in the file) and its output redirected to a log file; no rc
script is supplied yet.

## License

BSD 3-Clause; see [LICENSE](LICENSE).
