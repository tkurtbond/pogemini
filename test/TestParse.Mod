MODULE TestParse; (* GemRequest: requests parsed, normalised and refused *)

(* GemRequest.Parse on its own, no server: what it makes of URLs a
   client should send, with every part of the URL checked, and what it
   refuses, by status and reason. The paths that try to leave the root
   ("..", encoded or not) matter most: Phase 4 looks them up as files. *)

IMPORT Out, Check, GemRequest;

CONST BOM = "﻿";  (* U+FEFF as UTF-8 *)

VAR r: GemRequest.Request; why: ARRAY 128 OF CHAR; status: INTEGER;

(* Appends n, then " bytes)", to label. *)
PROCEDURE Bytes(n: LONGINT; VAR label: ARRAY OF CHAR);
  VAR d: ARRAY 12 OF CHAR; i, j: INTEGER;
BEGIN
  i := 0; REPEAT d[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i) UNTIL n = 0;
  j := 0; WHILE label[j] # 0X DO INC(j) END;
  WHILE i > 0 DO DEC(i); label[j] := d[i]; INC(j) END;
  label[j] := 0X;
  COPY(" bytes)", d); i := 0; WHILE d[i] # 0X DO label[j] := d[i]; INC(i); INC(j) END;
  label[j] := 0X
END Bytes;

