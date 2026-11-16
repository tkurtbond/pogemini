MODULE TestRequests; (* Requests through the server: refused, and served to other clients *)

(* Starts build/pogemini on port 0 serving localhost and ::1 (-host),
   and sends it, by GemClient, requests GemRequest must accept or refuse
   (TestParse checks it on its own): for its hosts, however written, for
   another host or port (53, since the server is no proxy), for another
   scheme (53), and with userinfo, a fragment, a path above the root, an
   encoded "/" or a byte order mark (59). The response must be the
   status, with the reason as its meta.

   Then the clients other people use, each on a TLS stack of its own:
   openssl s_client (OpenSSL's or LibreSSL's), OpenBSD's nc (libtls),
   gemget (Go) and gnutls-cli (GnuTLS), each run as a child process
   with the request on its standard input or command line, must get the
   page. nc is the first of $LIBTLS_NC, netcat and nc that is linked
   with libtls; gemget is $GEMGET or gemget, gnutls-cli $GNUTLS_CLI or
   gnutls-cli, openssl $OPENSSL or openssl, on PATH. Without one, its
   check is skipped, saying so. A client that hangs is ended by the
   server's deadline, which closes the connection (timeout(1) isn't on
   every system).

   Last, the server must exit 0 with a log line for each connection,
   counted by status. *)

IMPORT Out, Tasks, Check, Child, GemClient;

