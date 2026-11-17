MODULE TestFiles; (* A capsule's files, served *)

(* Starts build/pogemini serving localhost from a root of the test's own
   in ../build/test-files, made afresh, and given by a symbolic link to
   it, so the server must resolve the root before it compares a file's
   path with it. Then, by GemClient:

   - files, each with its MIME type by extension, in capitals or not,
     one whose name has a space or is not ASCII (percent-encoded in the
     request), and a large one, sent in pieces, which must arrive whole;
   - a directory: with a final "/", its index.gmi; without, 31 to the
     path as sent with "/" added, the query kept; with no index.gmi, 51;
   - a symbolic link inside the root, to a file or a directory: followed;
   - 51 for: a name that isn't there, a file asked for as a directory, a
     hidden name (".git/config", ".hidden"), a link out of the root
     (to a file or a directory), a link to a hidden name, a FIFO
     (which must not stop the server), and a file it can't read (not
     checked as root, who can read anything).

   Then openssl s_client, if it is on PATH ($OPENSSL), must get the
   large file whole too. And a capsule with no root answers "/" with
   its page, and anything else 51. Each time, the server must exit 0. *)

IMPORT Out, Files, Platform, Tasks, Check, Child, GemClient;

CONST
  Dir = "../build/test-files";
  StackSize = 1024 * 1024;  (* see TestServe *)
  CR = 0DX; LF = 0AX;
  BigLen = 1048576 + 1234;  (* not a multiple of a piece *)
  Ours = 31;   (* the connections Test makes, besides locked.gmi *)

TYPE
  Text = ARRAY 2048 OF CHAR;
  Test = POINTER TO RECORD (Tasks.TaskDesc) run: INTEGER END;

VAR
  port: INTEGER; portText: ARRAY 8 OF CHAR;
  got: ARRAY 65536 OF CHAR; gotLen: LONGINT;
  root: BOOLEAN;  (* running as root, so every file is readable *)
  openssl: Text;  (* $OPENSSL or openssl, "" if not on PATH *)

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

(* The large file's byte at i: every value, 0X included, in no simple
   repetition of a piece. *)
PROCEDURE BigByte(i: LONGINT): CHAR;
BEGIN RETURN CHR((i * 7 + i DIV 251) MOD 256)
END BigByte;

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

PROCEDURE WriteBig(name: ARRAY OF CHAR);
  VAR f: Files.File; r: Files.Rider; i: LONGINT; path: Text;
BEGIN
  path := Dir; Append(path, "/"); Append(path, name);
  f := Files.New(path); Files.Set(r, f, 0);
  FOR i := 0 TO BigLen - 1 DO Files.Write(r, BigByte(i)) END;
  Files.Register(f)
END WriteBig;

