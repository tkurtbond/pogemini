MODULE TestServe; (* The server, as a child process, against our client *)

(* Starts build/pogemini on port 0, as a user would start it, reads the
   port from its first line, and sends it requests from a task, by
   GemClient: over IPv4 and IPv6, with and without a client
   certificate, at and past the longest request, with a control
   character, and from two clients that say nothing, which must not
   hold up a third and must be dropped at the server's deadline. Then
   the server, told how many connections to serve, must exit 0 with a
   line in its log for each. Once more with an RSA key pair. *)

IMPORT Out, Platform, Tasks, Sockets, SocketTasks, Check, Child,
  GemClient;

CONST
  Certs = "../build/certs/";
  Client1Crt = "../build/certs/client1-ec.crt";
  Client1Key = "../build/certs/client1-ec.key";
  Deadline = 1000;  (* the server's, ms: short, for the silent clients *)
  Count = 10;       (* the connections Test makes *)
  CR = 0DX; LF = 0AX;
  Home = "gemini://localhost/";
  (* The test's tasks pass whole responses (64 KiB) by value, to
     Check.Contains, so they need more than TlsTasks.stackSize. *)
  StackSize = 1024 * 1024;

TYPE
  Test = POINTER TO RECORD (Tasks.TaskDesc) port: INTEGER END;
  Rsa = POINTER TO RECORD (Tasks.TaskDesc) port: INTEGER END;

VAR
  hash: ARRAY 128 OF CHAR;  (* client1-ec.crt's, as the log gives it *)
  longest: ARRAY 1100 OF CHAR;  (* a URL of 1024 bytes, the most there may be *)

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

(* How many times part occurs in s. *)
PROCEDURE Occurs(s, part: ARRAY OF CHAR): INTEGER;
  VAR i, j: LONGINT; n: INTEGER;
BEGIN
  n := 0; i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    j := 0;
    WHILE (part[j] # 0X) & (i + j < LEN(s)) & (s[i + j] = part[j]) DO INC(j) END;
    IF part[j] = 0X THEN INC(n) END;
    INC(i)
  END;
  RETURN n
END Occurs;

(* How many lines of log are line. *)
PROCEDURE Lines(log, line: ARRAY OF CHAR): INTEGER;
  VAR l: ARRAY 1300 OF CHAR; i, j: LONGINT; n: INTEGER;
BEGIN
  n := 0; i := 0;
  WHILE (i < LEN(log)) & (log[i] # 0X) DO
    j := 0;
    WHILE (i < LEN(log)) & (log[i] # 0X) & (log[i] # LF) DO
      IF j < LEN(l) - 1 THEN l[j] := log[i]; INC(j) END;
      INC(i)
    END;
    l[j] := 0X;
    IF l = line THEN INC(n) END;
    IF (i < LEN(log)) & (log[i] = LF) THEN INC(i) END
  END;
  RETURN n
END Lines;

(* A request line: url and CR LF. *)
PROCEDURE Request(url: ARRAY OF CHAR; VAR req: ARRAY OF CHAR; VAR len: LONGINT);
BEGIN
  COPY(url, req); len := Length(req);
  req[len] := CR; req[len + 1] := LF; req[len + 2] := 0X; INC(len, 2)
END Request;

(* A response's header line, up to its CR LF. *)
PROCEDURE Header(r: GemClient.Response; VAR h: ARRAY OF CHAR);
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i < r.len) & (r.data[i] # CR) & (i < LEN(h) - 1) DO h[i] := r.data[i]; INC(i) END;
  h[i] := 0X
END Header;

PROCEDURE Fetch(host: ARRAY OF CHAR; port: INTEGER; url, cert, key: ARRAY OF CHAR): GemClient.Response;
  VAR req: ARRAY 1100 OF CHAR; len: LONGINT;
BEGIN
  Request(url, req, len);
  RETURN GemClient.Fetch(host, port, req, len, cert, key)
END Fetch;

(* r is complete, ended by close_notify, with header h. *)
PROCEDURE Expect(r: GemClient.Response; h, label: ARRAY OF CHAR);
  VAR got: ARRAY 1100 OF CHAR;
BEGIN
  Header(r, got);
  Check.Check(r.ok & (got = h), label);
  IF ~r.ok THEN Out.String("  error: "); Out.String(r.error); Out.Ln
  ELSIF got # h THEN Out.String("  header: "); Out.String(got); Out.Ln
  END
END Expect;

PROCEDURE (t: Test) Run*;
  VAR r: GemClient.Response; req: ARRAY 1200 OF CHAR; i, len, n, start: LONGINT;
    silent: GemClient.Conn; tcp: Sockets.Socket; err: Sockets.Error;
    error: ARRAY 256 OF CHAR; buf: ARRAY 16 OF CHAR;
BEGIN
  r := Fetch("127.0.0.1", t.port, Home, "", "");
  Expect(r, "20 text/gemini", "IPv4: 20 text/gemini");
  Check.Check(Check.Contains(r.data^, "# pogemini"), "IPv4: the page");
  r := Fetch("::1", t.port, Home, "", "");
  Expect(r, "20 text/gemini", "IPv6: 20 text/gemini");
  r := Fetch("127.0.0.1", t.port, Home, Client1Crt, Client1Key);
  Expect(r, "20 text/gemini", "with a client certificate: 20 text/gemini");

  (* The longest request there may be is served, and one byte longer
     is refused; so is one without CR LF in the first 1026 bytes. *)
  r := Fetch("127.0.0.1", t.port, longest, "", "");
  Expect(r, "20 text/gemini", "a 1024-byte request: 20");
  COPY(longest, req); Append(req, "a");
  r := Fetch("127.0.0.1", t.port, req, "", "");
  Expect(r, "59 request too long, or no CR LF", "a 1025-byte request: 59");
  FOR i := 0 TO 1099 DO req[i] := "a" END;
  r := GemClient.Fetch("127.0.0.1", t.port, req, 1100, "", "");
  Expect(r, "59 request too long, or no CR LF", "1100 bytes without CR LF: 59");

  req := "gemini://localhost/a"; Append(req, 09X); Append(req, "b");
  r := Fetch("127.0.0.1", t.port, req, "", "");
  Expect(r, "20 text/gemini", "a control character in the request: 20");

  (* Two clients that say nothing: one connects and makes no handshake,
     the other makes one and sends no request. Neither holds up a
     third, and the server drops both at its deadline. *)
  start := Platform.Time();
  IF ~SocketTasks.Connect("127.0.0.1", t.port, GemClient.Deadline, tcp, err) THEN
    Check.Check(FALSE, "a silent TCP client connects"); Out.String("  "); Out.String(err.text); Out.Ln;
    tcp := NIL
  END;
  IF ~GemClient.Open("127.0.0.1", t.port, "", "", silent, error) THEN
    Check.Check(FALSE, "a silent TLS client connects"); Out.String("  "); Out.String(error); Out.Ln;
    silent := NIL
  END;
  r := Fetch("127.0.0.1", t.port, Home, "", "");
  Expect(r, "20 text/gemini", "served while two clients say nothing");
  Check.Check(Platform.Time() - start < Deadline, "  ... without waiting for them");
  IF silent # NIL THEN
    r := GemClient.Receive(silent);
    n := Platform.Time() - start;
    Check.Check(~r.ok & (r.len = 0), "the silent TLS client is dropped, without close_notify");
    Check.Check((n >= Deadline - 100) & (n < GemClient.Deadline), "  ... at the deadline");
    GemClient.Close(silent)
  END;
  IF tcp # NIL THEN
    Sockets.SetDeadline(tcp, GemClient.Deadline);
    Check.Check(~SocketTasks.Read(tcp, buf, 0, LEN(buf), len, err) & (err.kind = Sockets.closed),
      "the silent TCP client is dropped");
    Sockets.Close(tcp)
  END
END Run;

PROCEDURE (t: Rsa) Run*;
  VAR r: GemClient.Response;
BEGIN
  r := Fetch("127.0.0.1", t.port, Home, "", "");
  Expect(r, "20 text/gemini", "RSA: 20 text/gemini")
END Run;

(* Starts the server with the key pair self-<kind> to serve count
   connections, and reads the port it listens on. *)
PROCEDURE Start(kind: ARRAY OF CHAR; count: INTEGER; VAR c: Child.Child;
    VAR port: INTEGER): BOOLEAN;
  VAR cmd: ARRAY 512 OF CHAR; line: ARRAY 64 OF CHAR; n: ARRAY 8 OF CHAR;
    i: INTEGER; p: LONGINT;
BEGIN
  cmd := "exec ../build/pogemini -port 0 -deadline ";
  n[0] := CHR(ORD("0") + Deadline DIV 1000); n[1] := "0"; n[2] := "0"; n[3] := "0"; n[4] := 0X;
  Append(cmd, n); Append(cmd, " -n ");
  n[0] := CHR(ORD("0") + count DIV 10); n[1] := CHR(ORD("0") + count MOD 10); n[2] := 0X;
  Append(cmd, n);
  Append(cmd, " -cert "); Append(cmd, Certs); Append(cmd, "self-"); Append(cmd, kind);
  Append(cmd, ".crt -key "); Append(cmd, Certs); Append(cmd, "self-"); Append(cmd, kind);
  Append(cmd, ".key");
  IF ~Child.Spawn(cmd, "", 0, c) THEN RETURN FALSE END;
  IF ~Child.ReadLine(c, line, 5000) OR ~StartsWith(line, "port ") THEN
    Out.String("  "); Out.String(line); Child.Kill(c); RETURN FALSE
  END;
  p := 0; i := 5;
  WHILE (line[i] >= "0") & (line[i] <= "9") DO p := p * 10 + ORD(line[i]) - ORD("0"); INC(i) END;
  port := SHORT(p);
  RETURN (p > 0) & (p <= 65535)
END Start;

(* The certificate's hash as libtls gives it: "SHA256:", lowercase hex. *)
PROCEDURE Hash(crt: ARRAY OF CHAR; VAR h: ARRAY OF CHAR);
  VAR c: Child.Child; cmd: ARRAY 256 OF CHAR; n: LONGINT;
BEGIN
  cmd := "openssl x509 -noout -fingerprint -sha256 -in "; Append(cmd, crt);
  Append(cmd, " | sed 's/^[^=]*=//; s/://g' | tr A-F a-f");
  COPY("SHA256:", h);
  IF Child.Spawn(cmd, "", 0, c) & (Child.Wait(c, cmd, n) = 0) & (n > 1) THEN
    cmd[n - 1] := 0X; Append(h, cmd)
  ELSE COPY("(no hash)", h)
  END
END Hash;

PROCEDURE Main;
  VAR c: Child.Child; t: Test; rsa: Rsa; port: INTEGER; i: LONGINT;
    log: ARRAY 65536 OF CHAR; line: ARRAY 1200 OF CHAR;
BEGIN
  Hash(Client1Crt, hash);
  longest := Home; FOR i := Length(Home) TO 1023 DO longest[i] := "a" END; longest[1024] := 0X;

  IF ~Start("ec", Count, c, port) THEN
    Check.Check(FALSE, "the server starts and says its port");
    IF Child.Wait(c, log, i) # 0 THEN END; Out.String(log); Out.Ln
  ELSE
    NEW(t); t.port := port; Tasks.Start(t, StackSize); Tasks.Join(t);
    Check.Check(Child.Wait(c, log, i) = 0, "the server exits 0 after its connections");
    Check.Check(Occurs(log, LF) = Count, "  ... with a line for each");
    Check.Check(Lines(log, "127.0.0.1 20 gemini://localhost/ -") = 2, "log: IPv4, no certificate");
    Check.Check(Lines(log, "::1 20 gemini://localhost/ -") = 1, "log: IPv6");
    line := "127.0.0.1 20 gemini://localhost/ "; Append(line, hash);
    Check.Check(Lines(log, line) = 1, "log: the client certificate's hash");
    line := "127.0.0.1 20 "; Append(line, longest); Append(line, " -");
    Check.Check(Lines(log, line) = 1, "log: the longest request, whole");
    Check.Check(Lines(log, "127.0.0.1 59 - -") = 2, "log: the two refused");
    Check.Check(Lines(log, "127.0.0.1 20 gemini://localhost/a%09b -") = 1,
      "log: the control character escaped");
    Check.Check(Lines(log, "127.0.0.1 failed: handshake timed out") = 1,
      "log: the silent TCP client timed out");
    Check.Check(Lines(log, "127.0.0.1 failed: read timed out") = 1,
      "log: the silent TLS client timed out");
    Out.String(log)
  END;

  IF ~Start("rsa", 1, c, port) THEN
    Check.Check(FALSE, "RSA: the server starts");
    IF Child.Wait(c, log, i) # 0 THEN END; Out.String(log); Out.Ln
  ELSE
    NEW(rsa); rsa.port := port; Tasks.Start(rsa, StackSize); Tasks.Join(rsa);
    Check.Check(Child.Wait(c, log, i) = 0, "RSA: the server exits 0")
  END;
  Check.Summary
END Main;

BEGIN
  Main
END TestServe.
