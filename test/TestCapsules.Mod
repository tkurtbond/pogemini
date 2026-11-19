MODULE TestCapsules; (* Capsules from a configuration file, and made certificates *)

(* Starts build/pogemini with a configuration file of three capsules:
   localhost (alias ::1) and other.example (alias www.other.example)
   with the tests' certificates, and gen.example with none, so the
   server makes one in a certificate directory of the test's own. Each
   request must be answered by the capsule its host names, and the
   handshake must present the certificate SNI asks for: localhost's to
   a client that sends none, being first. A host no capsule has is
   refused, 53.

   Run again, the server must present the certificate it made the first
   time, not a new one, and the key must be readable by its owner only.
   A capsule for any host given on the command line comes first, and
   answers every host the file's capsules don't have.

   Last, what must stop the server, with exit status 1 and a reason on
   standard error: a mistake in the file, a certificate with no key
   beside it, a root that isn't a directory, a certificate directory
   that can't be made; and with no capsule at all, the usage, status 2.
   The certificate is made without openssl on PATH, through TlsMake,
   before the root is checked, in a certificate directory made with its
   parents; and a key found alone is given a certificate, not replaced.
   The file and certificates are in ../build/test-capsules, made
   afresh. *)

IMPORT Out, Files, Platform, Tasks, Check, Child, GemClient;

CONST
  Dir = "../build/test-capsules";
  Certs = "../build/certs/";
  StackSize = 1024 * 1024;  (* see TestServe *)
  CR = 0DX; LF = 0AX;

TYPE
  Text = ARRAY 2048 OF CHAR;
  Hash = ARRAY 80 OF CHAR;
  Test = POINTER TO RECORD (Tasks.TaskDesc) run: INTEGER END;

