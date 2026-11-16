MODULE GemConfig; (* The configuration: a file of our own, and capsules *)

(* What the server is told to do, from a file and the command line
   (pogemini merges the two). The file is a line per setting, a keyword
   and its value; "#" begins a comment, and blank lines are ignored:

     # global settings, before the first capsule
     listen ::1              the address to listen on (default: every one)
     port 1965               the port
     deadline 10000          ms a connection has for the whole exchange
     certdir /var/lib/pogemini/certs   where made certificates are kept

     capsule example.org     a capsule, by its host name; what follows
       alias www.example.org   is its own, up to the next capsule:
       root /srv/gemini/example.org    another name, its documents,
       cert /etc/pogemini/example.org.crt   and its certificate and key
       key /etc/pogemini/example.org.key    (made if neither is given)

   A value is the rest of the line with its spaces trimmed, so a file
   name may contain spaces; a name or number must be one word. A host
   name is kept in lower case, as GemRequest gives a request's host, and
   must be a DNS name or an IP address, written plainly (::1, not [::1])
   in ASCII: it names files and goes to openssl's command line
   (GemCert), so nothing else is let through. *)

IMPORT Files, Strings;

CONST
  MaxCapsules* = 64;
  MaxAliases* = 16;
  NameLen* = 256;
  PathLen* = 1024;
  ErrorLen* = 1400;
  DefaultPort* = 1965;
  DefaultDeadline* = 10000;
  LineLen = 1100;

TYPE
  Name* = ARRAY NameLen OF CHAR;
  Path* = ARRAY PathLen OF CHAR;

  Capsule* = POINTER TO CapsuleDesc;
  CapsuleDesc* = RECORD
    name*: Name;              (* "" for one that serves any host *)
    aliases*: ARRAY MaxAliases OF Name;
    nAliases*: INTEGER;
    root*, cert*, key*: Path  (* "" when not given *)
  END;

  Config* = POINTER TO ConfigDesc;
  ConfigDesc* = RECORD
    listen*: Name;            (* "" for every address *)
    port*: LONGINT;           (* -1 when not given *)
    deadline*: LONGINT;       (* -1 when not given *)
    certdir*: Path;           (* "" when not given *)
    capsules*: ARRAY MaxCapsules OF Capsule;
    n*: INTEGER
  END;

PROCEDURE New*(): Config;
  VAR c: Config;
BEGIN
  NEW(c); c.listen := ""; c.port := -1; c.deadline := -1; c.certdir := ""; c.n := 0;
  RETURN c
END New;

PROCEDURE IsDigit(ch: CHAR): BOOLEAN;
BEGIN RETURN (ch >= "0") & (ch <= "9")
END IsDigit;

(* s in lower case. *)
PROCEDURE Lower*(VAR s: ARRAY OF CHAR);
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    IF (s[i] >= "A") & (s[i] <= "Z") THEN s[i] := CHR(ORD(s[i]) + 32) END;
    INC(i)
  END
END Lower;

(* s is an IP address: IPv4's digits and dots, or IPv6's, which has a
   colon. Only the characters are checked; a capsule for a malformed
   address simply never matches. *)
