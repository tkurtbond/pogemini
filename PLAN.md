# PLAN.md

pogemini's design and roadmap. Decisions and findings are appended to
the relevant section as they happen; a finished phase is marked
`[done]`, and a decided open question struck through.

## Goal and scope

A Gemini server, in Oberon-2 for poc, that a person can run to serve
one or more capsules from files, on Linux:

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
dynamic content, Titan uploads, proxying, and platforms other than
Linux.

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

From the specification (polibtls's AGENTS.md, "Reference material");
to be re-read before Phase 2, and corrected here where this is wrong:

- The request is an absolute URI, at most 1024 bytes, then CR LF; it
  must not begin with a byte order mark, and has no userinfo or
  fragment.
- The response header is a two-digit status, a space and its meta, CR
  LF; only a 2x response has a body, ended by the server closing the
  connection with TLS close_notify.
- TLS 1.2 or later, with SNI. Client certificates are mostly
  self-signed and are identities, not things a CA vouches for.

## Design

Nothing decided yet; to be settled in Phases 1 to 3. See "Open
questions".

### Halt codes

The poc runtime uses 10..20, and the po* libraries 61..99 (polibfyaml
61..65, pofltk 70..78, posockets 80..89, polibtls 90..99). A module of
this server that asserts a programmer's error uses 100..109.

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

### Phase 1: a first server

GeminiHello's structure as `src/`: listeners, accept tasks, a task per
connection with a deadline, one capsule from the command line, every
request answered with a fixed page; tests as in polibtls, against the
server as a child process, with a test client.

### Phase 2: requests

Parsing and validating the request URL (scheme, host, port, path,
percent-encoding, the limits above), statuses 59 and 53, and the path
normalised (`.` and `..` resolved) before it goes anywhere near the
file system.

### Phase 3: configuration

The configuration: capsules (host, certificate, key, document root),
listen addresses and port, deadlines, logging. Its format is an open
question.

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

### Phase 7: documentation and install

A user's guide, an example configuration, `make install`.

## Open questions

- The configuration format: a small line-based file of our own, YAML
  through polibfyaml, or the command line only?
- Certificates for users: generate a self-signed pair on first run, as
  many Gemini servers do (libtls can't; it would need OpenSSL's API, or
  running `openssl`), or document the `openssl` commands only?
- Does validating a request line belong here or in polibtls (polibtls's
  PLAN.md leaned towards here, with at most a bounded `ReadLine` in
  polibtls)?
- Internationalised host names (punycode) and IRIs in requests.
- A test client: our own module in `test/`, or polibtls's
  `GeminiFetch` (an example, not installed)?
