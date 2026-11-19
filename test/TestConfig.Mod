MODULE TestConfig; (* GemConfig: configuration files read, and refused *)

(* GemConfig on its own, no server: a file with every setting, read into
   the values expected, and files with one thing wrong each, refused
   with the line and the reason. The files are written into
   ../build/test-config, made afresh. *)

IMPORT Out, Files, Platform, Check, GemAddresses, GemConfig;

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

(* s parses, and formats back as f. *)
PROCEDURE Formats(s, f: ARRAY OF CHAR): BOOLEAN;
  VAR a: GemAddresses.Address; t: ARRAY 64 OF CHAR;
BEGIN
  IF ~GemAddresses.Parse(s, a) THEN Out.String("  not parsed: "); Out.String(s); Out.Ln; RETURN FALSE END;
  GemAddresses.Format(a, t);
  IF t # f THEN Out.String("  "); Out.String(s); Out.String(" as "); Out.String(t); Out.Ln END;
  RETURN t = f
END Formats;

(* s is no address. *)
PROCEDURE NotAddress(s: ARRAY OF CHAR): BOOLEAN;
  VAR a: GemAddresses.Address;
BEGIN
  IF GemAddresses.Parse(s, a) THEN Out.String("  parsed: "); Out.String(s); Out.Ln; RETURN FALSE END;
  RETURN TRUE
END NotAddress;

(* Whether address s is in range r, both parsed. *)
PROCEDURE InRange(s, r: ARRAY OF CHAR): BOOLEAN;
  VAR a: GemAddresses.Address; g: GemAddresses.Range; why: ARRAY 128 OF CHAR;
BEGIN
  RETURN GemAddresses.Parse(s, a) & GemAddresses.ParseRange(r, g, why) & GemAddresses.In(a, g)
END InRange;

(* Range s is refused, with why. *)
PROCEDURE BadRange(s, expected: ARRAY OF CHAR): BOOLEAN;
  VAR g: GemAddresses.Range; why: ARRAY 128 OF CHAR;