PROCEDURE IsAddress*(s: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT; colon, other: BOOLEAN; ch: CHAR;
BEGIN
  i := 0; colon := FALSE; other := FALSE;
  WHILE s[i] # 0X DO
    ch := s[i];
    IF ch = ":" THEN colon := TRUE
    ELSIF IsDigit(ch) OR (ch = ".") THEN
    ELSIF (ch >= "a") & (ch <= "f") THEN other := TRUE
    ELSE RETURN FALSE
    END;
    INC(i)
  END;
  RETURN (i > 0) & (colon OR ~other)
END IsAddress;

(* s, in lower case, is a host name a capsule may have: an IP address,
   or a DNS name of labels of letters, digits and hyphens, a hyphen
   neither first nor last in its label, with no final dot. *)
PROCEDURE ValidName*(s: ARRAY OF CHAR): BOOLEAN;
  VAR i, len: LONGINT; ch: CHAR;
BEGIN
  IF (s = "") OR (Strings.Length(s) > 253) THEN RETURN FALSE END;
  IF IsAddress(s) & (Strings.Pos(":", s, 0) >= 0) THEN RETURN TRUE END;
  i := 0; len := 0;
  LOOP
    ch := s[i];
    IF (ch = ".") OR (ch = 0X) THEN
      IF (len = 0) OR (len > 63) OR (s[i - 1] = "-") THEN RETURN FALSE END;
      IF ch = 0X THEN RETURN TRUE END;
      len := 0
    ELSIF (ch >= "a") & (ch <= "z") OR IsDigit(ch) OR (ch = "-") & (len > 0) THEN INC(len)
    ELSE RETURN FALSE
    END;
    INC(i)
  END
END ValidName;

(* The capsule c names, by its name or an alias, or NIL. *)
PROCEDURE (c: Config) Find*(host: ARRAY OF CHAR): Capsule;
  VAR i, j: INTEGER; k: Capsule;
BEGIN
  FOR i := 0 TO c.n - 1 DO
    k := c.capsules[i];
    IF k.name = host THEN RETURN k END;
    FOR j := 0 TO k.nAliases - 1 DO
      IF k.aliases[j] = host THEN RETURN k END
    END
  END;
  RETURN NIL
END Find;

(* A new capsule called name ("" for any host), added to c last, or
   first if first. FALSE, with why, if c is full or the name is taken or
   not a valid one. *)
PROCEDURE (c: Config) Add*(name: ARRAY OF CHAR; first: BOOLEAN;
    VAR k: Capsule; VAR why: ARRAY OF CHAR): BOOLEAN;
  VAR i: INTEGER; n: Name;
BEGIN
  COPY(name, n); Lower(n);
  IF c.n = MaxCapsules THEN COPY("too many capsules", why); RETURN FALSE END;
  IF (n # "") & ~ValidName(n) THEN COPY("not a host name: ", why); Strings.Append(name, why); RETURN FALSE END;
  IF c.Find(n) # NIL THEN COPY("a second capsule for ", why); Strings.Append(n, why); RETURN FALSE END;
  NEW(k); k.name := n; k.nAliases := 0; k.root := ""; k.cert := ""; k.key := "";
  IF first THEN
    FOR i := c.n TO 1 BY -1 DO c.capsules[i] := c.capsules[i - 1] END;
    c.capsules[0] := k
  ELSE c.capsules[c.n] := k
  END;
  INC(c.n);
  RETURN TRUE
END Add;

(* Adds alias to k, a capsule of c. *)
PROCEDURE (c: Config) AddAlias*(k: Capsule; alias: ARRAY OF CHAR;
    VAR why: ARRAY OF CHAR): BOOLEAN;
  VAR n: Name;
BEGIN
  COPY(alias, n); Lower(n);
  IF k.name = "" THEN COPY("a capsule for any host has no aliases", why); RETURN FALSE END;
  IF k.nAliases = MaxAliases THEN COPY("too many aliases", why); RETURN FALSE END;
  IF ~ValidName(n) THEN COPY("not a host name: ", why); Strings.Append(alias, why); RETURN FALSE END;
  IF c.Find(n) # NIL THEN COPY("a second capsule for ", why); Strings.Append(n, why); RETURN FALSE END;
  k.aliases[k.nAliases] := n; INC(k.nAliases);
  RETURN TRUE
END AddAlias;

(* s as a number from lo to hi, or FALSE. *)
PROCEDURE Number*(s: ARRAY OF CHAR; lo, hi: LONGINT; VAR x: LONGINT): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  x := 0; i := 0;
  IF s[0] = 0X THEN RETURN FALSE END;
  WHILE s[i] # 0X DO
    IF ~IsDigit(s[i]) OR (x > hi) THEN RETURN FALSE END;
    x := x * 10 + ORD(s[i]) - ORD("0"); INC(i)
  END;
  RETURN (x >= lo) & (x <= hi)
END Number;

PROCEDURE IsSpace(ch: CHAR): BOOLEAN;
BEGIN RETURN (ch = " ") OR (ch = 09X) OR (ch = 0DX)
END IsSpace;

(* Splits line into its keyword and the rest, trimmed; a "#" outside a
   value begins a comment only at the start of a word. *)
PROCEDURE Split(line: ARRAY OF CHAR; VAR key, value: ARRAY OF CHAR);
  VAR i, j, end: LONGINT;
BEGIN
  i := 0; WHILE IsSpace(line[i]) DO INC(i) END;
  j := 0;
  WHILE (line[i] # 0X) & ~IsSpace(line[i]) & (j < LEN(key) - 1) DO key[j] := line[i]; INC(i); INC(j) END;
  key[j] := 0X;
  IF key[0] = "#" THEN key[0] := 0X; value[0] := 0X; RETURN END;
  WHILE IsSpace(line[i]) DO INC(i) END;
  j := 0; end := 0;
  WHILE (line[i] # 0X) & ~((line[i] = "#") & IsSpace(line[i - 1])) & (j < LEN(value) - 1) DO
    value[j] := line[i];
    IF ~IsSpace(line[i]) THEN end := j + 1 END;
    INC(i); INC(j)
  END;
  value[end] := 0X
END Split;

PROCEDURE OneWord(s: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0; WHILE (s[i] # 0X) & ~IsSpace(s[i]) DO INC(i) END;
  RETURN s[i] = 0X
END OneWord;

(* n in decimal, n >= 0. *)
PROCEDURE IntToStr(n: LONGINT; VAR s: ARRAY OF CHAR);
  VAR d: ARRAY 24 OF CHAR; i, j: INTEGER;
BEGIN
  i := 0; REPEAT d[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i) UNTIL n = 0;
  j := 0; WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END;
  s[j] := 0X
END IntToStr;

(* Sets error to "file:line: message". *)
PROCEDURE Error(file: ARRAY OF CHAR; line: LONGINT; msg: ARRAY OF CHAR; VAR error: ARRAY OF CHAR);
  VAR n: ARRAY 24 OF CHAR;
BEGIN
  IntToStr(line, n);
  COPY(file, error); Strings.Append(":", error); Strings.Append(n, error);
  Strings.Append(": ", error); Strings.Append(msg, error)
END Error;

(* One setting, key and value, into c; k is the capsule being read, NIL
   before the first. FALSE with why if it is wrong. *)
PROCEDURE Setting(c: Config; VAR k: Capsule; key, value: ARRAY OF CHAR;
    VAR why: ARRAY OF CHAR): BOOLEAN;
  VAR x: LONGINT;
BEGIN
  IF value = "" THEN COPY(key, why); Strings.Append(" needs a value", why); RETURN FALSE END;
  IF (key = "capsule") OR (key = "alias") OR (key = "listen") OR (key = "port")
    OR (key = "deadline") THEN
    IF ~OneWord(value) THEN COPY(key, why); Strings.Append(" takes one word", why); RETURN FALSE END
  END;
  IF key = "capsule" THEN RETURN c.Add(value, FALSE, k, why)
  ELSIF (key = "alias") OR (key = "root") OR (key = "cert") OR (key = "key") THEN
    IF k = NIL THEN COPY(key, why); Strings.Append(" outside a capsule", why); RETURN FALSE
    ELSIF key = "alias" THEN RETURN c.AddAlias(k, value, why)
    ELSIF Strings.Length(value) >= PathLen THEN COPY("a file name too long", why); RETURN FALSE
    ELSIF key = "root" THEN COPY(value, k.root)
    ELSIF key = "cert" THEN COPY(value, k.cert)
    ELSE COPY(value, k.key)
    END
  ELSIF k # NIL THEN COPY(key, why); Strings.Append(" inside a capsule: global settings come first", why); RETURN FALSE
  ELSIF key = "listen" THEN
    IF Strings.Length(value) >= NameLen THEN COPY("a listen address too long", why); RETURN FALSE END;
    COPY(value, c.listen)
  ELSIF key = "port" THEN
    IF ~Number(value, 0, 65535, x) THEN COPY("a port is 0 to 65535", why); RETURN FALSE END;
    c.port := x
  ELSIF key = "deadline" THEN
    IF ~Number(value, 1, 3600000, x) THEN COPY("a deadline is 1 to 3600000 ms", why); RETURN FALSE END;
    c.deadline := x
  ELSIF key = "certdir" THEN
    IF Strings.Length(value) >= PathLen THEN COPY("a file name too long", why); RETURN FALSE END;
    COPY(value, c.certdir)
  ELSE COPY("unknown setting: ", why); Strings.Append(key, why); RETURN FALSE
  END;
  RETURN TRUE
END Setting;

(* Reads the file called file into c. FALSE, with "file:line: why" in
   error, at the first thing wrong in it, or if it can't be read. *)
PROCEDURE Read*(c: Config; file: ARRAY OF CHAR; VAR error: ARRAY OF CHAR): BOOLEAN;
  VAR f: Files.File; r: Files.Rider; line: ARRAY LineLen + 2 OF CHAR;
    key: ARRAY 64 OF CHAR; value: Path; why: ARRAY ErrorLen OF CHAR;
    n: LONGINT; k: Capsule;
BEGIN
  f := Files.Old(file);
  IF f = NIL THEN COPY(file, error); Strings.Append(": can't be read", error); RETURN FALSE END;
  Files.Set(r, f, 0); n := 0; k := NIL;
  LOOP
    Files.ReadLine(r, line); INC(n);
    IF r.eof & (line = "") THEN EXIT END;
    IF Strings.Length(line) > LineLen THEN
      Error(file, n, "a line too long", error); Files.Close(f); RETURN FALSE
    END;
    Split(line, key, value);
    IF (key # "") & ~Setting(c, k, key, value, why) THEN
      Error(file, n, why, error); Files.Close(f); RETURN FALSE
    END;
    IF r.eof THEN EXIT END
  END;
  Files.Close(f);
  RETURN TRUE
END Read;

END GemConfig.
