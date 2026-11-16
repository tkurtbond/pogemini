MODULE TestConfig; (* GemConfig: configuration files read, and refused *)

(* GemConfig on its own, no server: a file with every setting, read into
   the values expected, and files with one thing wrong each, refused
   with the line and the reason. The files are written into
   ../build/test-config, made afresh. *)

IMPORT Out, Files, Platform, Check, GemConfig;

CONST Dir = "../build/test-config/";

VAR c: GemConfig.Config; error: ARRAY GemConfig.ErrorLen OF CHAR;

(* The file name in Dir. *)
PROCEDURE Path(name: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  COPY(Dir, path); i := 0; WHILE path[i] # 0X DO INC(i) END;
  j := 0; WHILE name[j] # 0X DO path[i] := name[j]; INC(i); INC(j) END;
  path[i] := 0X
END Path;

(* Writes text to the file name in Dir, with each "|" a line feed and "~" a carriage return. *)
PROCEDURE Write(name, text: ARRAY OF CHAR);
  VAR f: Files.File; r: Files.Rider; path: ARRAY 256 OF CHAR; i: LONGINT;
BEGIN
  Path(name, path);
  f := Files.New(path); Files.Set(r, f, 0); i := 0;
  WHILE text[i] # 0X DO
    IF text[i] = "|" THEN Files.Write(r, 0AX) ELSIF text[i] = "~" THEN Files.Write(r, 0DX) ELSE Files.Write(r, text[i]) END;
    INC(i)
  END;
  Files.Register(f)
END Write;

(* Reads the file name in Dir into a new c. *)
PROCEDURE Read(name: ARRAY OF CHAR): BOOLEAN;
  VAR path: ARRAY 256 OF CHAR;
BEGIN
  Path(name, path);
  c := GemConfig.New(); error := "";
  RETURN GemConfig.Read(c, path, error)
END Read;

(* A file of text is refused, with error. *)
PROCEDURE Bad(label, text, expected: ARRAY OF CHAR);
  VAR ok: BOOLEAN;
BEGIN
  Write("bad", text);
  ok := ~Read("bad") & (error = expected);
  Check.Check(ok, label);
  IF ~ok THEN Out.String("  error: "); Out.String(error); Out.Ln END
END Bad;

PROCEDURE Main;
  VAR k, k2: GemConfig.Capsule; why: ARRAY 256 OF CHAR;
BEGIN
  IF Platform.System("rm -rf ../build/test-config && mkdir -p ../build/test-config") # 0 THEN
    Check.Check(FALSE, "make ../build/test-config"); Check.Summary; RETURN
  END;

  Write("good", "# every setting|listen ::1|  port 1966  |deadline	2500|certdir /var/lib/po gemini   # a comment|| # and another|capsule Example.ORG|  alias WWW.example.org|  alias example.net|  root /srv/a#b c |  cert /etc/a.crt|  key /etc/a.key|capsule 127.0.0.1|capsule ::1");
  Check.Check(Read("good"), "a file with every setting");
  IF error # "" THEN Out.String("  error: "); Out.String(error); Out.Ln END;
  Check.Check((c.listen = "::1") & (c.port = 1966) & (c.deadline = 2500), "  ... listen, port and deadline");
  Check.Check(c.certdir = "/var/lib/po gemini", "  ... certdir, with a space, and the comment after it dropped");
  Check.Check(c.n = 3, "  ... three capsules");
  k := c.capsules[0];
  Check.Check((k.name = "example.org") & (k.nAliases = 2) & (k.aliases[0] = "www.example.org")
    & (k.aliases[1] = "example.net"), "  ... the first's names, in lower case");
  Check.Check((k.root = "/srv/a#b c") & (k.cert = "/etc/a.crt") & (k.key = "/etc/a.key"),
    "  ... its root (# inside a value kept), cert and key");
  Check.Check((c.capsules[1].name = "127.0.0.1") & (c.capsules[2].name = "::1")
    & (c.capsules[2].cert = ""), "  ... the others, addresses, without cert");
  Check.Check((c.Find("www.example.org") = k) & (c.Find("example.org") = k)
    & (c.Find("::1") = c.capsules[2]) & (c.Find("example.com") = NIL), "Find: by name and alias");
  Check.Check(c.Add("", TRUE, k2, why) & (c.capsules[0] = k2) & (c.capsules[1] = k) & (c.n = 4),
    "Add first: a capsule for any host, before the rest");
  Check.Check(~c.AddAlias(k2, "x.example", why) & (why = "a capsule for any host has no aliases"),
    "  ... which has no aliases");

  Write("empty", "");
  Check.Check(Read("empty") & (c.n = 0) & (c.port = -1) & (c.deadline = -1) & (c.listen = ""),
    "an empty file: nothing set");
  Write("crlf", "port 1~|capsule a.example~|");
  Check.Check(Read("crlf") & (c.port = 1) & (c.n = 1) & (c.capsules[0].name = "a.example"),
    "CR LF line ends");

  Bad("a port too large", "port 70000", "../build/test-config/bad:1: a port is 0 to 65535");
  Bad("a port not a number", "port 19x", "../build/test-config/bad:1: a port is 0 to 65535");
  Bad("a deadline of 0", "deadline 0", "../build/test-config/bad:1: a deadline is 1 to 3600000 ms");
  Bad("an unknown setting", "#|frobnicate 1", "../build/test-config/bad:2: unknown setting: frobnicate");
  Bad("no value", "capsule", "../build/test-config/bad:1: capsule needs a value");
  Bad("no value, only a comment", "port # 1965", "../build/test-config/bad:1: port needs a value");
  Bad("two words", "capsule a.example b.example", "../build/test-config/bad:1: capsule takes one word");
  Bad("alias outside a capsule", "||alias x.example", "../build/test-config/bad:3: alias outside a capsule");
  Bad("root outside a capsule", "root /srv", "../build/test-config/bad:1: root outside a capsule");
  Bad("a global setting inside a capsule", "capsule a.example|port 1",
    "../build/test-config/bad:2: port inside a capsule: global settings come first");
  Bad("a capsule twice", "capsule a.example|capsule A.example",
    "../build/test-config/bad:2: a second capsule for a.example");
  Bad("an alias that is another's name", "capsule a.example|capsule b.example|alias a.example",
    "../build/test-config/bad:3: a second capsule for a.example");
  Bad("an underscore", "capsule a_b.example", "../build/test-config/bad:1: not a host name: a_b.example");
  Bad("a hyphen first", "capsule -a.example", "../build/test-config/bad:1: not a host name: -a.example");
  Bad("a hyphen last", "capsule a-.example", "../build/test-config/bad:1: not a host name: a-.example");
  Bad("an empty label", "capsule a..example", "../build/test-config/bad:1: not a host name: a..example");
  Bad("a final dot", "capsule a.example.", "../build/test-config/bad:1: not a host name: a.example.");
  Bad("a quote", "capsule a'b", "../build/test-config/bad:1: not a host name: a'b");
  Bad("brackets", "capsule [::1]", "../build/test-config/bad:1: not a host name: [::1]");
  Bad("not ASCII", "capsule bücher.example", "../build/test-config/bad:1: not a host name: bücher.example");
  Bad("a label too long",
    "capsule a234567890123456789012345678901234567890123456789012345678901234.example",
    "../build/test-config/bad:1: not a host name: a234567890123456789012345678901234567890123456789012345678901234.example");
  Check.Check(~GemConfig.ValidName("a.example.") & GemConfig.ValidName("a-b.example")
    & GemConfig.ValidName("xn--bcher-kva.example") & GemConfig.ValidName("localhost")
    & GemConfig.ValidName("2001:db8::1") & GemConfig.ValidName("10.0.0.1"),
    "ValidName: names and addresses");

  c := GemConfig.New();
  Check.Check(~GemConfig.Read(c, "../build/test-config/none", error)
    & (error = "../build/test-config/none: can't be read"), "a missing file");

  IF Platform.System("rm -rf ../build/test-config") # 0 THEN END;
  Check.Summary
END Main;

BEGIN
  Main
END TestConfig.
