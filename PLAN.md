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
  can't forge a line. Phase 6 added the time.
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
| 105 | GemCert | `Ensure` for a capsule with no name, or with a certificate or key |

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

### Phase 3: configuration [done]

The configuration file and command-line options ("Design"): capsules
(host, certificate, key, document root), listen addresses and port,
deadlines, logging; and a self-signed certificate made with `openssl`
for a capsule given none. The certificate must be made as polibtls's
`test/make-certs.sh` makes its own: options OpenSSL 3 and LibreSSL both
have, and `-sha256` named, since LibreSSL's `x509 -req` signs with
SHA-1 by default, which GnuTLS rejects (polibtls's AGENTS.md, "From the
port").

Decided, 2026-11-16 (`GemConfig`, `GemCert`, `pogemini`):

- **The file** is a line per setting, `keyword value`; `#` at the start
  of a word begins a comment; blank lines are ignored. A value is the
  rest of the line, trimmed, so a file name may hold spaces (and a `#`
  not after a space); a name or number is one word. Global settings
  (`listen`, `port`, `deadline`, `certdir`) come first; `capsule name`
  begins a capsule, and `alias`, `root`, `cert` and `key` after it are
  its own. A mistake is reported as `file:line: reason`, and the server
  exits 1 (2 for a mistake in the options, with the usage).
- **Capsule names** are kept in lower case and must be DNS names
  (letters, digits, hyphens, labels of 1 to 63, no final dot) or IP
  addresses written plainly (`::1`): they name files and go to
  `openssl`'s command line, so nothing else is let through, non-ASCII
  included (the punycode question stays open). A name or alias may
  belong to one capsule only.
- **The command line** overrides the file's global settings, and its
  capsule options make one more capsule, put first: its name is the
  first `-host`, the others its aliases, with `-root`, `-cert`, `-key`.
  Without `-host` it is a capsule for any host, answering what no named
  capsule has (as Phases 1 and 2 did); it needs `-cert` and `-key`, and
  has no aliases.
- **Choosing a capsule**: by the request's host, among names and
  aliases, else the capsule for any host, else 53. libtls chooses the
  key pair by SNI against each certificate's names, the first pair for
  a client that sends none (or a name no certificate has), so the
  first capsule is the default; all the pairs go into one `Tls.Config`
  (`SetKeypairFile`, then `AddKeypairFile`). An alias that a supplied
  certificate doesn't name is answered by its capsule, but over the
  first capsule's certificate (`TestCapsules`, www.other.example).
- **Made certificates** (`GemCert`): for a capsule with neither `cert`
  nor `key`, `<certdir>/<name>.crt` and `.key`, made once and then used
  as they are, since clients pin them (TOFU). `certdir` defaults to
  `$XDG_DATA_HOME/pogemini/certs`, else `~/.local/share/pogemini/certs`.
  ECDSA P-256, `-sha256`, 3650 days, CN the name and subject
  alternative names the name and aliases (`IP:` for an address), made
  by `openssl genpkey` and `req -x509` with a configuration of its own,
  as `make-certs.sh` does, under `umask 077` in a directory made by
  `mkdir -p`, then the certificate `chmod 644`. Written under temporary
  names and renamed key first, certificate last, so a pair is complete
  exactly when its `.crt` exists: a `.key` alone is made again, a
  `.crt` alone is refused. The directory's name may not hold a `'`,
  since it is quoted for the shell. Without `openssl` on `PATH`, the
  server says so and exits 1. Made before the server listens, so a
  slow `openssl` only delays the start.
- **A capsule's root** must be a directory if given; Phase 4 serves it.
- **Not done here**: `listen` takes one address (or all), as
  `GemServer.Listen` does; logging stays as Phase 1's, for Phase 6; a
  public port differing from the one listened on (behind a port
  forward) isn't configurable yet, and a request's port must still be
  the listened one.

Tests: `TestConfig` (GemConfig alone: a file with every setting, CR LF
lines, 21 mistakes each refused with its line and reason, and a
missing file) and
`TestCapsules` (the server with three capsules from a file: pages and
certificates chosen by host and SNI, the default certificate without
SNI, a certificate made for one and reused on a second run, its key
mode 600, `-cert` alone as a capsule for any host; then a mistake in
the file, a missing file, a lone `.crt`, a root that isn't a
directory, a certificate without its key, `openssl` missing, no capsule,
and a mismatched key pair, each stopping it with its reason).

### Phase 4: serving files [done]

Files under a capsule's root, the MIME type by extension, `index.gmi`
for a directory, 31 to add a directory's slash, 51 for none; symlinks
out of the root refused; large files sent in pieces.

Done 2026-11-16: `src/GemFiles.Mod`, with a C part, `src/GemFiles.c`
(`realpath`, `open`, `fstat`, `read`: POSIX, the same on the BSDs).
Decided:

- **What is served**: regular files only. A directory asked for with
  a final `/` gives its `index.gmi`, or 51: no listings. Without the
  `/`, 31 to the path as sent (`rawPath`) with `/` added, the query
  kept, as a reference relative to the request, so its index's links
  resolve against the directory. An empty path is `/`, served without a
  redirect, as the specification requires.
- **Hidden names**: a segment beginning with `.` is refused (51),
  in the request and in the resolved path (so a link to `.git/config`
  is refused too). By Unix custom such names are not for publishing,
  and `.git` is the usual leak.
- **Symbolic links**: followed while they stay inside the root, refused
  (51) when they lead out. The root is resolved once at start (it may
  itself be a link), each file's path resolved by `realpath` and
  compared with it, and the file opened by its resolved path with
  `O_NOFOLLOW`. A directory above it swapped for a link between the two
  could still lead out; only someone who can write under the root can
  do that, and they can already change what is served. Recorded in
  GemFiles's comment.
- **Everything not served is 51 "not found"**: not there, outside the
  root, hidden, unreadable (`EACCES`), not a regular file (a FIFO is
  opened with `O_NONBLOCK`, so it can't stop the server, then refused).
  A client learns nothing of what exists. A failure of the server's
  own (too many files open, an I/O error) is 40.
- **MIME types**: a fixed table by extension, case-insensitive,
  `application/octet-stream` for the rest; no `charset`, since the
  specification makes UTF-8 the default for text. Configurable types
  and `lang=` are left for later.
- **Large files** go in 16 KiB pieces read into a heap buffer, not the
  task's stack. A read from disk blocks every task while it lasts,
  accepted as short beside the network. A read that fails part way
  leaves the client a response ended as if complete: Gemini has no way
  to say otherwise.
- **A capsule without a root** answers `/` with a page naming it and
  anything else 51, so tests that need no files give none.
- No descriptor is left open: 100 requests of each kind left the
  server's count of open descriptors as it was (checked by hand, on
  Linux's `/proc`, not in a test).

Tests: `TestFiles` (a root given by a link to it: types by extension,
names with a space or not ASCII, a 1 MiB file whole, by GemClient and
`openssl s_client`; directories with and without `/`, a query kept in
the redirect; links in and out of the root, to files and directories;
hidden names, also percent-encoded and through a link; a FIFO; a file it
can't read, unless run as root; and a capsule without a root). `TestServe`'s
longest request is now answered 51, there being no such file, and
`TestRequests`'s other clients ask for `/?<client>`.

### Phase 5: client certificates [done]

Paths that require a client certificate (60), and what the server makes
of an expired or unaccepted one (61, 62).

Decisions (2026-11-16):

- **A require is a path in a capsule** (`require /private` in the
  file, `-require` on the command line), covering itself and everything
  below it, segment by segment: `/private` covers `/private/a.gmi`, not
  `/privateer`; `/` the whole capsule, its built-in page included. It is
  written decoded, as GemRequest gives a request's path; one with an
  empty, `.` or `..` segment, which no request has, is refused, and a
  final `/` dropped.
- **Identities** are `identity SHA256:<hex>` lines after a require,
  narrowing it to those certificates (any if none), written as the log
  shows a hash, the hex in either case. Only in the file: the command
  line's `-require` takes any certificate, since a list of hashes
  belongs in a file, not a process listing.
- **The status**: 60 without a certificate; 62 for one outside its
  dates, which the server checks itself (libtls checks nothing when
  verification is off, polibtls's `PeerCertNotAfter`), and only inside
  a require, since elsewhere a certificate is only logged; 61 for one
  not among the require's identities. An expired certificate not listed
  either is 62: its dates are checked first.
- **Nested requires all apply**, so an inner one can only narrow an
  outer one, never widen it (`/members` lists two, `/members/inner`
  one of them).
- **The request's path is checked before the file is looked up**, so a
  file that isn't there, a directory without its `/` (no 31), anything,
  gets 60 alike, and a client learns nothing of what is inside. **The
  file's real path is checked too** (GemFiles, with the path
  `gemfiles_open` resolved), so a symbolic link from outside a require
  into it needs what the require needs. A hard link can't be told from
  the file; whoever could make one could copy the file as well.
- **Halt codes**: none new; a mistake in a require or identity is a
  configuration error, reported with its line, exit 1.

Tests: `TestConfig` (requires and identities read and normalised,
`Within`, eleven ways to get one wrong), `TestCerts` (the server with a
configuration file of three requires, one nested: 20, 60, 61 and 62 by
GemClient with the tests' client certificates, EC and RSA, an expired
one, none; a missing file and a directory without `/` inside; links into
a require; the hashes, from `openssl x509 -fingerprint`, one given in
capitals; the log; and `-require /` on a capsule without a root).

### Phase 6: running it [done]

Logging, a clean stop on SIGTERM (finish connections in progress),
limits on connections at once, running under systemd, and dropping
privileges if started as root.

Done 2026-11-16: `src/GemServer.c` (signals, the time) and
`src/GemUser` with `src/GemUser.c` (`getpwnam`, `initgroups`,
`setgid`, `setuid`: on the BSDs too). Decided:

- **The log** stays on standard output, a line per connection, each
  now beginning with the time in UTC, `2026-11-16T12:34:56Z`, so a log
  redirected to a file is complete; under systemd the journal adds its
  own, which does no harm. The first line, `port <n>`, has none: it
  is for whoever started the server. No log levels, no file of its own:
  where it goes is the caller's choice (redirection, the journal).
- **Stopping**: SIGTERM and SIGINT are caught by a handler of our own in
  C that only notes the signal (a `sig_atomic_t`); each accept task
  looks every `Tick` (200 ms), stops accepting, and closes its
  listener, so a new client is refused at once rather than queued. The
  connections in progress finish, bounded by their deadline; then
  `Serve` returns and the server exits 0, having logged `stopping on
  signal <n>, connections in progress: <k>` and `stopped`. The handler
  is installed with `SA_RESETHAND`, so a second signal ends the server
  at once. Platform has setters only for SIGINT, SIGQUIT and SIGILL,
  hence the C. `Tasks.Event` could wake the accept tasks sooner, but
  200 ms is soon enough.
- **The limit**: at most `connections` (option `-connections`,
  default 256, 1..100000) at once. At the limit the accept tasks wait
  on a `Tasks.Condition` that each connection's end signals, so a
  client waits in the kernel's listen queue, not refused. Finished
  connections' tasks are dropped from the server's list at each accept
  (`Tasks.Done`), so it no longer grows for as long as the server runs.
- **Dropping privileges**: `user` (option `-user`). Started as root,
  the server becomes the user, with its groups (`initgroups`, `setgid`,
  `setuid`, then a check that root can't be had back) once its key
  pairs are loaded and it listens, so keys only root may read and ports
  below 1024 still work. Without one, as root, it refuses to start:
  a server reading files as root is one mistake from serving any of
  them; `-user root` keeps root for whoever really wants it. Not root,
  `user` may name only the user it is. Self-signed certificates are
  still made before, as root, in root's `certdir`. chroot, and
  OpenBSD's `pledge` and `unveil`, are possible later.
- **systemd**: `contrib/pogemini.service`, which starts it as its user
  (`User=gemini`), so no `-user`; the made certificates in its
  `StateDirectory` (`XDG_DATA_HOME=/var/lib`); sandboxing options; and
  a stop by SIGTERM, which ends with `Result=success`. Checked with
  `systemd-analyze verify`, and the stop under `systemd-run --user`
  (2026-11-16), not as a system service, which needs root.

Tests: `TestConfig` (`connections` and `user`, four mistakes), `TestRun`
(SIGTERM with a client mid-exchange: a new client refused on IPv4 and
IPv6, the one in progress answered, exit 0 and the two lines; SIGINT
with none; `-connections 1` making a second client wait for a silent
first, `-connections 2` not; the time on every line; `-user` as the
user it is, root and an unknown user refused, and, only as root, no
`-user` refused), and `TestServe`'s exact lines read after the time.

### Phase 7: the BSDs [done]

First polibtls's own port, done 2026-11-16 (its Phase 10, b828a53):
OpenBSD's libtls in base, LibreTLS from packages on FreeBSD and NetBSD,
its tests passing on amd64 and i386. Then this server's tests, by `gmake test`
on FreeBSD, OpenBSD and NetBSD hosts, and the self-signed certificate
made with each system's `openssl`. Anything Linux-only found is fixed
here, and a finding recorded in AGENTS.md.

Done 2026-11-16: `gmake test` passes on FreeBSD 15.1 amd64 (alerik),
NetBSD 11.0 amd64 (artos) and i386 (yishana), and OpenBSD 7.9 amd64
(jherek) and i386 (cymoril), with poc 0.13.0, polibtls at b828a53 and
posockets at 059b47d installed from `git archive` into the copy's own
library directory, TestRun passing five times more on each. Nothing in
the code was Linux-only, and the certificates, made and checked with
LibreSSL's `openssl` on OpenBSD and OpenSSL 3's elsewhere, needed no
change. The clients a host lacks are skipped, saying so: gemget
everywhere, OpenBSD's nc on FreeBSD and NetBSD, gnutls-cli on NetBSD
and jherek. Two faults, both in Phase 6's code and both only on the
BSDs:

- **A signal sent as soon as the port was printed killed the server**
  (NetBSD amd64, now and then): Serve installed the handler, after
  pogemini printed `port`, so a test that read the port and sent
  SIGINT at once could find the default action still in place. Listen
  installs it now, before the port can be known.
- **The log's time overran a task's stack** (NetBSD i386, every run
  that served a request; status 139, a segfault in `OPENSSL_cleanup` at
  exit, walking a heap something had overwritten). The first
  `gmtime_r` loads the UTC zone (`tzload`), with large buffers on the
  stack, and the first was in a connection's task, on a 64 KiB stack.
  Run in a thread with a stack of a given size (with a guard page), the
  first `gmtime_r` and `strftime` needs more than 64 KiB on NetBSD
  (amd64 and i386 alike: 64 KiB crashed, 80 KiB did not), more than 32
  on OpenBSD, and fits in 16 on FreeBSD and glibc. Where it doesn't fit
  a task, it writes below the stack without touching the guard page,
  so a large frame corrupts whatever lies there, or nothing (artos, by
  luck). `GemServer.-now` now works the date out from `time()` by
  arithmetic (Hinnant's `civil_from_days`), with no zone at all; it
  matched glibc's `gmtime_r` for 1,538,207 times from 1970 to 2400,
  and runs in a 16 KiB thread on NetBSD and OpenBSD.

So C that a task calls must fit in a task's stack, and libc may use
far more than its interface suggests: a function that loads something
on first use is suspect. GemFiles' `realpath` and `open` are the other
libc calls in tasks; run the same way, they fit in a 16 KiB stack on
every host.

### Phase 8: documentation and install [done]

A user's guide, an example configuration, `make install`, on Linux and
the BSDs.

Done 2026-11-16:

- README.md is the user's guide: requirements, building and installing,
  a first capsule, a configuration, running it as a service.
  `doc/pogemini.1` is the reference, in mdoc so that mandoc (the BSDs)
  and groff (Linux) both read it; `mandoc -T lint -W warning` is clean.
- `contrib/pogemini.conf` is a commented example configuration;
  `TestConfig` reads it and checks every setting, so it can't drift
  from the parser.
- `make install` puts `bin/pogemini`, `man1/pogemini.1` and
  `share/doc/pogemini` (README, LICENSE, the example configuration,
  the systemd unit) under `PREFIX`, `~/.local` by default, with
  `DESTDIR` for packaging; `make uninstall` removes them. Decisions:
  - install doesn't build, so it can be run as root after `make` as
    the user, and fails, saying so, if nothing was built;
  - `POCLIBDIR` no longer follows `PREFIX`: it is where the libraries
    are, not where the program goes;
  - `MANDIR` is `$(PREFIX)/man` on NetBSD and OpenBSD, whose `man`
    looks there (NetBSD's default path is `/usr/{share,X11R7,pkg,local}/man`),
    and `$(PREFIX)/share/man` on Linux and FreeBSD;
  - no rc script for the BSDs yet; README says how to start it from rc
    (since added: "rc scripts for the BSDs", below).
- Checked: on Linux, `make clean && make test` (299 ok), install into a
  temporary prefix, `man -l` the page, the README's first capsule from
  the installed program (status 20, the certificate made once), and
  uninstall leaving no file. On all five BSD hosts, `gmake test` (exit
  0; ok 296 to 298, by the clients each lacks), then install, `man
  pogemini` through `MANPATH`, the installed program run, and
  uninstall leaving no file. OpenBSD's `man` notes that a prefix's
  `mandoc.db` lacks the page until `makewhatis` is run on it; it shows
  the page regardless. The program links libtls (with OpenSSL or
  LibreSSL under it) and the C library, nothing
  of poc's.

### rc scripts for the BSDs [done]

Asked for after Phase 8. Done 2026-11-16: `contrib/freebsd/pogemini`,
`contrib/netbsd/pogemini` and `contrib/openbsd/pogemini`, one per
system, since their rc frameworks differ; `make install` puts the one
for the system it runs on (by `uname -s`) in `$(DOCDIR)/rc.d`, mode
555, and none on Linux. Decisions and findings:

- All three start pogemini as root, so it reads root's keys and binds
  1965, and it becomes the configuration's `user`; stopping is SIGTERM,
  and there is no reload, since pogemini doesn't catch SIGHUP. The
  configuration is `/usr/local/etc/pogemini.conf` on FreeBSD and
  NetBSD, `/etc/pogemini.conf` on OpenBSD, as each system's own
  daemons do.
- **FreeBSD**: daemon(8) `-f -H -o /var/log/pogemini.log -p
  /var/run/pogemini.pid -P /var/run/pogemini.daemon.pid`. Two
  rc.subr pitfalls: `${name}_flags` goes before `command_args`, so to
  daemon(8), and options for pogemini are `pogemini_args`; and
  `${name}_program` silently replaces `command`, so the program's path
  is `pogemini_bin` (named `pogemini_program` at first, it ran
  pogemini with daemon(8)'s options). The log is a file, not syslog:
  with `-S`, daemon(8) hands syslog each read of the output, so two
  lines written together ("stopping on signal 15" and "stopped")
  became one record. `-H` reopens the file on SIGHUP to daemon(8),
  so newsyslog rotates it by `/var/run/pogemini.daemon.pid` (checked:
  moved, HUPed, the next line in the new file).
- **NetBSD**: no daemon(8). rc.subr evaluates the command line, so
  `command_args` ends `2>&1 | logger -t pogemini -p daemon.info &`;
  no pidfile, rc.subr finds the process by its path; logger exits when
  pogemini does.
- **OpenBSD**: `rc_bg=YES` and `daemon_logger=daemon.info`;
  `rc_reload=NO`. Flags from `rcctl set` replace `daemon_flags`
  whole, so the comment says to keep `-config`.
- On NetBSD and OpenBSD, logger splits a line over about 1000 bytes in
  two (a 1024-byte request: 1055 and 70 bytes on NetBSD, 1063 and 77 on
  OpenBSD); documented, not avoided.
- A mistake in the configuration is logged, and pogemini exits; rc
  reports it on OpenBSD only (`pogemini(failed)`), since FreeBSD's and
  NetBSD's start return before pogemini reads its file.
- Checked as root on alerik (FreeBSD 15.1), artos (NetBSD 11.0) and
  jherek (OpenBSD 7.9), amd64: start, status, a second start refused,
  a fetch (20) and a 1024-byte request (51) logged, stop with the
  pidfiles gone, and a bad configuration; and `gmake install` and
  `uninstall` with each script. Not run on the i386 hosts.

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
