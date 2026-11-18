MODULE GemRequest; (* A Gemini request's URL, parsed and checked *)

(* A request is an absolute URI, at most 1024 bytes (the Gemini
   specification, "Requests"). Parse takes it apart into scheme, host,
   port, path and query, and refuses, with status 59 and a reason, what
   the specification says a server must reject (a URL over 1024 bytes,
   userinfo, a fragment) and what is not a URL at all; a scheme other
   than gemini it refuses with 53, since that is a request for something
   this server does not serve. Whether the host and port are this
   server's is for the caller, which knows them.

   Besides the characters of RFC 3986, a URL may contain any non-ASCII
   characters as UTF-8, as an IRI (RFC 3987) does, since some clients
   send them so; malformed UTF-8 is refused.

   The path comes back decoded and normalised, ready to be looked up:
   each segment percent-decoded, "." and ".." resolved after decoding (so
   "%2E%2E" is ".." too), empty segments dropped, and the result always
   beginning with "/" (an empty path is "/", as the specification
   requires). A path whose ".." would climb above "/", or with a segment
   that decodes to "/", NUL, another control character or malformed
   UTF-8, is refused (59): none of those names a file a server should
   serve, and refusing them here means no later code has to remember
   to. A trailing "/" is kept, since it says the client asked for a
   directory. The query is left as sent, still percent-encoded: Decode
   decodes it. *)

CONST
  MaxURL* = 1024;      (* a request's URL at most, by the specification *)
  DefaultPort* = 1965;
  Ok* = 0;
  BadRequest* = 59;    (* not a URL, or one the specification forbids *)
  Refused* = 53;       (* not a gemini: URL *)

TYPE
  URL* = ARRAY MaxURL + 1 OF CHAR;

  Request* = RECORD
    scheme-: ARRAY 64 OF CHAR;  (* lower case *)
    host-: ARRAY 256 OF CHAR;   (* lower case, decoded, with no
                                   final "." and an IPv6 address
                                   without its brackets *)
    port-: LONGINT;             (* DefaultPort if none was given *)
    path-: URL;                 (* decoded and normalised: see above *)
    rawPath-: URL;              (* as sent, "" for none *)
    hasQuery-: BOOLEAN;         (* there was a "?", perhaps with nothing after *)
    query-: URL                 (* after the "?", as sent *)
  END;

PROCEDURE Length(s: ARRAY OF CHAR): LONGINT;
  VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END; RETURN n
END Length;

PROCEDURE Alpha(c: CHAR): BOOLEAN;
BEGIN RETURN (CAP(c) >= "A") & (CAP(c) <= "Z")
END Alpha;

PROCEDURE Digit(c: CHAR): BOOLEAN;
BEGIN RETURN (c >= "0") & (c <= "9")
END Digit;

(* The value of hex digit c, or -1 *)
PROCEDURE Hex(c: CHAR): INTEGER;
BEGIN
  IF Digit(c) THEN RETURN ORD(c) - ORD("0")
  ELSIF (CAP(c) >= "A") & (CAP(c) <= "F") THEN RETURN ORD(CAP(c)) - ORD("A") + 10
  ELSE RETURN -1
  END
END Hex;

PROCEDURE Lower(c: CHAR): CHAR;
BEGIN
  IF (c >= "A") & (c <= "Z") THEN RETURN CHR(ORD(c) + 32) ELSE RETURN c END
END Lower;

(* c may appear in a URL as itself: RFC 3986's unreserved, gen-delims
   and sub-delims, "%", and every byte of a non-ASCII character. *)
PROCEDURE UrlChar(c: CHAR): BOOLEAN;
BEGIN
  RETURN Alpha(c) OR Digit(c) OR (c >= 80X)
    OR (c = "-") OR (c = ".") OR (c = "_") OR (c = "~")
    OR (c = ":") OR (c = "/") OR (c = "?") OR (c = "#") OR (c = "[") OR (c = "]") OR (c = "@")
    OR (c = "!") OR (c = "$") OR (c = "&") OR (c = "'") OR (c = "(") OR (c = ")")
    OR (c = "*") OR (c = "+") OR (c = ",") OR (c = ";") OR (c = "=") OR (c = "%")
END UrlChar;

(* s[0..n-1] is well-formed UTF-8 (RFC 3629): no overlong forms, no
   surrogates, nothing over U+10FFFF. *)
PROCEDURE Utf8*(VAR s: ARRAY OF CHAR; n: LONGINT): BOOLEAN;
  VAR i, k: LONGINT; c: INTEGER; lo, hi: CHAR;
BEGIN
  i := 0;
  WHILE i < n DO
    c := ORD(s[i]); lo := 80X; hi := 0BFX;
    IF c < 80H THEN k := 0
    ELSIF (c >= 0C2H) & (c <= 0DFH) THEN k := 1
    ELSIF c = 0E0H THEN k := 2; lo := 0A0X
    ELSIF c = 0EDH THEN k := 2; hi := 9FX
    ELSIF (c >= 0E1H) & (c <= 0EFH) THEN k := 2
    ELSIF c = 0F0H THEN k := 3; lo := 90X
    ELSIF c = 0F4H THEN k := 3; hi := 8FX
    ELSIF (c >= 0F1H) & (c <= 0F3H) THEN k := 3
    ELSE RETURN FALSE
    END;
    INC(i);
    IF k > 0 THEN
      IF (i >= n) OR (s[i] < lo) OR (s[i] > hi) THEN RETURN FALSE END;
      INC(i); DEC(k);
      WHILE k > 0 DO
        IF (i >= n) OR (s[i] < 80X) OR (s[i] > 0BFX) THEN RETURN FALSE END;
        INC(i); DEC(k)
      END
    END
  END;
  RETURN TRUE
END Utf8;

(* Decodes s[from..to-1]'s percent-encoding into d, 0X-terminated, and
   its length into n: FALSE if a "%" isn't followed by two hex digits. *)
PROCEDURE DecodePart(VAR s: ARRAY OF CHAR; from, to: LONGINT;
    VAR d: ARRAY OF CHAR; VAR n: LONGINT): BOOLEAN;
  VAR i: LONGINT; h, l: INTEGER;
BEGIN
  i := from; n := 0;
  WHILE i < to DO
    IF s[i] = "%" THEN
      IF i + 2 >= to THEN RETURN FALSE END;
      h := Hex(s[i + 1]); l := Hex(s[i + 2]);
      IF (h < 0) OR (l < 0) THEN RETURN FALSE END;
      d[n] := CHR(h * 16 + l); INC(i, 3)
    ELSE d[n] := s[i]; INC(i)
    END;
    INC(n)
  END;
  d[n] := 0X;
  RETURN TRUE
END DecodePart;

(* Decodes s's percent-encoding (a query's, say) into d: FALSE if a "%"
   isn't followed by two hex digits, or the result doesn't fit d. The
   result may contain any byte, 0X included, so n is its length. *)
PROCEDURE Decode*(s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR; VAR n: LONGINT): BOOLEAN;
  VAR m: LONGINT;
BEGIN
  m := Length(s);
  (* Decoding never lengthens. *)
  IF m >= LEN(d) THEN n := 0; RETURN FALSE END;
  RETURN DecodePart(s, 0, m, d, n)
END Decode;

PROCEDURE Fail(VAR why: ARRAY OF CHAR; reason: ARRAY OF CHAR): INTEGER;
BEGIN COPY(reason, why); RETURN BadRequest
END Fail;

(* Normalises url[from..to-1], the raw path, into r.path: FALSE, with
   why, if it can't be. *)
PROCEDURE Path(VAR url: ARRAY OF CHAR; from, to: LONGINT; VAR r: Request;
    VAR why: ARRAY OF CHAR): BOOLEAN;
  VAR seg: URL; i, j, k, n, p: LONGINT; dir: BOOLEAN;
BEGIN
  (* r.path holds "/" and the segments so far, each after a "/"; p is
     its length. dir: the last segment named a directory. *)
  r.path[0] := "/"; p := 1; dir := FALSE;
  i := from;
  IF (i < to) & (url[i] = "/") THEN INC(i) END;
  WHILE i < to DO
    j := i; WHILE (j < to) & (url[j] # "/") DO INC(j) END;
    IF ~DecodePart(url, i, j, seg, n) THEN COPY("bad percent-encoding in the path", why); RETURN FALSE END;
    k := 0;
    WHILE k < n DO
      IF seg[k] = "/" THEN COPY("an encoded / in the path", why); RETURN FALSE
      ELSIF (seg[k] < " ") OR (seg[k] = 7FX) THEN
        COPY("a control character in the path", why); RETURN FALSE
      END;
      INC(k)
    END;
    IF ~Utf8(seg, n) THEN COPY("the path is not UTF-8", why); RETURN FALSE END;
    IF (n = 0) OR (seg = ".") THEN dir := TRUE
    ELSIF seg = ".." THEN
      IF p = 1 THEN COPY("the path climbs above /", why); RETURN FALSE END;
      (* Drop the last segment and its "/". *)
      DEC(p); WHILE r.path[p - 1] # "/" DO DEC(p) END;
      dir := TRUE
    ELSE
      IF p > 1 THEN r.path[p - 1] := "/" END;
      k := 0; WHILE k < n DO r.path[p] := seg[k]; INC(p); INC(k) END;
      INC(p); r.path[p - 1] := "/";  (* the separator, if another segment comes *)
      dir := FALSE
    END;
    i := j + 1;
    (* A path ending in "/" names a directory. *)
    IF j = to - 1 THEN dir := TRUE END
  END;
  (* r.path[0..p-1] ends with "/" whenever it has a segment; keep it
     only for a directory. *)
  IF (p > 1) & ~dir THEN DEC(p) END;
  r.path[p] := 0X;
  RETURN TRUE
END Path;

(* Parses and checks url, the request line without its CR LF: Ok, with
   r filled in, or BadRequest or Refused, with the reason in why, for
   the response's meta. *)
PROCEDURE Parse*(url: ARRAY OF CHAR; VAR r: Request; VAR why: ARRAY OF CHAR): INTEGER;
  VAR n, i, j, h, end, m: LONGINT; d: URL;
BEGIN
  why[0] := 0X;
  r.scheme := ""; r.host := ""; r.port := DefaultPort; r.path := "/"; r.rawPath := "";
  r.hasQuery := FALSE; r.query := "";
  n := Length(url);
  IF n > MaxURL THEN RETURN Fail(why, "the URL is over 1024 bytes") END;
  IF n = 0 THEN RETURN Fail(why, "no URL") END;
  i := 0;
  WHILE i < n DO
    IF ~UrlChar(url[i]) THEN RETURN Fail(why, "a character not allowed in a URL") END;
    IF url[i] = "#" THEN RETURN Fail(why, "a fragment") END;
    INC(i)
  END;
  IF ~Utf8(url, n) THEN RETURN Fail(why, "the URL is not UTF-8") END;

  (* scheme ":" *)
  i := 0;
  WHILE (i < n) & (Alpha(url[i]) OR (i > 0) & (Digit(url[i]) OR (url[i] = "+")
      OR (url[i] = "-") OR (url[i] = "."))) DO
    INC(i)
  END;
  IF (i = 0) OR (i = n) OR (url[i] # ":") THEN RETURN Fail(why, "not an absolute URL") END;
  IF i >= LEN(r.scheme) THEN RETURN Fail(why, "the scheme is too long") END;
  j := 0; WHILE j < i DO r.scheme[j] := Lower(url[j]); INC(j) END;
  r.scheme[i] := 0X;
  IF r.scheme # "gemini" THEN
    COPY("only gemini: URLs are served here", why); RETURN Refused
  END;

  (* "//" authority *)
  INC(i);
  IF (i + 1 >= n) OR (url[i] # "/") OR (url[i + 1] # "/") THEN RETURN Fail(why, "no host") END;
  INC(i, 2);
  end := i; WHILE (end < n) & (url[end] # "/") & (url[end] # "?") DO INC(end) END;
  j := i; WHILE (j < end) & (url[j] # "@") DO INC(j) END;
  IF j < end THEN RETURN Fail(why, "userinfo in the URL") END;

  (* host *)
  IF (i < end) & (url[i] = "[") THEN
    (* An IP literal: an IPv6 address, kept as written, lower case. *)
    j := i + 1;
    WHILE (j < end) & ((Hex(url[j]) >= 0) OR (url[j] = ":") OR (url[j] = ".")) DO INC(j) END;
    (* j - i > LEN(r.host): its text, j - i - 1 bytes, wouldn't fit with
       its 0X; no address is that long, and copying it would halt. *)
    IF (j = end) OR (url[j] # "]") OR (j = i + 1) OR (j - i > LEN(r.host)) THEN
      RETURN Fail(why, "a malformed IPv6 address")
    END;
    h := 0; m := i + 1; WHILE m < j DO r.host[h] := Lower(url[m]); INC(h); INC(m) END;
    r.host[h] := 0X;
    i := j + 1
  ELSE
    j := i;
    WHILE (j < end) & (url[j] # ":") DO
      IF (url[j] = "[") OR (url[j] = "]") THEN RETURN Fail(why, "a malformed host") END;
      INC(j)
    END;
    IF j - i >= LEN(r.host) THEN RETURN Fail(why, "the host is too long") END;
    IF ~DecodePart(url, i, j, d, m) THEN RETURN Fail(why, "bad percent-encoding in the host") END;
    h := 0;
    WHILE h < m DO
      IF (d[h] <= " ") OR (d[h] = 7FX) OR (d[h] = "/") THEN RETURN Fail(why, "a malformed host") END;
      r.host[h] := Lower(d[h]); INC(h)
    END;
    IF ~Utf8(d, m) THEN RETURN Fail(why, "the host is not UTF-8") END;
    (* "example.org." is "example.org" *)
    IF (h > 1) & (r.host[h - 1] = ".") THEN DEC(h) END;
    r.host[h] := 0X;
    i := j
  END;
  IF r.host = "" THEN RETURN Fail(why, "no host") END;

  (* ":" port, empty meaning the default *)
  IF i < end THEN
    IF url[i] # ":" THEN RETURN Fail(why, "a malformed host") END;
    INC(i);
    IF i < end THEN
      r.port := 0;
      WHILE i < end DO
        IF ~Digit(url[i]) THEN RETURN Fail(why, "a malformed port") END;
        r.port := r.port * 10 + ORD(url[i]) - ORD("0");
        IF r.port > 65535 THEN RETURN Fail(why, "a malformed port") END;
        INC(i)
      END
    END
  END;

  (* path, then "?" query *)
  end := i; WHILE (end < n) & (url[end] # "?") DO INC(end) END;
  j := 0; WHILE i + j < end DO r.rawPath[j] := url[i + j]; INC(j) END;
  r.rawPath[j] := 0X;
  IF ~Path(url, i, end, r, why) THEN RETURN BadRequest END;
  IF end < n THEN
    r.hasQuery := TRUE;
    j := 0; i := end + 1; WHILE i < n DO r.query[j] := url[i]; INC(i); INC(j) END;
    r.query[j] := 0X;
    IF ~Decode(r.query, d, m) THEN RETURN Fail(why, "bad percent-encoding in the query") END
  END;
  RETURN Ok
END Parse;

END GemRequest.