CONST
  Deadline = 5000;  (* the server's, ms *)
  Ours = 13;        (* the connections Test makes *)
  CR = 0DX; LF = 0AX;
  StackSize = 1024 * 1024;  (* see TestServe *)
  Bom = "﻿";  (* U+FEFF as UTF-8 *)

TYPE
  Text = ARRAY 1100 OF CHAR;
  Test = POINTER TO RECORD (Tasks.TaskDesc) port: INTEGER END;

VAR
  home: ARRAY 64 OF CHAR;     (* gemini://localhost:<port>/ *)
  portText: ARRAY 8 OF CHAR;  (* the server's port, in decimal *)
  got: ARRAY 65536 OF CHAR; gotLen: LONGINT;
  openssl, nc, gemget, gnutlsCli: Text;  (* each "" for none *)

PROCEDURE Length(s: ARRAY OF CHAR): LONGINT;
  VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END; RETURN n
END Length;

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := Length(s); j := 0;
  WHILE (i < LEN(s) - 1) & (j < LEN(t)) & (t[j] # 0X) DO s[i] := t[j]; INC(i); INC(j) END;
  s[i] := 0X
END Append;

PROCEDURE StartsWith(s, prefix: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (prefix[i] # 0X) & (i < LEN(s)) & (s[i] = prefix[i]) DO INC(i) END;
  RETURN prefix[i] = 0X
END StartsWith;

(* How many lines of log contain part. *)
PROCEDURE Lines(VAR log: ARRAY OF CHAR; part: ARRAY OF CHAR): INTEGER;
  VAR i, j, k: LONGINT; n: INTEGER; found: BOOLEAN;
BEGIN
  n := 0; i := 0;
  WHILE (i < LEN(log)) & (log[i] # 0X) DO
    found := FALSE;
    WHILE (i < LEN(log)) & (log[i] # 0X) & (log[i] # LF) DO
      j := 0; k := i;
      WHILE (part[j] # 0X) & (k < LEN(log)) & (log[k] = part[j]) DO INC(j); INC(k) END;
      IF part[j] = 0X THEN found := TRUE END;
      INC(i)
    END;
    IF found THEN INC(n) END;
    IF (i < LEN(log)) & (log[i] = LF) THEN INC(i) END
  END;
  RETURN n
END Lines;

(* got[0..gotLen-1] contains s. *)
PROCEDURE Has(s: ARRAY OF CHAR): BOOLEAN;
  VAR i, j, m: LONGINT;
BEGIN
  m := Length(s); i := 0;
  WHILE i + m <= gotLen DO
    j := 0; WHILE (j < m) & (got[i + j] = s[j]) DO INC(j) END;
    IF j = m THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END Has;

(* Runs command with input, then end of file, to its end: its exit
   status, and its output, standard error included, in got. *)
PROCEDURE Run(command, input: ARRAY OF CHAR): INTEGER;
  VAR c: Child.Child;
BEGIN
  gotLen := 0; got[0] := 0X;
  IF ~Child.Spawn(command, input, Length(input), c) THEN RETURN -1 END;
  RETURN Child.Wait(c, got, gotLen)
END Run;

(* The first line script, a shell command, prints, or "" if it exits
   nonzero. *)
PROCEDURE Find(script: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
  VAR i: LONGINT;
BEGIN
  path[0] := 0X;
  IF Run(script, "") = 0 THEN
    i := 0; WHILE (i < gotLen) & (i < LEN(path) - 1) & (got[i] # LF) DO path[i] := got[i]; INC(i) END;
    path[i] := 0X
  END
END Find;

PROCEDURE Found(name, path, how: ARRAY OF CHAR);
BEGIN
  IF path = "" THEN
    Out.String("skip - "); Out.String(name); Out.String(": not found ("); Out.String(how);
    Out.String(")")
  ELSE
    Out.String("# "); Out.String(name); Out.String(": "); Out.String(path)
  END;
  Out.Ln
END Found;

(* Sends url CR LF to host and port: the response must be complete, its
   header h. *)
PROCEDURE Expect(host: ARRAY OF CHAR; port: INTEGER; url, h, label: ARRAY OF CHAR);
  VAR req, got: Text; r: GemClient.Response; i, len: LONGINT;
BEGIN
  COPY(url, req); len := Length(req);
  req[len] := CR; req[len + 1] := LF; INC(len, 2);
  r := GemClient.Fetch(host, port, req, len, "", "");
  i := 0;
  WHILE (i < r.len) & (r.data[i] # CR) & (i < LEN(got) - 1) DO got[i] := r.data[i]; INC(i) END;
  got[i] := 0X;
  Check.Check(r.ok & (got = h), label);
  IF ~r.ok THEN Out.String("  error: "); Out.String(r.error); Out.Ln
  ELSIF got # h THEN Out.String("  header: "); Out.String(got); Out.Ln
  END
END Expect;

(* url is home with path after it. *)
PROCEDURE Url(path: ARRAY OF CHAR; VAR url: ARRAY OF CHAR);
BEGIN COPY(home, url); Append(url, path)
END Url;

PROCEDURE (t: Test) Run*;
  VAR u: Text;
BEGIN
  Expect("127.0.0.1", t.port, home, "20 text/gemini", "its host: 20");
  u := "gemini://LOCALHOST.:"; Append(u, portText);
  Expect("127.0.0.1", t.port, u, "20 text/gemini", "its host in capitals, a final dot, no path: 20");
  u := "gemini://[::1]:"; Append(u, portText); Append(u, "/");
  Expect("::1", t.port, u, "20 text/gemini", "its IPv6 address: 20");

  u := "gemini://127.0.0.1:"; Append(u, portText); Append(u, "/");
  Expect("127.0.0.1", t.port, u, "53 not served here", "an address it doesn't serve: 53");
  u := "gemini://other.example:"; Append(u, portText); Append(u, "/");
  Expect("127.0.0.1", t.port, u, "53 not served here", "another host: 53");
  Expect("127.0.0.1", t.port, "gemini://localhost/", "53 not served here",
    "another port (the default): 53");
  u := "https://localhost:"; Append(u, portText); Append(u, "/");
  Expect("127.0.0.1", t.port, u, "53 only gemini: URLs are served here", "https: 53");

  u := "gemini://user@localhost:"; Append(u, portText); Append(u, "/");
  Expect("127.0.0.1", t.port, u, "59 userinfo in the URL", "userinfo: 59");
  Url("#top", u);
  Expect("127.0.0.1", t.port, u, "59 a fragment", "a fragment: 59");
  Url("../etc/passwd", u);
  Expect("127.0.0.1", t.port, u, "59 the path climbs above /", "../etc/passwd: 59");
  Url("a%2F..%2F..%2Fetc", u);
  Expect("127.0.0.1", t.port, u, "59 an encoded / in the path", "an encoded /: 59");
  Expect("127.0.0.1", t.port, "/a", "59 not an absolute URL", "a path, not a URL: 59");
  u := Bom; Append(u, home);
  Expect("127.0.0.1", t.port, u, "59 not an absolute URL", "a byte order mark first: 59")
END Run;

(* Runs cmd, a client, with input: it must exit 0 with the page. *)
PROCEDURE Client(label, cmd, input: ARRAY OF CHAR);
  VAR s: INTEGER; ok: BOOLEAN;
BEGIN
  s := Run(cmd, input);
  ok := (s = 0) & Has("20 text/gemini") & Has("# pogemini");
  Check.Check(ok, label);
  IF ~ok THEN Out.String("  exit "); Out.Int(s, 0); Out.String(", output: "); Out.String(got); Out.Ln END
END Client;

(* The other clients, each fetching path. *)
PROCEDURE Others;
  VAR cmd, url, req: Text; i: LONGINT;
BEGIN
  IF openssl # "" THEN
    cmd := "exec "; Append(cmd, openssl);
    Append(cmd, " s_client -quiet -servername localhost -connect 127.0.0.1:");
    Append(cmd, portText);
    Url("openssl", req); i := Length(req); req[i] := CR; req[i + 1] := LF; req[i + 2] := 0X;
    Client("openssl s_client: the page", cmd, req)
  END;
  IF nc # "" THEN
    cmd := "exec "; Append(cmd, nc); Append(cmd, " -c -T noverify -e localhost 127.0.0.1 ");
    Append(cmd, portText);
    Url("nc", req); i := Length(req); req[i] := CR; req[i + 1] := LF; req[i + 2] := 0X;
    Client("nc -c (libtls): the page", cmd, req)
  END;
  IF gemget # "" THEN
    cmd := "exec "; Append(cmd, gemget); Append(cmd, " -o - --header ");
    Url("gemget", url); Append(cmd, url);
    Client("gemget (Go): the page", cmd, "")
  END;
  IF gnutlsCli # "" THEN
    cmd := "exec "; Append(cmd, gnutlsCli); Append(cmd, " --logfile=/dev/null --insecure -p ");
    Append(cmd, portText); Append(cmd, " localhost");
    Url("gnutls", req); i := Length(req); req[i] := CR; req[i + 1] := LF; req[i + 2] := 0X;
    Client("gnutls-cli (GnuTLS): the page", cmd, req)
  END
END Others;

PROCEDURE Main;
  VAR c: Child.Child; t: Test; cmd: Text; line: ARRAY 64 OF CHAR;
    log: ARRAY 65536 OF CHAR; i, n, count: LONGINT; others: INTEGER;
BEGIN
  Find('for n in "$OPENSSL" openssl; do command -v "$n" && exit 0; done; exit 1', openssl);
  Found("openssl", openssl, "install it, or set OPENSSL");
  Find('for n in "$LIBTLS_NC" netcat nc; do p=$(command -v "$n") && ldd "$p" 2>/dev/null | grep libtls >/dev/null && { echo "$p"; exit 0; }; done; exit 1', nc);
  Found("nc", nc, "one linked with libtls: install OpenBSD's netcat, or set LIBTLS_NC");
  Find('for n in "$GEMGET" gemget; do command -v "$n" && exit 0; done; exit 1', gemget);
  Found("gemget", gemget, "on PATH, or set GEMGET");
  Find('for n in "$GNUTLS_CLI" gnutls-cli; do command -v "$n" && exit 0; done; exit 1', gnutlsCli);
  Found("gnutls-cli", gnutlsCli, "install gnutls-utils, or set GNUTLS_CLI");
  others := 0;
  IF openssl # "" THEN INC(others) END; IF nc # "" THEN INC(others) END;
  IF gemget # "" THEN INC(others) END; IF gnutlsCli # "" THEN INC(others) END;
  count := Ours + others;

  cmd := "exec ../build/pogemini -host localhost -host ::1 -port 0 -deadline 5000 -n ";
  line[0] := CHR(ORD("0") + count DIV 10); line[1] := CHR(ORD("0") + count MOD 10); line[2] := 0X;
  Append(cmd, line);
  Append(cmd, " -cert ../build/certs/self-ec.crt -key ../build/certs/self-ec.key");
  IF ~Child.Spawn(cmd, "", 0, c) OR ~Child.ReadLine(c, line, 5000) OR ~StartsWith(line, "port ") THEN
    Check.Check(FALSE, "the server starts and says its port");
    Child.Kill(c); IF Child.Wait(c, log, n) # 0 THEN END; Out.String(log); Out.Ln;
    Check.Summary; RETURN
  END;
  i := 5; WHILE (line[i] >= "0") & (line[i] <= "9") DO portText[i - 5] := line[i]; INC(i) END;
  portText[i - 5] := 0X;
  home := "gemini://localhost:"; Append(home, portText); Append(home, "/");
  NEW(t); t.port := 0; i := 0;
  WHILE portText[i] # 0X DO t.port := t.port * 10 + ORD(portText[i]) - ORD("0"); INC(i) END;
  Tasks.Start(t, StackSize); Tasks.Join(t);
  Others;

  Check.Check(Child.Wait(c, log, n) = 0, "the server exits 0 after its connections");
  Out.String(log);
  Check.Check(Lines(log, " ") = count, "  ... with a line for each");
  Check.Check(Lines(log, " 20 ") = 3 + others, "log: the 20s");
  Check.Check(Lines(log, " 53 ") = 4, "log: the 53s");
  Check.Check(Lines(log, " 59 ") = 6, "log: the 59s");
  Check.Summary
END Main;

BEGIN
  Main
END TestRequests.
