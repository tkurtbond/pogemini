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
  (`text/gemini` for `.gmi`), a directory's `index.gmi`, or, if asked
  for, a listing of a directory without one, never a hidden name
  (`.git`) or anything outside the root, even by a symbolic link;
- requires a client certificate for parts of a capsule, any or only
  those listed (status 60, 61, and 62 for one outside its dates);
- logs a line per connection, with the time, on standard output;
- gives each connection a deadline, serves at most a set number at
  once, stops cleanly on SIGTERM, and, started as root, serves as
  another user.

It serves only static files: no CGI, no proxying.

[`pogemini(1)`](docs/pogemini.1) is the reference: every option and
setting. [PLAN.md](PLAN.md) has the design and the roadmap, and
[AGENTS.md](AGENTS.md) the working notes.

## Requirements

- poc 0.14.0 or later, with its runtime library, on `PATH`; override
  with `make POC=/path/to/poc`.
- clang, which poc runs, and GNU make (`gmake` on the BSDs).
- libtls: Fedora's `libretls` and `libretls-devel`, the `libretls`
  package on FreeBSD and NetBSD; OpenBSD's is in base.
- [pounix](https://github.com/tkurtbond/pounix), polibtls, posockets
  and [poDateTime](https://github.com/tkurtbond/poDateTime), installed by
  `make install` in each, in `~/.local/lib/poc` by default (`make
  POCLIBDIR=<dir>` otherwise), and built by the same poc as this: poc
  refuses a library another poc built. After upgrading poc, reinstall
  all four, poDateTime before polibtls and posockets, then rebuild
  this.
`make deps` says whether the libraries are there. The program links
libtls (and the libcrypto libtls uses, to make self-signed
certificates) and nothing of poc's, so once built it needs only libtls.

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
      listings yes                  # list directories without index.gmi

A capsule answers its name and its aliases; a request for any other
host, or another port, is refused (53). An internationalised name may
be written in UTF-8 (`bücher.example`) or in its ASCII form
(`xn--bcher-kva.example`), and a request in either form reaches it. An identity is a client
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
s by default), and it exits 0. A second signal of the same kind ends it
at once.

On Linux with systemd, `contrib/pogemini.service` starts it as the user
`gemini`, logs to the journal, keeps self-signed certificates in
`/var/lib/pogemini`, and sandboxes it; its comments say how to install
it. On the BSDs, `contrib/freebsd/pogemini`, `contrib/netbsd/pogemini`
and `contrib/openbsd/pogemini` are rc scripts, and `make install`
puts the one for the system it runs on in `share/doc/pogemini/rc.d`.
Each starts it as root, so the configuration must name a `user`, and
its comments say how to install and enable it. On FreeBSD its log goes
to `/var/log/pogemini.log`, through daemon(8), which reopens the file
for newsyslog; on NetBSD and OpenBSD to syslog, as `daemon.info`
(`/var/log/messages` and `/var/log/daemon`), where a line over about
1000 bytes is split in two.

## An earlier, simpler version

The version first announced, tagged
[`announced`](https://github.com/tkurtbond/pogemini/tree/announced),
is easier to read as a whole: its request parsing, response writing
and server loop are its own, where this version takes them from
[pogeminilib](https://github.com/tkurtbond/pogeminilib), and it has
fewer features. It builds and passes its tests with poc 0.14.0. Read
it, but don't serve with it: it halts on a request with an IPv6
literal over 255 bytes, fixed since.

## License

BSD 3-Clause; see [LICENSE](LICENSE).