BEGIN
  why := "";
  IF GemAddresses.ParseRange(s, g, why) OR (why # expected) THEN
    Out.String("  "); Out.String(s); Out.String(": "); Out.String(why); Out.Ln; RETURN FALSE
  END;
  RETURN TRUE
END BadRange;

(* Whether c, as read, serves address s. *)
PROCEDURE Serves(s: ARRAY OF CHAR): BOOLEAN;
  VAR a: GemAddresses.Address;
BEGIN
  IF ~GemAddresses.Parse(s, a) THEN Out.String("  not parsed: "); Out.String(s); Out.Ln; RETURN FALSE END;
  RETURN c.Admits(a)
END Serves;

(* Gives c's rule i the one address s, as a lookup would. *)
PROCEDURE Found(i: INTEGER; s: ARRAY OF CHAR);
BEGIN
  NEW(c.rules[i].addrs, 1); c.rules[i].nAddrs := 1;
  IF GemAddresses.Parse(s, c.rules[i].addrs[0]) THEN END
END Found;

(* Writes the file many: n lines of "deny all". *)
PROCEDURE Many(n: INTEGER);
  VAR t: ARRAY 1024 OF CHAR; line: ARRAY 10 OF CHAR; i, j, k: LONGINT;
BEGIN
  line := "deny all|"; k := 0;
  FOR i := 1 TO n DO FOR j := 0 TO 8 DO t[k] := line[j]; INC(k) END END;
  t[k] := 0X; Write("many", t)
END Many;

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
  VAR k, k2: GemConfig.Capsule; a: GemConfig.Area; why: ARRAY 256 OF CHAR; n, n2: GemConfig.Name;
BEGIN
  IF Platform.System("rm -rf ../build/test-config && mkdir -p ../build/test-config") # 0 THEN
    Check.Check(FALSE, "make ../build/test-config"); Check.Summary; RETURN
  END;

  Write("good", "# every setting|listen ::1|  port 1966  |deadline	2500|connections 100|user gemini|certdir /var/lib/po gemini   # a comment|| # and another|capsule Example.ORG|  alias WWW.example.org|  alias example.net|  root /srv/a#b c |  cert /etc/a.crt|  key /etc/a.key|  listings yes|require /private/|  identity SHA256:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef|  identity sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff|require /a b|capsule 127.0.0.1|  listings yes|  listings no|  require /|capsule ::1");
  Check.Check(Read("good"), "a file with every setting");
  IF error # "" THEN Out.String("  error: "); Out.String(error); Out.Ln END;
  Check.Check((c.listen = "::1") & (c.port = 1966) & (c.deadline = 2500), "  ... listen, port and deadline");
  Check.Check((c.connections = 100) & (c.user = "gemini"), "  ... connections and user");
  Check.Check(c.certdir = "/var/lib/po gemini", "  ... certdir, with a space, and the comment after it dropped");
  Check.Check(c.n = 3, "  ... three capsules");
  k := c.capsules[0];
  Check.Check((k.name = "example.org") & (k.nAliases = 2) & (k.aliases[0] = "www.example.org")
    & (k.aliases[1] = "example.net"), "  ... the first's names, in lower case");
  Check.Check((k.root = "/srv/a#b c") & (k.cert = "/etc/a.crt") & (k.key = "/etc/a.key"),
    "  ... its root (# inside a value kept), cert and key");
  Check.Check((k.nAreas = 2) & (k.areas[0].path = "/private") & (k.areas[1].path = "/a b")
    & (k.areas[1].nIds = 0), "  ... its requires, the final / dropped, a space kept");
  a := k.areas[0];
  Check.Check((a.nIds = 2)
    & (a.ids[0] = "SHA256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    & (a.ids[1] = "SHA256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
    "  ... and the first's identities, as libtls writes a hash");
  Check.Check((c.capsules[1].name = "127.0.0.1") & (c.capsules[2].name = "::1")
    & (c.capsules[2].cert = ""), "  ... the others, addresses, without cert");
  Check.Check(k.listings & ~c.capsules[1].listings & ~c.capsules[2].listings,
    "  ... listings: yes in the first, no after yes in the second, none by default");
  Check.Check((c.capsules[1].nAreas = 1) & (c.capsules[1].areas[0].path = "/")
    & (c.capsules[2].nAreas = 0), "  ... a require of / in the second, none in the third");
  Check.Check(GemConfig.Within("/private", "/private") & GemConfig.Within("/private/a.gmi", "/private")
    & GemConfig.Within("/private/", "/private") & ~GemConfig.Within("/privateer", "/private")
    & ~GemConfig.Within("/", "/private") & ~GemConfig.Within("/priv", "/private")
    & GemConfig.Within("/", "/") & GemConfig.Within("/x/y", "/"),
    "Within: a path, segment by segment");
  Check.Check((c.Find("www.example.org") = k) & (c.Find("example.org") = k)
    & (c.Find("::1") = c.capsules[2]) & (c.Find("example.com") = NIL), "Find: by name and alias");
  Check.Check(c.Add("", TRUE, k2, why) & (c.capsules[0] = k2) & (c.capsules[1] = k) & (c.n = 4),
    "Add first: a capsule for any host, before the rest");
  Check.Check(~c.AddAlias(k2, "x.example", why) & (why = "a capsule for any host has no aliases"),
    "  ... which has no aliases");

  Write("empty", "");
  Check.Check(Read("empty") & (c.n = 0) & (c.port = -1) & (c.deadline = -1) & (c.listen = "")
    & (c.connections = -1) & (c.user = ""),
    "an empty file: nothing set");
  Write("crlf", "port 1~|capsule a.example~|");
  Check.Check(Read("crlf") & (c.port = 1) & (c.n = 1) & (c.capsules[0].name = "a.example"),
    "CR LF line ends");

  Bad("a port too large", "port 70000", "../build/test-config/bad:1: a port is 0 to 65535");
  Bad("a port not a number", "port 19x", "../build/test-config/bad:1: a port is 0 to 65535");
  Bad("a deadline of 0", "deadline 0", "../build/test-config/bad:1: a deadline is 1 to 3600000 ms");
  Bad("connections 0", "connections 0", "../build/test-config/bad:1: connections is 1 to 100000");
  Bad("connections too many", "connections 100001", "../build/test-config/bad:1: connections is 1 to 100000");
  Bad("a user of two words", "user a b", "../build/test-config/bad:1: user takes one word");
  Bad("user inside a capsule", "capsule a.example|user gemini",
    "../build/test-config/bad:2: user inside a capsule: global settings come first");
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
  Bad("listings outside a capsule", "listings yes", "../build/test-config/bad:1: listings outside a capsule");
  Bad("listings neither yes nor no", "capsule a.example|listings on",
    "../build/test-config/bad:2: listings is yes or no");
  Bad("require outside a capsule", "require /x", "../build/test-config/bad:1: require outside a capsule");
  Bad("identity outside a require", "capsule a.example|identity SHA256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "../build/test-config/bad:2: identity outside a require");
  Bad("identity after a new capsule", "capsule a.example|require /x|capsule b.example|identity SHA256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "../build/test-config/bad:4: identity outside a require");
  Bad("an identity too short", "capsule a.example|require /x|identity SHA256:0123",
    "../build/test-config/bad:3: an identity is SHA256: and 64 hex digits");
  Bad("an identity not hex", "capsule a.example|require /x|identity SHA256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg",
    "../build/test-config/bad:3: an identity is SHA256: and 64 hex digits");
  Bad("an identity not SHA-256", "capsule a.example|require /x|identity SHA512:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "../build/test-config/bad:3: an identity is SHA256: and 64 hex digits");
  Bad("a relative require", "capsule a.example|require private",
    "../build/test-config/bad:2: a require is a path beginning with /");
  Bad("a require with ..", "capsule a.example|require /a/../b",
    "../build/test-config/bad:2: a require with an empty, . or .. segment: /a/../b");
  Bad("a require with .", "capsule a.example|require /a/.",
    "../build/test-config/bad:2: a require with an empty, . or .. segment: /a/.");
  Bad("a require with //", "capsule a.example|require //",
    "../build/test-config/bad:2: a require with an empty, . or .. segment: //");
  Bad("a require twice", "capsule a.example|require /a|require /a/",
    "../build/test-config/bad:3: a second require for /a");
  Bad("an underscore", "capsule a_b.example", "../build/test-config/bad:1: not a host name: a_b.example");
  Bad("a hyphen first", "capsule -a.example", "../build/test-config/bad:1: not a host name: -a.example");
  Bad("a hyphen last", "capsule a-.example", "../build/test-config/bad:1: not a host name: a-.example");
  Bad("an empty label", "capsule a..example", "../build/test-config/bad:1: not a host name: a..example (label 2: empty)");
  Bad("a final dot", "capsule a.example.", "../build/test-config/bad:1: not a host name: a.example.");
  Bad("a quote", "capsule a'b", "../build/test-config/bad:1: not a host name: a'b");
  Bad("brackets", "capsule [::1]", "../build/test-config/bad:1: not a host name: [::1]");
  Bad("not ASCII, and not a host name once ASCII", "capsule bücher_.example",
    "../build/test-config/bad:1: not a host name: bücher_.example");
  Check.Check(GemConfig.HostName("Bücher.Example", n, why) & (n = "xn--bcher-kva.example"),
    "HostName: UTF-8, in capitals, to its ASCII form");
  Check.Check(GemConfig.HostName("XN--bcher-KVA.example", n, why) & (n = "xn--bcher-kva.example")
    & GemConfig.HostName("::1", n, why) & (n = "::1"), "  ... its ASCII form, and an address, lowered");
  n := "bxcher.example"; n[1] := 0FCX;
  Check.Check(~GemConfig.HostName(n, n2, why) & Check.Contains(why, "not a host name: b"),
    "  ... refused: malformed UTF-8");
  Bad("a label too long",
    "capsule a234567890123456789012345678901234567890123456789012345678901234.example",
    "../build/test-config/bad:1: not a host name: a234567890123456789012345678901234567890123456789012345678901234.example (label 1: over 63 bytes)");
  Check.Check(~GemConfig.ValidName("a.example.") & GemConfig.ValidName("a-b.example")
    & GemConfig.ValidName("xn--bcher-kva.example") & GemConfig.ValidName("localhost")
    & GemConfig.ValidName("2001:db8::1") & GemConfig.ValidName("10.0.0.1"),
    "ValidName: names and addresses");

  (* GemAddresses, and the rules *)
  Check.Check(Formats("192.0.2.1", "192.0.2.1") & Formats("0.0.0.0", "0.0.0.0")
    & Formats("255.255.255.255", "255.255.255.255"), "GemAddresses: IPv4");
  Check.Check(Formats("::ffff:192.0.2.1", "192.0.2.1") & Formats("::FFFF:c000:0201", "192.0.2.1")
    & Formats("0:0:0:0:0:ffff:192.0.2.1", "192.0.2.1"), "  ... IPv4-mapped IPv6, as IPv4");
  Check.Check(Formats("::1", "::1") & Formats("::", "::") & Formats("2001:DB8:0:0:0:0:0:1", "2001:db8::1")
    & Formats("2001:0db8:0000:0001:0000:0000:0000:0001", "2001:db8:0:1::1")
    & Formats("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1") & Formats("1::", "1::")
    & Formats("1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8") & Formats("1:0:2:3:4:5:6:7", "1:0:2:3:4:5:6:7")
    & Formats("::2:3:4:5:6:7:8", "0:2:3:4:5:6:7:8") & Formats("::192.0.2.1", "::c000:201"),
    "  ... IPv6, as RFC 5952 writes it");
  Check.Check(Formats("fe80::1%eth0", "fe80::1") & NotAddress("fe80::1%") & NotAddress("192.0.2.1%eth0"),
    "  ... a zone dropped, only on IPv6, and not empty");
  Check.Check(NotAddress("") & NotAddress("192.0.2") & NotAddress("192.0.2.1.5") & NotAddress("192.0.2.256")
    & NotAddress("192.0.2.01") & NotAddress("192.0.2.1 ") & NotAddress("1:2:3:4:5:6:7")
    & NotAddress("1:2:3:4:5:6:7:8:9") & NotAddress("1::2::3") & NotAddress("12345::")
    & NotAddress("::g") & NotAddress(":1::") & NotAddress("1:::2") & NotAddress("1:2:3:4:5:6:7::8")
    & NotAddress("localhost"),
    "  ... not addresses");
  Check.Check(InRange("192.0.2.77", "192.0.2.0/24") & ~InRange("192.0.3.1", "192.0.2.0/24")
    & InRange("::ffff:192.0.2.77", "192.0.2.0/24") & InRange("10.1.2.3", "0.0.0.0/0")
    & ~InRange("::1", "0.0.0.0/0") & InRange("192.0.2.1", "192.0.2.1")
    & ~InRange("192.0.2.2", "192.0.2.1") & InRange("192.0.2.129", "192.0.2.128/25")
    & ~InRange("192.0.2.127", "192.0.2.128/25"),
    "  ... IPv4 ranges, matching IPv4-mapped, not IPv6");
  Check.Check(InRange("2001:db8::5", "2001:db8::/32") & ~InRange("2001:db9::5", "2001:db8::/32")
    & InRange("fe80::1%eth0", "fe80::/10") & InRange("febf::1", "fe80::/10") & ~InRange("fec0::1", "fe80::/10")
    & InRange("::1", "::/0") & InRange("192.0.2.1", "::/0") & InRange("::1", "::1"),
    "  ... IPv6 ranges");
  Check.Check(BadRange("192.0.2.1/24", "an address with bits set past its range's prefix")
    & BadRange("2001:db8::1/64", "an address with bits set past its range's prefix")
    & BadRange("192.0.2.0/33", "a range's prefix is 0 to 32 bits for IPv4, 0 to 128 for IPv6")
    & BadRange("::/129", "a range's prefix is 0 to 32 bits for IPv4, 0 to 128 for IPv6")
    & BadRange("192.0.2.0/024", "a range's prefix is 0 to 32 bits for IPv4, 0 to 128 for IPv6")
    & BadRange("192.0.2.0/", "a range's prefix is 0 to 32 bits for IPv4, 0 to 128 for IPv6")
    & BadRange("192.0.2.0/2x", "a range's prefix is 0 to 32 bits for IPv4, 0 to 128 for IPv6")
    & BadRange("192.0.2/24", "not an address or range"),
    "  ... ranges refused");

  Write("rules", "refresh 60|allow 192.0.2.0/24|deny 192.0.2.7|allow Gemini.Example|deny ::1|allow 2001:db8::/32|deny all|capsule a.example");
  Check.Check(Read("rules") & (c.nRules = 6) & (c.refresh = 60), "rules: read, in order");
  IF error # "" THEN Out.String("  error: "); Out.String(error); Out.Ln END;
  Check.Check(c.rules[0].allow & ~c.rules[1].allow & (c.rules[0].name = "") & (c.rules[2].name = "gemini.example")
    & (c.rules[2].nAddrs = 0) & (c.rules[5].range.bits = 0), "  ... allow and deny, a name lowered, all");
  Check.Check(Serves("192.0.2.7") & Serves("192.0.2.1") & ~Serves("192.0.3.1") & ~Serves("::1")
    & Serves("2001:db8::1") & ~Serves("2001:db9::1"), "  ... the first rule to match decides");
  Found(2, "198.51.100.9");
  Check.Check(Serves("198.51.100.9") & ~Serves("198.51.100.10"), "  ... a name, by the addresses found for it");
  Write("norules", "deny 192.0.2.1");
  Check.Check(Read("norules") & ~Serves("192.0.2.1") & Serves("192.0.2.2") & Serves("::1") & (c.refresh = -1),
    "  ... none matching: served");
  Bad("a range with host bits", "deny 192.0.2.1/24",
    "../build/test-config/bad:1: an address with bits set past its range's prefix: 192.0.2.1/24");
  Bad("an address too large", "deny 192.0.2.300", "../build/test-config/bad:1: not an address or range: 192.0.2.300");
  Bad("a bad name", "allow a_b.example", "../build/test-config/bad:1: not a host name: a_b.example");
  Bad("a rule of two words", "allow 192.0.2.1 192.0.2.2", "../build/test-config/bad:1: allow takes one word");
  Bad("a rule inside a capsule", "capsule a.example|deny all",
    "../build/test-config/bad:2: deny inside a capsule: global settings come first");
  Bad("refresh too large", "refresh 86401", "../build/test-config/bad:1: refresh is 0 to 86400 s");
  Many(GemConfig.MaxRules);
  Check.Check(Read("many") & (c.nRules = GemConfig.MaxRules), "  ... as many rules as MaxRules");
  Many(GemConfig.MaxRules + 1);
  Check.Check(~Read("many") & (error = "../build/test-config/many:65: too many allow and deny rules"),
    "  ... and no more");
  IF ~Check.Contains(error, "many:65:") THEN Out.String("  error: "); Out.String(error); Out.Ln END;

  (* The example installed with the server: it must stay one the server
     reads, and say what its comments say. *)
  c := GemConfig.New(); error := "";
  Check.Check(GemConfig.Read(c, "../contrib/pogemini.conf", error), "contrib/pogemini.conf: read");
  IF error # "" THEN Out.String("  error: "); Out.String(error); Out.Ln END;
  Check.Check((c.listen = "") & (c.port = 1965) & (c.deadline = 10000) & (c.connections = 256)
    & (c.user = "gemini") & (c.certdir = "/var/lib/pogemini/certs") & (c.n = 2)
    & (c.capsules[0].name = "example.org") & (c.capsules[0].nAliases = 1)
    & (c.capsules[0].cert # "") & (c.capsules[0].nAreas = 1) & (c.capsules[0].areas[0].nIds = 1)
    & ~c.capsules[0].listings & c.capsules[1].listings
    & (c.capsules[1].name = "example.net") & (c.capsules[1].cert = "")
    & (c.capsules[1].nAreas = 1) & (c.capsules[1].areas[0].nIds = 0),
    "  ... its settings and two capsules");

  c := GemConfig.New();
  Check.Check(~GemConfig.Read(c, "../build/test-config/none", error)
    & (error = "../build/test-config/none: can't be read"), "a missing file");

  IF Platform.System("rm -rf ../build/test-config") # 0 THEN END;
  Check.Summary
END Main;

BEGIN
  Main
END TestConfig.