(* Fetches gemini://localhost:port path: the response, or NIL with a
   failed check if it didn't end with close_notify. *)
PROCEDURE Fetch(path: ARRAY OF CHAR; label: ARRAY OF CHAR): GemClient.Response;
  VAR req: Text; r: GemClient.Response; len: LONGINT;
BEGIN
  req := "gemini://localhost:"; Append(req, portText); Append(req, path);
  len := Length(req); req[len] := CR; req[len + 1] := LF; INC(len, 2);
  r := GemClient.Fetch("127.0.0.1", port, req, len, "", "");
  IF ~r.ok THEN
    Check.Check(FALSE, label); Out.String("  error: "); Out.String(r.error); Out.Ln;
    RETURN NIL
  END;
  RETURN r
END Fetch;

(* The header of r, without CR LF, in h; the body begins at body. *)
PROCEDURE Header(r: GemClient.Response; VAR h: ARRAY OF CHAR; VAR body: LONGINT);
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i < r.len) & (r.data[i] # CR) & (i < LEN(h) - 1) DO h[i] := r.data[i]; INC(i) END;
  h[i] := 0X;
  body := i + 2
END Header;

(* path must be answered with header h, and, if body isn't "", that
   body exactly, each "|" in it a line feed. *)
PROCEDURE Expect(path, h, body, label: ARRAY OF CHAR);
  VAR r: GemClient.Response; hh: Text; b, i, n: LONGINT; ok: BOOLEAN;
BEGIN
  r := Fetch(path, label);
  IF r # NIL THEN
    Header(r, hh, b);
    ok := hh = h;
    IF ok & (body # "") THEN
      n := Length(body); ok := r.len - b = n; i := 0;
      WHILE ok & (i < n) DO
        ok := (r.data[b + i] = body[i]) OR (body[i] = "|") & (r.data[b + i] = LF); INC(i)
      END
    END;
    Check.Check(ok, label);
    IF ~ok THEN Out.String("  response: "); Out.String(r.data^); Out.Ln END
  END
END Expect;

(* The large file must come whole. *)
PROCEDURE ExpectBig(path, label: ARRAY OF CHAR);
  VAR r: GemClient.Response; h: Text; b, i: LONGINT; ok: BOOLEAN;
BEGIN
  r := Fetch(path, label);
  IF r # NIL THEN
    Header(r, h, b);
    ok := (h = "20 application/octet-stream") & (r.len - b = BigLen); i := 0;
    WHILE ok & (i < BigLen) DO ok := r.data[b + i] = BigByte(i); INC(i) END;
    Check.Check(ok, label);
    IF ~ok THEN Out.String("  header: "); Out.String(h); Out.String(", length ");
      Out.Int(r.len - b, 0); Out.Ln
    END
  END
END ExpectBig;

PROCEDURE (t: Test) Run*;
BEGIN
  IF t.run = 1 THEN
    Expect("/", "20 text/gemini", "# files|=> sub/|", "/: its index.gmi");
    Expect("", "20 text/gemini", "# files|=> sub/|", "  ... and an empty path, without a redirect");
    Expect("/a.gmi", "20 text/gemini", "", "a .gmi file: text/gemini");
    Expect("/b.gemini", "20 text/gemini", "", "a .gemini file: text/gemini");
    Expect("/C.GMI", "20 text/gemini", "", "  ... in capitals");
    Expect("/sub/a.txt", "20 text/plain", "plain|", "a .txt file in a directory: text/plain, its text");
    Expect("/t.text", "20 text/plain", "text|", "a .text file: text/plain");
    Expect("/p.png", "20 image/png", "", "a .png file: image/png");
    Expect("/s.html", "20 text/html", "", "a .html file: text/html");
    Expect("/noext", "20 application/octet-stream", "", "no extension: application/octet-stream");
    Expect("/x.frob", "20 application/octet-stream", "", "an unknown extension: application/octet-stream");
    Expect("/a%20b.gmi", "20 text/gemini", "space|", "a name with a space, %20 in the request");
    Expect("/%C3%A9t%C3%A9.gmi", "20 text/gemini", "summer|", "a name not ASCII, percent-encoded");
    ExpectBig("/big.bin", "a large file, in pieces: whole");

    Expect("/docs/", "20 text/gemini", "# docs|", "a directory with /: its index.gmi");
    Expect("/docs", "31 /docs/", "", "  ... without: 31, the / added");
    Expect("/docs?q=1", "31 /docs/?q=1", "", "  ... with a query: kept");
    Expect("/d%6Fcs", "31 /d%6Fcs/", "", "  ... the path as sent");
    Expect("/sub/", "51 not found", "", "a directory without index.gmi: 51");
    Expect("/sub/a.txt/", "51 not found", "", "a file asked for as a directory: 51");
    Expect("/none.gmi", "51 not found", "", "a name that isn't there: 51");

    Expect("/link.gmi", "20 text/gemini", "", "a link to a file inside the root: followed");
    Expect("/linkdir/", "20 text/gemini", "# docs|", "a link to a directory inside: followed");
    Expect("/.hidden", "51 not found", "", "a hidden file: 51");
    Expect("/.git/config", "51 not found", "", "a file in a hidden directory: 51");
    Expect("/%2Egit/config", "51 not found", "", "  ... its . percent-encoded: 51");
    Expect("/cfg.txt", "51 not found", "", "a link to a hidden file: 51");
    Expect("/out.txt", "51 not found", "", "a link to a file outside the root: 51");
    Expect("/outdir/secret.txt", "51 not found", "", "a file through a link to a directory outside: 51");
    Expect("/passwd", "51 not found", "", "a link to /etc/passwd: 51");
    Expect("/fifo", "51 not found", "", "a FIFO: 51, and the server not stopped");
    IF root THEN Out.String("skip - a file it can't read: running as root"); Out.Ln
    ELSE Expect("/locked.gmi", "51 not found", "", "a file it can't read: 51")
    END
  ELSE
    Expect("/", "20 text/gemini", "", "no root: / gets the capsule's page");
    Expect("/a.gmi", "51 not found", "", "  ... and anything else 51")
  END
END Run;

(* openssl s_client fetching the large file. The shell reads the header
   a byte at a time, so cmp sees the body alone. *)
PROCEDURE Others;
  VAR cmd: Text; ok: BOOLEAN;
BEGIN
  cmd := "printf 'gemini://localhost:"; Append(cmd, portText);
  Append(cmd, "/big.bin\r\n' | '"); Append(cmd, openssl);
  Append(cmd, "' s_client -quiet -servername localhost -connect 127.0.0.1:"); Append(cmd, portText);
  Append(cmd, " 2>/dev/null | { IFS= read -r h; echo $h; cmp - ");
  Append(cmd, Dir); Append(cmd, "/root/big.bin && echo same; }");
  ok := (Run(cmd) = 0) & Check.Contains(got, "20 application/octet-stream") & Check.Contains(got, "same");
  Check.Check(ok, "openssl s_client: the large file whole");
  IF ~ok THEN Out.String("  output: "); Out.String(got); Out.Ln END
END Others;

(* Starts the server with args, for count connections, runs the test's
   requests as run, and checks it exits 0 with a log line for each. *)
PROCEDURE Serve(args: ARRAY OF CHAR; count, run: INTEGER);
  VAR c: Child.Child; t: Test; cmd: Text; line: ARRAY 64 OF CHAR; log: ARRAY 65536 OF CHAR;
    i, n: LONGINT;
BEGIN
  cmd := "exec ../build/pogemini -port 0 -n "; IntToStr(count, line);
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
  NEW(t); t.run := run; Tasks.Start(t, StackSize); Tasks.Join(t);
  IF (run = 1) & (openssl # "") THEN Others END;
  Check.Check(Child.Wait(c, log, n) = 0, "  ... the server exits 0");
  Out.String(log)
END Serve;

PROCEDURE Main;
  VAR status, n: INTEGER; cmd: Text;
BEGIN
  status := Platform.System("rm -rf ../build/test-files && mkdir -p ../build/test-files/root/sub ../build/test-files/root/docs ../build/test-files/root/.git ../build/test-files/outside");
  IF status # 0 THEN Check.Check(FALSE, "make ../build/test-files"); Check.Summary; RETURN END;
  Write("root/index.gmi", "# files|=> sub/|");
  Write("root/a.gmi", "a|"); Write("root/b.gemini", "b|"); Write("root/C.GMI", "c|");
  Write("root/sub/a.txt", "plain|"); Write("root/t.text", "text|"); Write("root/p.png", "png"); Write("root/s.html", "<p>");
  Write("root/noext", "?"); Write("root/x.frob", "?");
  Write("root/a b.gmi", "space|"); Write("root/été.gmi", "summer|");
  WriteBig("root/big.bin");
  Write("root/docs/index.gmi", "# docs|");
  Write("root/.hidden", "hidden|"); Write("root/.git/config", "secret|");
  Write("outside/out.txt", "outside|"); Write("outside/secret.txt", "outside|");
  Write("root/locked.gmi", "locked|");
  status := Platform.System("cd ../build/test-files && ln -s root rootlink && cd root && ln -s a.gmi link.gmi && ln -s docs linkdir && ln -s .git/config cfg.txt && ln -s ../outside/out.txt out.txt && ln -s ../outside outdir && ln -s /etc/passwd passwd && mkfifo fifo && chmod 000 locked.gmi");
  Check.Check(status = 0, "the files, links and FIFO made");
  root := Run("test `id -u` = 0") = 0;
  IF ~Platform.getEnv("OPENSSL", openssl) OR (openssl = "") THEN openssl := "openssl" END;
  cmd := "command -v '"; Append(cmd, openssl); Append(cmd, "' >/dev/null");
  IF Run(cmd) # 0 THEN
    Out.String("skip - openssl s_client: not found ($OPENSSL or openssl)"); Out.Ln; openssl := ""
  END;
  n := Ours; IF ~root THEN INC(n) END; IF openssl # "" THEN INC(n) END;

  Serve("-host localhost -root ../build/test-files/rootlink -cert ../build/certs/self-ec.crt -key ../build/certs/self-ec.key",
    n, 1);
  Serve("-host localhost -cert ../build/certs/self-ec.crt -key ../build/certs/self-ec.key", 2, 2);

  IF Platform.System("chmod 644 ../build/test-files/root/locked.gmi && rm -rf ../build/test-files") # 0 THEN END;
  Check.Summary
END Main;

BEGIN
  Main
END TestFiles.