(* url parses, to host, port, path and, if query isn't "-", query. *)
PROCEDURE Good(url, host: ARRAY OF CHAR; port: LONGINT; path, query: ARRAY OF CHAR);
  VAR ok: BOOLEAN; label: ARRAY 1100 OF CHAR; n: LONGINT;
BEGIN
  status := GemRequest.Parse(url, r, why);
  ok := (status = GemRequest.Ok) & (r.scheme = "gemini") & (r.host = host)
    & (r.port = port) & (r.path = path);
  IF query = "-" THEN ok := ok & ~r.hasQuery & (r.query = "")
  ELSE ok := ok & r.hasQuery & (r.query = query)
  END;
  COPY(url, label);
  IF LEN(url) > 100 THEN
    n := 0; WHILE url[n] # 0X DO INC(n) END;
    IF n > 100 THEN label := "(a URL of "; Bytes(n, label) END
  END;
  Check.Check(ok, label);
  IF ~ok THEN
    Out.String("  status "); Out.Int(status, 0); Out.String(" "); Out.String(why);
    Out.String(", host "); Out.String(r.host); Out.String(", port "); Out.Int(r.port, 0);
    Out.String(", path "); Out.String(r.path); Out.String(", query "); Out.String(r.query); Out.Ln
  END
END Good;

(* url is refused with status, and a reason that is reason. *)
PROCEDURE Bad(label, url: ARRAY OF CHAR; st: INTEGER; reason: ARRAY OF CHAR);
  VAR ok: BOOLEAN;
BEGIN
  status := GemRequest.Parse(url, r, why);
  ok := (status = st) & (why = reason);
  Check.Check(ok, label);
  IF ~ok THEN Out.String("  status "); Out.Int(status, 0); Out.String(" "); Out.String(why); Out.Ln END
END Bad;

PROCEDURE Main;
  VAR u, p: ARRAY 1100 OF CHAR; d: ARRAY 64 OF CHAR; i, n: LONGINT;
BEGIN
  (* hosts and ports *)
  Good("gemini://example.org", "example.org", 1965, "/", "-");
  Check.Check(r.rawPath = "", "  ... its raw path is empty");
  Good("gemini://example.org/", "example.org", 1965, "/", "-");
  Good("GEMINI://Example.ORG.:1966/a/b", "example.org", 1966, "/a/b", "-");
  Good("gemini://example.org:/x", "example.org", 1965, "/x", "-");
  Good("gemini://[::1]:1965/", "::1", 1965, "/", "-");
  Good("gemini://[2001:DB8::1]/", "2001:db8::1", 1965, "/", "-");
  Good("gemini://127.0.0.1:0/", "127.0.0.1", 0, "/", "-");
  Good("gemini://xn--bcher-kva.example/", "xn--bcher-kva.example", 1965, "/", "-");
  Good("gemini://bücher.example/", "bücher.example", 1965, "/", "-");
  Good("gemini://ex%41mple.org/", "example.org", 1965, "/", "-");

  (* paths *)
  Good("gemini://h/a/./b/../c/", "h", 1965, "/a/c/", "-");
  Check.Check(r.rawPath = "/a/./b/../c/", "  ... its raw path is as sent");
  Good("gemini://h/a//b", "h", 1965, "/a/b", "-");
  Good("gemini://h/a/.", "h", 1965, "/a/", "-");
  Good("gemini://h/a/..", "h", 1965, "/", "-");
  Good("gemini://h/a/b/..", "h", 1965, "/a/", "-");
  Good("gemini://h/./a", "h", 1965, "/a", "-");
  Good("gemini://h/a/%2E%2E/b", "h", 1965, "/b", "-");
  Good("gemini://h/a/%2e/b", "h", 1965, "/a/b", "-");
  Good("gemini://h/...", "h", 1965, "/...", "-");
  Good("gemini://h/.a/..b", "h", 1965, "/.a/..b", "-");
  Good("gemini://h/a%20b/%C3%A9", "h", 1965, "/a b/é", "-");
  Good("gemini://h/é", "h", 1965, "/é", "-");
  Good("gemini://h/a~b_c-d!$&'()*+,;=:@", "h", 1965, "/a~b_c-d!$&'()*+,;=:@", "-");

  (* queries *)
  Good("gemini://h/search?gemini%20search", "h", 1965, "/search", "gemini%20search");
  Check.Check(GemRequest.Decode(r.query, d, n) & (n = 13) & (d = "gemini search"),
    "  ... decoded: gemini search");
  Good("gemini://h/?", "h", 1965, "/", "");
  Good("gemini://h?q", "h", 1965, "/", "q");
  Good("gemini://h/a?b/../c?d", "h", 1965, "/a", "b/../c?d");
  Check.Check(GemRequest.Decode("a%00b", d, n) & (n = 3) & (d[1] = 0X), "Decode: %00 is a byte");
  Check.Check(~GemRequest.Decode("a%0", d, n), "Decode: a short escape, refused");
  Check.Check(~GemRequest.Decode("0123456789012345678901234567890123456789012345678901234567890123", d, n),
    "Decode: too long for its buffer, refused");

  (* the longest *)
  u := "gemini://h/"; FOR i := 11 TO 1023 DO u[i] := "a" END; u[1024] := 0X;
  p := "/"; FOR i := 1 TO 1013 DO p[i] := "a" END; p[1014] := 0X;
  Good(u, "h", 1965, p, "-");
  u[1024] := "a"; u[1025] := 0X;
  Bad("a 1025-byte URL", u, 59, "the URL is over 1024 bytes");

  (* what the specification forbids *)
  Bad("userinfo", "gemini://u@h/", 59, "userinfo in the URL");
  Bad("userinfo with a password", "gemini://u:p@h/", 59, "userinfo in the URL");
  Bad("a fragment", "gemini://h/a#f", 59, "a fragment");
  Bad("an empty fragment", "gemini://h/#", 59, "a fragment");

  (* other schemes, which aren't served here *)
  Bad("https", "https://h/", 53, "only gemini: URLs are served here");
  Bad("mailto", "mailto:x@h", 53, "only gemini: URLs are served here");

  (* not URLs, or not well-formed *)
  Bad("empty", "", 59, "no URL");
  Bad("a relative reference", "//h/a", 59, "not an absolute URL");
  Bad("a path alone", "/a", 59, "not an absolute URL");
  Bad("no scheme", "h", 59, "not an absolute URL");
  Bad("a byte order mark first", BOM, 59, "not an absolute URL");
  u := BOM; COPY("gemini://h/", d); i := 0; WHILE d[i] # 0X DO u[3 + i] := d[i]; INC(i) END;
  u[3 + i] := 0X;
  Bad("a byte order mark before the URL", u, 59, "not an absolute URL");
  Bad("a space", "gemini://h/a b", 59, "a character not allowed in a URL");
  Bad("a tab", "gemini://h/a	b", 59, "a character not allowed in a URL");
  Bad("a backslash", "gemini://h/a\b", 59, "a character not allowed in a URL");
  Bad("no //", "gemini:/a", 59, "no host");
  Bad("no host", "gemini:///a", 59, "no host");
  Bad("only a port", "gemini://:1965/", 59, "no host");
  Bad("a port not a number", "gemini://h:x/", 59, "a malformed port");
  Bad("a port too large", "gemini://h:65536/", 59, "a malformed port");
  Bad("an IPv6 address unclosed", "gemini://[::1/", 59, "a malformed IPv6 address");
  Bad("an IPv6 address not hex", "gemini://[::g]/", 59, "a malformed IPv6 address");
  Bad("an empty IPv6 address", "gemini://[]/", 59, "a malformed IPv6 address");
  (* The longest literal r.host holds, 255 bytes, and longer, which
     once halted Parse with an index out of range. *)
  u := "gemini://["; FOR i := 10 TO 264 DO u[i] := "a" END; u[265] := "]"; u[266] := "/"; u[267] := 0X;
  FOR i := 0 TO 254 DO p[i] := "a" END; p[255] := 0X;
  Good(u, p, 1965, "/", "-");
  u := "gemini://["; FOR i := 10 TO 265 DO u[i] := "a" END; u[266] := "]"; u[267] := "/"; u[268] := 0X;
  Bad("an IPv6 address of 256 bytes", u, 59, "a malformed IPv6 address");
  u := "gemini://["; FOR i := 10 TO 309 DO u[i] := "a" END; u[310] := "]"; u[311] := "/"; u[312] := 0X;
  Bad("an IPv6 address of 300 bytes", u, 59, "a malformed IPv6 address");
  Bad("text after an IPv6 address", "gemini://[::1]x/", 59, "a malformed host");
  Bad("a bracket in a host", "gemini://h]/", 59, "a malformed host");
  Bad("an encoded space in a host", "gemini://a%20b/", 59, "a malformed host");
  Bad("bad encoding in a host", "gemini://a%2/", 59, "bad percent-encoding in the host");

  (* paths that leave the root, or that name no file *)
  Bad("..", "gemini://h/..", 59, "the path climbs above /");
  Bad("../a", "gemini://h/../a", 59, "the path climbs above /");
  Bad("a/../..", "gemini://h/a/../..", 59, "the path climbs above /");
  Bad("an encoded ..", "gemini://h/%2e%2E", 59, "the path climbs above /");
  Bad("an encoded / ", "gemini://h/a%2Fb", 59, "an encoded / in the path");
  Bad("an encoded ../ ", "gemini://h/..%2Fetc", 59, "an encoded / in the path");
  Bad("an encoded NUL", "gemini://h/a%00b", 59, "a control character in the path");
  Bad("an encoded LF", "gemini://h/a%0Ab", 59, "a control character in the path");
  Bad("an encoded DEL", "gemini://h/a%7Fb", 59, "a control character in the path");
  Bad("an encoded byte not UTF-8", "gemini://h/%FF", 59, "the path is not UTF-8");
  Bad("an encoded surrogate", "gemini://h/%ED%A0%80", 59, "the path is not UTF-8");
  Bad("a bad escape", "gemini://h/a%zz", 59, "bad percent-encoding in the path");
  Bad("a short escape", "gemini://h/a%4", 59, "bad percent-encoding in the path");
  Bad("a bad escape in the query", "gemini://h/?a%zz", 59, "bad percent-encoding in the query");

  (* malformed UTF-8 *)
  u := "gemini://h/"; u[11] := 0FFX; u[12] := 0X;
  Bad("a byte FF", u, 59, "the URL is not UTF-8");
  u[11] := 0C0X; u[12] := 80X; u[13] := 0X;
  Bad("an overlong NUL", u, 59, "the URL is not UTF-8");
  u[11] := 0E0X; u[12] := 80X; u[13] := 80X; u[14] := 0X;
  Bad("an overlong three bytes", u, 59, "the URL is not UTF-8");
  u[11] := 0F4X; u[12] := 90X; u[13] := 80X; u[14] := 80X; u[15] := 0X;
  Bad("over U+10FFFF", u, 59, "the URL is not UTF-8");
  u[11] := 0C3X; u[12] := 0X;
  Bad("cut short", u, 59, "the URL is not UTF-8");
  u[11] := 0F0X; u[12] := 9FX; u[13] := 98X; u[14] := 80X; u[15] := 0X;
  Good(u, "h", 1965, "/😀", "-");

  Check.Summary
END Main;

BEGIN
  Main
END TestParse.