VAR
  port: INTEGER; portText: ARRAY 8 OF CHAR;
  got: ARRAY 65536 OF CHAR; gotLen: LONGINT;
  selfEc, otherRsa, selfRsa, gen: Hash;  (* certificates' hashes *)

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

(* Runs command to its end, with no input: its exit status, and its
   output, standard error included, in got. *)
PROCEDURE Run(command: ARRAY OF CHAR): INTEGER;
  VAR c: Child.Child;
BEGIN
  gotLen := 0; got[0] := 0X;
  IF ~Child.Spawn(command, "", 0, c) THEN RETURN -1 END;
  RETURN Child.Wait(c, got, gotLen)
END Run;

(* The hash of the certificate in file, as libtls gives a peer's:
   "SHA256:" and lowercase hex, or "" if it can't be had. openssl dgst
   ends its line with "= <hex>", in OpenSSL and LibreSSL alike. *)
PROCEDURE CertHash(file: ARRAY OF CHAR; VAR h: Hash);
  VAR cmd: Text; i, j: LONGINT;
BEGIN
  cmd := "openssl x509 -in '"; Append(cmd, file);
  Append(cmd, "' -outform DER | openssl dgst -sha256");
  h := "";
  IF Run(cmd) = 0 THEN
    i := gotLen; WHILE (i > 0) & (got[i - 1] # " ") DO DEC(i) END;
    h := "SHA256:"; j := 7;
    WHILE (i < gotLen) & (got[i] # LF) & (j < LEN(h) - 1) DO h[j] := got[i]; INC(i); INC(j) END;
    h[j] := 0X
  END
END CertHash;

PROCEDURE StartsWith(s, prefix: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (prefix[i] # 0X) & (i < LEN(s)) & (s[i] = prefix[i]) DO INC(i) END;
  RETURN prefix[i] = 0X
END StartsWith;

(* Fetches url from 127.0.0.1 with SNI servername ("" for none, by
   connecting to an address): the page must name capsule (or be a 53 if
   capsule is ""), and the certificate presented must be hash, unless
   hash is "". *)
PROCEDURE Expect(servername, url, capsule: ARRAY OF CHAR; hash: Hash; label: ARRAY OF CHAR);
  VAR req, page: Text; r: GemClient.Response; len: LONGINT; ok: BOOLEAN;
BEGIN
  IF servername = "" THEN GemClient.servername := "127.0.0.1"
  ELSE COPY(servername, GemClient.servername)
  END;
  COPY(url, req); len := Length(req); req[len] := CR; req[len + 1] := LF; INC(len, 2);
  r := GemClient.Fetch("127.0.0.1", port, req, len, "", "");
  IF capsule = "" THEN page := "53 not served here"; page[18] := CR; page[19] := 0X
  ELSIF capsule = "*" THEN page := "This capsule serves any host."
  ELSE page := "This capsule is "; Append(page, capsule); Append(page, ".")
  END;
  ok := r.ok & Check.Contains(r.data^, page) & ((hash = "") OR (r.serverHash = hash));
  Check.Check(ok, label);
  IF ~ok THEN
    Out.String("  error: "); Out.String(r.error); Out.String(", certificate "); Out.String(r.serverHash);
    Out.String(", response: "); Out.String(r.data^); Out.Ln
  END
END Expect;

(* gemini://host:port/ *)
PROCEDURE Url(host: ARRAY OF CHAR; VAR url: ARRAY OF CHAR);
BEGIN
  COPY("gemini://", url); Append(url, host); Append(url, ":"); Append(url, portText);
  Append(url, "/")
END Url;

PROCEDURE (t: Test) Run*;
  VAR u: Text; none: Hash;
BEGIN
  none := "";
  IF t.run = 1 THEN
    Url("localhost", u); Expect("localhost", u, "localhost", selfEc, "localhost, by SNI: its page and certificate");
    Url("[::1]", u); Expect("", u, "localhost", selfEc, "::1, its alias, without SNI: the first capsule's certificate");
    Url("other.example", u);
    Expect("other.example", u, "other.example", otherRsa, "other.example, by SNI: its page and certificate");
    Url("www.other.example", u);
    Expect("www.other.example", u, "other.example", none, "www.other.example, its alias: its page");
    Url("gen.example", u);
    Expect("gen.example", u, "gen.example", gen, "gen.example: its page and the certificate made for it");
    Url("Gen.Example.", u);
    Expect("gen.example", u, "gen.example", none, "  ... its name in capitals, with a final dot");
    Url("nowhere.example", u); Expect("nowhere.example", u, "", none, "a host no capsule has: 53")
  ELSIF t.run = 2 THEN
    Url("gen.example", u);
    Expect("gen.example", u, "gen.example", gen, "run again: the same certificate for gen.example")
  ELSE
    Url("nowhere.example", u);
    Expect("nowhere.example", u, "*", selfRsa, "-cert alone: a capsule for any host, its certificate shown first");
    Url("other.example", u);
    Expect("other.example", u, "other.example", otherRsa, "  ... and the file's capsules still served")
  END
END Run;

(* Starts the server with args, for count connections, runs the test's
   requests as run, and checks it exits 0. *)
PROCEDURE Serve(args: ARRAY OF CHAR; count, run: INTEGER);
  VAR c: Child.Child; t: Test; cmd: Text; line: ARRAY 64 OF CHAR; log: ARRAY 65536 OF CHAR;
    i, n: LONGINT;
BEGIN
  cmd := "exec $POGEMINI_UNDER ../build/pogemini -port 0 -n "; line[0] := CHR(ORD("0") + count); line[1] := 0X;
  Append(cmd, line); Append(cmd, " "); Append(cmd, args);
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
  (* the server made gen.example's certificate before it listened *)
  IF gen = "" THEN
    CertHash("../build/test-capsules/certs/gen.example.crt", gen);
    Check.Check(gen # "", "a certificate made for gen.example")
  END;
  NEW(t); t.run := run; Tasks.Start(t, StackSize); Tasks.Join(t);
  Check.Check(Child.Wait(c, log, n) = 0, "  ... the server exits 0");
  Out.String(log)
END Serve;

(* Runs the server with args, its environment changed by env (as
   "NAME=value ", or ""): it must exit with status, saying why. *)
PROCEDURE RefusedWith(label, env, args: ARRAY OF CHAR; status: INTEGER; why: ARRAY OF CHAR);
  VAR cmd: Text; s: INTEGER; ok: BOOLEAN;
BEGIN
  cmd := "exec "; Append(cmd, env); Append(cmd, "$POGEMINI_UNDER ../build/pogemini -port 0 -n 1 "); Append(cmd, args);
  s := Run(cmd);
  ok := (s = status) & Check.Contains(got, why);
  Check.Check(ok, label);
  IF ~ok THEN Out.String("  exit "); Out.Int(s, 0); Out.String(": "); Out.String(got); Out.Ln END
END RefusedWith;

(* Runs the server with args: it must exit with status, saying why. *)
PROCEDURE Refused(label, args: ARRAY OF CHAR; status: INTEGER; why: ARRAY OF CHAR);
BEGIN RefusedWith(label, "", args, status, why)
END Refused;

(* Writes text to the file called name, each "|" a line feed. *)
PROCEDURE Write(name, text: ARRAY OF CHAR);
  VAR f: Files.File; r: Files.Rider; i: LONGINT;
BEGIN
  f := Files.New(name); Files.Set(r, f, 0); i := 0;
  WHILE text[i] # 0X DO
    IF text[i] = "|" THEN Files.Write(r, LF) ELSE Files.Write(r, text[i]) END;
    INC(i)
  END;
  Files.Register(f)
END Write;

PROCEDURE Main;
  VAR args: Text;
BEGIN
  IF Platform.System("rm -rf ../build/test-capsules && mkdir -p ../build/test-capsules/root") # 0 THEN
    Check.Check(FALSE, "make ../build/test-capsules"); Check.Summary; RETURN
  END;
  Write("../build/test-capsules/root/index.gmi", "# localhost|This capsule is localhost.|");
  CertHash("../build/certs/self-ec.crt", selfEc);
  CertHash("../build/certs/self-rsa.crt", selfRsa);
  CertHash("../build/certs/other-rsa.crt", otherRsa);
  Check.Check((selfEc # "") & (otherRsa # "") & (selfRsa # ""), "the test certificates' hashes");

  Write("../build/test-capsules/pogemini.conf",
    "# three capsules|port 1965|deadline 5000|certdir ../build/test-capsules/certs||capsule localhost|  alias ::1|  root ../build/test-capsules/root|  cert ../build/certs/self-ec.crt|  key ../build/certs/self-ec.key|capsule other.example|  alias www.other.example|  cert ../build/certs/other-rsa.crt|  key ../build/certs/other-rsa.key|capsule gen.example|");
  args := "-config ../build/test-capsules/pogemini.conf";

  gen := "";
  Serve(args, 7, 1);
  Check.Check(Run("ls -l ../build/test-capsules/certs/gen.example.key") = 0, "  ... gen.example's key kept");
  Check.Check(StartsWith(got, "-rw------- ") OR StartsWith(got, "-rw-------."),
    "  ... readable by its owner only");
  Check.Check((Run("ls -ld ../build/test-capsules/certs") = 0) & StartsWith(got, "drwx------"),
    "  ... in a directory made its owner's only");
  Check.Check(Run("openssl x509 -in ../build/test-capsules/certs/gen.example.crt -noout -text") = 0,
    "  ... beside a certificate openssl reads");
  Check.Check(Check.Contains(got, "DNS:gen.example") & Check.Contains(got, "ecdsa-with-SHA256"),
    "  ... for gen.example, ECDSA with SHA-256");
  (* 3650 days: still valid in 3645, and no longer in 3652 *)
  Check.Check((Run("openssl x509 -in ../build/test-capsules/certs/gen.example.crt -noout -checkend 314928000") = 0)
    & (Run("openssl x509 -in ../build/test-capsules/certs/gen.example.crt -noout -checkend 315532800") # 0),
    "  ... valid for 3650 days");
  Serve(args, 1, 2);
  args := "-config ../build/test-capsules/pogemini.conf -cert ../build/certs/self-rsa.crt -key ../build/certs/self-rsa.key";
  Serve(args, 2, 3);

  Write("../build/test-capsules/bad.conf", "capsule a.example||port 1");
  Refused("a mistake in the file", "-config ../build/test-capsules/bad.conf", 1,
    "pogemini: ../build/test-capsules/bad.conf:3: port inside a capsule: global settings come first");
  Refused("a file that isn't there", "-config ../build/test-capsules/none.conf", 1,
    "pogemini: ../build/test-capsules/none.conf: can't be read");
  IF Platform.System("mkdir -p ../build/test-capsules/lone && cp ../build/certs/self-ec.crt ../build/test-capsules/lone/a.example.crt") # 0 THEN END;
  Refused("a certificate with no key beside it", "-host a.example -certdir ../build/test-capsules/lone", 1,
    "pogemini: a.example: ../build/test-capsules/lone/a.example.crt has no key beside it");
  Refused("a root that isn't a directory",
    "-host localhost -root ../build/test-capsules/pogemini.conf -cert ../build/certs/self-ec.crt -key ../build/certs/self-ec.key", 1,
    "pogemini: localhost: ../build/test-capsules/pogemini.conf is not a directory");
  Refused("a certificate without its key", "-host localhost -cert ../build/certs/self-ec.crt", 1,
    "pogemini: localhost: a certificate needs its key, and a key its certificate");
  RefusedWith("a certificate made with no openssl on PATH, then the root refused", "env PATH=/nonexistent ",
    "-host b.example -certdir ../build/test-capsules/certs2/deeper -root ../build/test-capsules/pogemini.conf", 1,
    "pogemini: b.example: ../build/test-capsules/pogemini.conf is not a directory");
  Check.Check(Run("openssl x509 -in ../build/test-capsules/certs2/deeper/b.example.crt -noout -text") = 0,
    "  ... the certificate made, in a directory made with its parent");
  Check.Check(Check.Contains(got, "DNS:b.example"), "  ... for b.example");
  Check.Check((Run("ls -ld ../build/test-capsules/certs2/deeper") = 0) & StartsWith(got, "drwx------"),
    "  ... the directory its owner's only");
  Refused("a certificate directory that can't be made",
    "-host c.example -certdir ../build/test-capsules/pogemini.conf/certs", 1,
    "pogemini: c.example: can't make the certificate directory ../build/test-capsules/pogemini.conf/certs");
  IF Platform.System("mkdir -p ../build/test-capsules/certs3 && chmod 755 ../build/test-capsules/certs3 && cp ../build/certs/self-ec.key ../build/test-capsules/certs3/d.example.key") # 0 THEN END;
  Refused("a key alone: given a certificate, then the root refused",
    "-host d.example -certdir ../build/test-capsules/certs3 -root ../build/test-capsules/pogemini.conf", 1,
    "pogemini: d.example: ../build/test-capsules/pogemini.conf is not a directory");
  Check.Check(Run("cd ../build/test-capsules/certs3 && openssl x509 -in d.example.crt -noout -pubkey > c.pub && openssl pkey -in ../../certs/self-ec.key -pubout > k.pub && cmp c.pub k.pub && cmp d.example.key ../../certs/self-ec.key") = 0,
    "  ... the certificate is for that key, and the key is unchanged");
  Check.Check((Run("ls -ld ../build/test-capsules/certs3") = 0) & StartsWith(got, "drwxr-xr-x"),
    "  ... and the directory that was there keeps its mode");
  Refused("no capsule", "", 2, "usage: pogemini");
  Refused("the key pair of another", "-host localhost -cert ../build/certs/self-ec.crt -key ../build/certs/self-rsa.key", 1,
    "pogemini: certificate: ");

  IF Platform.System("rm -rf ../build/test-capsules") # 0 THEN END;
  Check.Summary
END Main;

BEGIN
  Main
END TestCapsules.
