MODULE TestCerts; (* Paths that need a client certificate: 60, 61, 62 *)

(* Starts build/pogemini with a configuration file giving localhost a
   root in ../build/test-certs, made afresh, and three requires:
   /private (any certificate), /members (client1-ec's or client2-ec's)
   and, inside it, /members/inner (client2-ec's only). Then, by
   GemClient, with no certificate or one of the tests' (make-certs.sh):

   - outside the requires, a page with none, or with an expired one,
     and "/privateer.gmi", which only begins like "/private";
   - inside, 60 without a certificate, whether the file is there or
     not, or is a directory asked for without its "/" (no 31 first), so
     nothing is revealed; 62 for an expired one; 61 for one not listed;
     and the page for one that may have it;
   - an inner require narrows the outer: client1-ec, a member, gets 61;
   - a symbolic link from outside into /private, to a file or the
     directory, needs a certificate as /private does.

   The identities are given as openssl prints the certificates' SHA-256
   fingerprints, made into libtls's form, one of them in capitals. The
   log must show each certificate's hash. Then a capsule given -require /
   on the command line, with no root, needs a certificate even for its
   page. Each time, the server must exit 0. *)

IMPORT Out, Files, Platform, Tasks, Check, Child, GemClient;

CONST
  Dir = "../build/test-certs";
  Certs = "../build/certs/";
  StackSize = 1024 * 1024;  (* see TestServe *)
  CR = 0DX; LF = 0AX;
  Ours = 22;   (* the connections Test makes in run 1 *)

TYPE
  Text = ARRAY 2048 OF CHAR;
  Hash = ARRAY 80 OF CHAR;
  Test = POINTER TO RECORD (Tasks.TaskDesc) run: INTEGER END;

VAR
  port: INTEGER; portText: ARRAY 8 OF CHAR;
  got: ARRAY 65536 OF CHAR; gotLen: LONGINT;
  hash1, hash2: Hash;  (* client1-ec's and client2-ec's *)

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

PROCEDURE IntToStr(x: LONGINT; VAR s: ARRAY OF CHAR);
  VAR d: ARRAY 24 OF CHAR; i, j: LONGINT;
BEGIN
  i := 0; REPEAT d[i] := CHR(ORD("0") + x MOD 10); x := x DIV 10; INC(i) UNTIL x = 0;
  j := 0; WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END; s[j] := 0X
END IntToStr;

(* Runs command to its end, with no input: its exit status, and its
   output, standard error included, in got. *)
PROCEDURE Run(command: ARRAY OF CHAR): INTEGER;
  VAR c: Child.Child;
BEGIN
  gotLen := 0; got[0] := 0X;
  IF ~Child.Spawn(command, "", 0, c) THEN RETURN -1 END;
  RETURN Child.Wait(c, got, gotLen)
END Run;

(* The SHA-256 hash of the certificate name in Certs, as libtls gives
   it, from openssl's fingerprint (AB:CD:..., after "="), in h: FALSE if
   openssl fails. *)
PROCEDURE CertHash(name: ARRAY OF CHAR; VAR h: ARRAY OF CHAR): BOOLEAN;
  VAR cmd: Text; i, j: LONGINT; ch: CHAR;
BEGIN
  cmd := "openssl x509 -noout -fingerprint -sha256 -in "; Append(cmd, Certs);
  Append(cmd, name); Append(cmd, ".crt");
  IF Run(cmd) # 0 THEN RETURN FALSE END;
  i := 0; WHILE (got[i] # 0X) & (got[i] # "=") DO INC(i) END;
  IF got[i] = 0X THEN RETURN FALSE END;
  COPY("SHA256:", h); j := 7; INC(i);
  WHILE (got[i] # 0X) & (got[i] # LF) & (j < LEN(h) - 1) DO
    ch := got[i];
    IF (ch >= "A") & (ch <= "F") THEN ch := CHR(ORD(ch) + 32) END;
    IF ch # ":" THEN h[j] := ch; INC(j) END;
    INC(i)
  END;
  h[j] := 0X;
  RETURN j = 7 + 64
END CertHash;

(* Writes text to the file name in Dir, each "|" a line feed. *)
PROCEDURE Write(name, text: ARRAY OF CHAR);
  VAR f: Files.File; r: Files.Rider; i: LONGINT; path: Text;
BEGIN
  path := Dir; Append(path, "/"); Append(path, name);
  f := Files.New(path); Files.Set(r, f, 0); i := 0;
  WHILE text[i] # 0X DO
    IF text[i] = "|" THEN Files.Write(r, LF) ELSE Files.Write(r, text[i]) END;
    INC(i)
  END;
  Files.Register(f)
END Write;

(* path, fetched with the certificate cert in Certs ("" for none), must
   be answered with header h, and, if body isn't "", that body exactly,
   each "|" in it a line feed. *)
PROCEDURE Expect(path, cert, h, body, label: ARRAY OF CHAR);
  VAR req, hh, crt, key: Text; r: GemClient.Response; len, b, i, n: LONGINT; ok: BOOLEAN;
BEGIN
  req := "gemini://localhost:"; Append(req, portText); Append(req, path);
  len := Length(req); req[len] := CR; req[len + 1] := LF; INC(len, 2);
  crt := ""; key := "";
  IF cert # "" THEN
    crt := Certs; Append(crt, cert); key := crt; Append(crt, ".crt"); Append(key, ".key")
  END;
  r := GemClient.Fetch("127.0.0.1", port, req, len, crt, key);
  IF ~r.ok THEN
    Check.Check(FALSE, label); Out.String("  error: "); Out.String(r.error); Out.Ln;
    RETURN
  END;
  i := 0;
  WHILE (i < r.len) & (r.data[i] # CR) & (i < LEN(hh) - 1) DO hh[i] := r.data[i]; INC(i) END;
  hh[i] := 0X; b := i + 2;
  ok := hh = h;
  IF ok & (body # "") THEN
    n := Length(body); ok := r.len - b = n; i := 0;
    WHILE ok & (i < n) DO
      ok := (r.data[b + i] = body[i]) OR (body[i] = "|") & (r.data[b + i] = LF); INC(i)
    END
  END;
  Check.Check(ok, label);
  IF ~ok THEN Out.String("  response: "); Out.String(r.data^); Out.Ln END
END Expect;

PROCEDURE (t: Test) Run*;
BEGIN
  IF t.run = 1 THEN
    Expect("/", "", "20 text/gemini", "# certs|", "outside the requires: no certificate needed");
    Expect("/", "expired-ec", "20 text/gemini", "# certs|", "  ... and an expired one not refused");
    Expect("/privateer.gmi", "", "20 text/gemini", "privateer|", "  ... /privateer.gmi, not within /private");

    Expect("/private/a.gmi", "", "60 client certificate required", "", "/private: 60 without a certificate");
    Expect("/private/none.gmi", "", "60 client certificate required", "", "  ... for a file not there too");
    Expect("/private", "", "60 client certificate required", "", "  ... and for the directory, without a 31 first");
    Expect("/private/a.gmi", "client1-ec", "20 text/gemini", "private|", "  ... a certificate: the file");
    Expect("/private/", "client2-rsa", "20 text/gemini", "# private|", "  ... another, RSA: its index");
    Expect("/private/a.gmi", "expired-ec", "62 certificate not valid", "", "  ... an expired one: 62");
    Expect("/private/none.gmi", "client1-ec", "51 not found", "", "  ... with one, a file not there: 51");

    Expect("/sneak.gmi", "", "60 client certificate required", "", "a link into /private: 60 without a certificate");
    Expect("/sneak.gmi", "client1-ec", "20 text/gemini", "private|", "  ... the file with one");
    Expect("/pubdir/a.gmi", "", "60 client certificate required", "", "a link to the directory /private: 60");
    Expect("/pubdir/", "", "60 client certificate required", "", "  ... its index too");

    Expect("/members/m.gmi", "", "60 client certificate required", "", "/members: 60 without a certificate");
    Expect("/members/m.gmi", "client1-ec", "20 text/gemini", "member|", "  ... client1-ec, listed: the file");
    Expect("/members/m.gmi", "client2-ec", "20 text/gemini", "member|", "  ... client2-ec, listed in capitals: the file");
    Expect("/members/m.gmi", "client1-rsa", "61 certificate not authorised", "", "  ... client1-rsa, not listed: 61");
    Expect("/members/m.gmi", "expired-ec", "62 certificate not valid", "", "  ... expired, and not listed: 62");
    Expect("/members/inner/x.gmi", "client1-ec", "61 certificate not authorised", "",
      "/members/inner: client1-ec, a member but not listed here: 61");
    Expect("/members/inner/x.gmi", "client2-ec", "20 text/gemini", "inner|", "  ... client2-ec, listed in both: the file");
    Expect("/members/inner/x.gmi", "", "60 client certificate required", "", "  ... none: 60")
  ELSE
    Expect("/", "", "60 client certificate required", "", "-require /, no root: 60 for its page");
    Expect("/", "client1-ec", "20 text/gemini", "", "  ... the page with a certificate")
  END
END Run;

(* Starts the server with args, for count connections, runs the test's
   requests as run, and checks it exits 0; its log in log. *)
PROCEDURE Serve(args: ARRAY OF CHAR; count, run: INTEGER; VAR log: ARRAY OF CHAR);
  VAR c: Child.Child; t: Test; cmd: Text; line: ARRAY 64 OF CHAR; i, n: LONGINT;
BEGIN
  cmd := "exec $POGEMINI_UNDER ../build/pogemini -port 0 -n "; IntToStr(count, line);
  Append(cmd, line); Append(cmd, " "); Append(cmd, args);
  log[0] := 0X;
  IF ~Child.Spawn(cmd, "", 0, c) OR ~Child.ReadLine(c, line, 15000) OR (line[0] # "p") THEN
    Check.Check(FALSE, "the server starts and says its port");
    Child.Kill(c); IF Child.Wait(c, log, n) # 0 THEN END; Out.String(line); Out.String(log); Out.Ln;
    RETURN
  END;
  i := 5; port := 0;
  WHILE (line[i] >= "0") & (line[i] <= "9") DO
    portText[i - 5] := line[i]; port := port * 10 + ORD(line[i]) - ORD("0"); INC(i)
  END;
  portText[i - 5] := 0X;
  NEW(t); t.run := run; Tasks.Start(t, StackSize); Tasks.Join(t);
  Check.Check(Child.Wait(c, log, n) = 0, "  ... the server exits 0");
  Out.String(log)
END Serve;

PROCEDURE Main;
  VAR status, i: INTEGER; config, upper: Text; log: ARRAY 65536 OF CHAR;
BEGIN
  status := Platform.System("rm -rf ../build/test-certs && mkdir -p ../build/test-certs/root/private ../build/test-certs/root/members/inner");
  IF status # 0 THEN Check.Check(FALSE, "make ../build/test-certs"); Check.Summary; RETURN END;
  IF ~CertHash("client1-ec", hash1) OR ~CertHash("client2-ec", hash2) THEN
    Check.Check(FALSE, "openssl gives the certificates' hashes"); Out.String(got); Check.Summary; RETURN
  END;
  Write("root/index.gmi", "# certs|"); Write("root/privateer.gmi", "privateer|");
  Write("root/private/index.gmi", "# private|"); Write("root/private/a.gmi", "private|");
  Write("root/members/m.gmi", "member|"); Write("root/members/inner/x.gmi", "inner|");
  status := Platform.System("cd ../build/test-certs/root && ln -s private/a.gmi sneak.gmi && ln -s private pubdir");
  Check.Check(status = 0, "the files and links made");

  (* client2-ec's hash with its hex in capitals *)
  upper := hash2; i := 7;
  WHILE upper[i] # 0X DO
    IF (upper[i] >= "a") & (upper[i] <= "f") THEN upper[i] := CHR(ORD(upper[i]) - 32) END; INC(i)
  END;
  config := "capsule localhost|  root ../build/test-certs/root|  cert ../build/certs/self-ec.crt|  key ../build/certs/self-ec.key|  require /private/|  require /members|    identity ";
  Append(config, hash1); Append(config, "|    identity "); Append(config, upper);
  Append(config, "|  require /members/inner|    identity "); Append(config, hash2); Append(config, "|");
  Write("pogemini.conf", config);

  Serve("-config ../build/test-certs/pogemini.conf", Ours, 1, log);
  Check.Check(Check.Contains(log, "/private/a.gmi -") & Check.Contains(log, hash1)
    & Check.Contains(log, hash2), "the log: each certificate's hash, or - for none");

  Serve("-host localhost -require / -cert ../build/certs/self-ec.crt -key ../build/certs/self-ec.key", 2, 2, log);

  IF Platform.System("rm -rf ../build/test-certs") # 0 THEN END;
  Check.Summary
END Main;

BEGIN
  Main
END TestCerts.
