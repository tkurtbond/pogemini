# PLAN.md

pogemini's design and roadmap. Decisions and findings are appended to
the relevant section as they happen; a finished phase is marked
`[done]`, and a decided open question struck through.

## Goal and scope

A Gemini server, in Oberon-2 for poc, that a person can run to serve
one or more capsules from files, on Linux and the BSDs (FreeBSD,
OpenBSD and NetBSD), the systems poc runs on:

1. listen on port 1965 (or another), on IPv6 and IPv4;
2. serve several capsules, each a host name with its own certificate
   and key, chosen by SNI;
3. read each request, validate it as the specification says, and map
   its path to a file under the capsule's document root, never outside
   it;
4. answer with the right status: 20 with a MIME type by extension
   (`text/gemini` for `.gmi`), 51 for a missing file, 59 for a bad
   request, 53 for a host it doesn't serve, 31 to add a directory's
   trailing slash, and so on;
5. serve many clients at once in one thread, each in its own task, with
   a deadline, so a slow or stalled client stops no other;
6. log each request: time, client, status, URL, client certificate
   fingerprint;
7. optionally require a client certificate for parts of a capsule
   (status 60), identifying users by fingerprint.

Out of scope for now, though nothing should rule them out: CGI or other
dynamic content, Titan uploads and proxying.

**Portability** (the user, 2026-11-16): the server must build and run
on FreeBSD, OpenBSD and NetBSD as well as Linux. poc supports all
three (Peaseblossom's INSTALL.md: FreeBSD 15.1, OpenBSD 7.9, NetBSD
11.0), and posockets and polibtls are tested on them (posockets' Phase
9, polibtls's Phase 10, b828a53, on amd64 and i386). So the server is
written so as not to need changing for them:

- no Linux-only calls or files (`/proc`, `accept4`, `epoll`, Linux
  `sendfile`, GNU options of commands); POSIX, or what the four
  systems share, and any difference kept in a module's C part;
- `openssl` run only with options both OpenSSL and OpenBSD's LibreSSL
  `openssl` accept, checked on each system before relying on one;
- `gmake` assumed, not GNU make as `make`; no GNU-only shell or tool
  options in the GNUmakefile or test scripts;
- paths such as the default configuration and certificate locations
  not hard-coded to Linux's layout (`/usr/local` on the BSDs, `/usr/pkg`
  on NetBSD's pkgsrc).

## Foundations

- **polibtls** (`~/Repos/Oberon/polibtls`): `Tls` (configs with several
  key pairs, a server context, connections, the peer certificate) and
  `TlsTasks` (each call waiting through `Tasks` until the connection's
  deadline). Its `examples/GeminiHello.Mod` is this server's starting
  point: an accept task per listener, a task per connection, the
  request read to CRLF within 1026 bytes, close_notify, and
  `SocketTasks.LingeringClose` so a client's early close_notify doesn't
  make the kernel reset the connection under the response. Its README,
  "Things to know", and AGENTS.md, "Confirmed facts", hold what was
  learned about libtls and other clients; read them first.
- **posockets** (`~/Repos/Oberon/posockets`): `Sockets` (listen,
  accept, addresses, non-blocking mode) and `SocketTasks`.
- **poc's runtime**: `Tasks`, `Out`, `Err`, `Args`, `Platform`.
- Other installed po* libraries that may help, to be weighed when the
  need comes: polibfyaml (a YAML config file), podatetime (times in
  logs, a certificate's expiry), ArgParser (the command line).

## Gemini's requirements

From the specification (0.24.1, polibtls's AGENTS.md, "Reference
material"), re-read for Phase 2:

- The request is an absolute URI, at most 1024 bytes, then CR LF; a
  server must reject one longer, or with userinfo or a fragment, and
  must treat an empty path as "/", without a redirect. The port is 1965
  if none is given. (The rule against a byte order mark is the
  response header's and a text body's; a request beginning with one is
  no absolute URI anyway.)
- Status 53, proxy request refused, is for a request for a resource
  this server doesn't serve: another host, port or scheme. 59, bad
  request, for one it can't parse or that breaks the rules above.
- The response header is a two-digit status, a space and its meta, CR
  LF; only a 2x response has a body, ended by the server closing the
  connection with TLS close_notify.
- TLS 1.2 or later, with SNI. Client certificates are mostly
  self-signed and are identities, not things a CA vouches for.

## Design

Decided with the user, 2026-11-16:

- **Configuration**: a small line-based file format of our own, read by
  the server itself, plus command-line options. The command line is
  enough for one capsule (port, host, certificate, key, root); the file
  is for several capsules and the rest; an option given on the command
  line overrides the file. The format is designed in Phase 3.
- **Certificates**: a capsule given no certificate and key gets a
  self-signed pair, made on first run by running `openssl` (libtls
  can't make certificates) and kept for later runs, since clients pin
  it. Where it is kept, its key type and lifetime, and what happens if
  `openssl` is missing are for Phase 3. A certificate the user supplies
  is used as it is.
- **Testing**: our own Gemini client module in `test/`, not polibtls's
  GeminiFetch, so the tests can send malformed requests and check
  exactly what comes back.

### The server's structure (Phase 1)

- **`GemServer`**, the engine, is GeminiHello's structure made a
  module: `New(ctx, respond)` takes a configured `Tls.Context` and a
  `Responder`; `Listen(host, port)` listens on both families (port 0:
  the kernel's choice, in `port`); `Serve(count)` runs an accept task
  per listener and a task per connection, and returns after `count`
  connections have ended (0: never). Each connection has one deadline,
  `SetDeadline` (10 s by default), for everything from handshake to
  close_notify.
- **An `Exchange`** is what a `Responder` sees: the client's address,
  the request line (without CR LF), the client certificate's hash, and
  `Header`, `Write` and `WriteString` to answer, which do nothing once a
  write has failed. Requests are read and the response ended
  (close_notify, then `LingeringClose`) by `GemServer`, so a responder
  only answers. A line with no CR LF in its first 1026 bytes is answered
  59 by `GemServer` itself, never reaching the responder. Later phases
  add their logic as responders, without touching the connection code.
- **The log** is a line per connection on standard output, written with
  no wait between its parts so lines from different tasks never mix:
  `<address> <status> <request> <hash|->`, or `<address> failed:
  <why>`; the request has its control characters as `%XX`, so a client
  can't forge a line. Phase 6 adds the time.
- **`pogemini`**, the program: `-cert`, `-key`, `-port` (1965),
  `-listen` (every address), `-deadline` ms and `-n count` (for the
  tests); its first line on standard output is `port <n>`.

### Halt codes

The poc runtime uses 10..20, and the po* libraries 61..99 (polibfyaml
61..65, pofltk 70..78, posockets 80..89, polibtls 90..99). A module of
this server that asserts a programmer's error uses 100..109:

| Code | Module | Meaning |
|---|---|---|
| 100 | GemServer | `Header` with a status outside 10..69, or a second header |
| 101 | GemServer | `Header` with meta over 1024 bytes |
| 102 | GemServer | `Write` without a 2x header first |
| 103 | GemServer | a `Responder` returned without a header |
| 104 | GemServer | `Serve` before `Listen` |

## Testing

As in polibtls: one main module per concern in `test/`, printing `ok -`
and `FAIL -` lines and a summary; certificates made by a script into
`build/certs`, never committed; the server run as a child process on
port 0, reporting its port, and driven by a client in the test. Other
clients, as polibtls's `TestGemini` uses them: `openssl s_client`,
OpenBSD's `nc` (`netcat`), gemget and `gnutls-cli`.

## Roadmap

### Phase 0: skeleton [done]

The repository, README.md, AGENTS.md, this plan, a GNUmakefile with
`make deps` checking that polibtls and posockets are installed and
built by the poc in use, and the GitHub repository (public), 2026-11-16.

### Phase 1: a first server [done]

GeminiHello's structure as `src/`: listeners, accept tasks, a task per
connection with a deadline, one capsule from the command line, every
request answered with a fixed page; tests as in polibtls, against the
server as a child process, with our own test client in `test/`.

Done 2026-11-16: `src/GemServer.Mod` and `src/pogemini.Mod` ("The
server's structure"). In `test/`: `GemClient` (a client in tasks, with
its own deadline, able to send what no real client would), `Child`
(spawn, read a line, wait, kill, from polibtls's `TestPeers`),
`make-certs.sh` (polibtls's) and `TestServe`, which starts the server
on port 0 and checks IPv4 and IPv6, a client certificate's hash in the
log, a 1024-byte request served and a 1025-byte one refused (59), 1100
bytes without CR LF (59), a control character escaped in the log, two
silent clients (one without a handshake, one without a request) that
hold up no third and are dropped at the deadline, the server's exit
status and its log line for each connection, and an RSA key pair.
Checked by hand against `openssl s_client`, gemget and `gnutls-cli`;
the other clients go into the tests with Phase 2.

Found on the way (poc 0.13.0):

- **A value `ARRAY OF CHAR` parameter is copied onto the callee's
  stack**, so passing a 64 KiB response to `Check.Contains` overran a
  task's 64 KiB stack (SIGSEGV, the guard page). The test's tasks get
  1 MiB; the server passes nothing that large by value.
- **poc has no string concatenation** (`"a" + "b"` is an error), and
  won't assign a string constant to an open array: use `COPY`.

### Phase 2: requests [done]

Parsing and validating the request URL (scheme, host, port, path,
percent-encoding, the limits above), statuses 59 and 53, and the path
normalised (`.` and `..` resolved) before it goes anywhere near the
file system.

Done 2026-11-16: `src/GemRequest.Mod`, `Parse(url, r, why)`, giving
`Ok`, 59 or 53 and a reason that becomes the response's meta;
`pogemini` refuses with 53 a host not given by `-host` (any, with none,
for now) or a port other than the one it listens on. Decided:

- **Characters**: RFC 3986's, plus non-ASCII as UTF-8, as an IRI has
  them (RFC 3987), since some clients send them raw; malformed UTF-8
  (overlong, surrogates, over U+10FFFF, cut short) is refused, raw or
  percent-encoded in the path. A space, a control character, `\`, `"`,
  `<`, `>`, `^`, `` ` ``, `{`, `|`, `}` are refused.
- **Scheme**: checked first, so `mailto:x` is a 53, not a 59.
- **Host**: lower case, percent-decoded, a final `.` dropped; an IPv6
  literal without its brackets. Punycode is left as it is (an open
  question below).
- **Path**: decoded segment by segment, then `.` and `..` resolved, so
  `%2E%2E` is `..`; empty segments dropped; a trailing `/` kept, since it
  names a directory (Phase 4). Refused (59), rather than clamped at the
  root as RFC 3986 does: `..` above `/`, and a segment decoding to `/`,
  a control character (NUL included) or malformed UTF-8. None names a
  file a server should serve, and refusing here spares Phase 4 from
  having to remember. `rawPath` keeps the path as sent, for redirects.
- **Query**: kept as sent, percent-encoding checked; `Decode` decodes it
  for a responder (1x input).
- **Port**: the request's must be the one listened on. Behind a port
  forward the two differ; Phase 3's configuration may need a public
  port.
- **SNI** isn't compared with the request's host: the specification
  doesn't ask it, and Phase 3 picks a capsule by the request's host.

Tests: `TestParse` (GemRequest alone, 82 checks) and `TestRequests` (the
server, by GemClient: hosts written several ways, 53s, 59s, then
openssl s_client, OpenBSD's nc, gemget and gnutls-cli each getting the
page, and the log counted by status). `TestServe`'s URLs now carry the
port, and its control character is a 59.

### Phase 3: configuration

The configuration file and command-line options ("Design"): capsules
(host, certificate, key, document root), listen addresses and port,
deadlines, logging; and a self-signed certificate made with `openssl`
for a capsule given none. The certificate must be made as polibtls's
`test/make-certs.sh` makes its own: options OpenSSL 3 and LibreSSL both
have, and `-sha256` named, since LibreSSL's `x509 -req` signs with
SHA-1 by default, which GnuTLS rejects (polibtls's AGENTS.md, "From the
port").

### Phase 4: serving files

Files under a capsule's root, the MIME type by extension, `index.gmi`
for a directory, 31 to add a directory's slash, 51 for none; symlinks
out of the root refused; large files sent in pieces.

### Phase 5: client certificates

Paths that require a client certificate (60), and what the server makes
of an expired or unaccepted one (61, 62).

### Phase 6: running it

Logging, a clean stop on SIGTERM (finish connections in progress),
limits on connections at once, running under systemd, and dropping
privileges if started as root.

### Phase 7: the BSDs

First polibtls's own port, done 2026-11-16 (its Phase 10, b828a53):
OpenBSD's libtls in base, LibreTLS from packages on FreeBSD and NetBSD,
its tests passing on amd64 and i386. Then this server's tests, by `gmake test`
on FreeBSD, OpenBSD and NetBSD hosts, and the self-signed certificate
made with each system's `openssl`. Anything Linux-only found is fixed
here, and a finding recorded in AGENTS.md.

### Phase 8: documentation and install

A user's guide, an example configuration, `make install`, on Linux and
the BSDs.

## Open questions

- ~~The configuration format: a small line-based file of our own, YAML
  through polibfyaml, or the command line only?~~ A file of our own and
  the command line (2026-11-16, with the user): "Design".
- ~~Certificates for users: generate a self-signed pair on first run, as
  many Gemini servers do (libtls can't; it would need OpenSSL's API, or
  running `openssl`), or document the `openssl` commands only?~~
  Generate one by running `openssl` when none is supplied (2026-11-16,
  with the user): "Design".
- ~~Does validating a request line belong here or in polibtls (polibtls's
  PLAN.md leaned towards here, with at most a bounded `ReadLine` in
  polibtls)?~~ Here: `GemServer` reads the line to CR LF within 1026
  bytes (Phase 1), and Phase 2 validates it. polibtls needs no
  `ReadLine`.
- ~~Which libtls on FreeBSD and NetBSD: LibreTLS from ports/pkgsrc, or
  LibreSSL's?~~ LibreTLS, from packages; OpenBSD's own in base
  (polibtls's Phase 10, 2026-11-16).
- Internationalised host names: should `bücher.example` in a request
  match a capsule named `xn--bcher-kva.example`, and the other way
  round? (~~IRIs in requests~~: their non-ASCII characters are accepted
  as UTF-8, Phase 2.)
- ~~A test client: our own module in `test/`, or polibtls's
  `GeminiFetch` (an example, not installed)?~~ Our own in `test/`
  (2026-11-16, with the user): "Design".
