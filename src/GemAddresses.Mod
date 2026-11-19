MODULE GemAddresses; (* IP addresses and ranges, for allow and deny *)

(* An address as 16 bytes, an IPv6 address's: an IPv4 address is held
   as IPv4-mapped (::ffff:192.0.2.1), so one comparison serves both
   families, and a client the kernel gives as ::ffff:192.0.2.1 matches
   a rule written 192.0.2.1. A range is an address and how many of its
   leading bits count; an IPv4 range's prefix gains the mapped prefix's
   96. pogemini reads addresses from the configuration and from
   posockets' Sockets.Address, which is text ("192.0.2.1",
   "2001:db8::1", "fe80::1%eth0"), so this parses text, and is pure
   Oberon: no inet_pton, which posockets doesn't bind. A zone ("%eth0")
   is dropped: a rule names addresses, not interfaces. *)

CONST
  Len* = 16;  (* bytes in an address *)

TYPE
  Address* = ARRAY Len OF INTEGER;  (* bytes, 0..255, network order *)
  Range* = RECORD
    a*: Address;     (* its bits past bits are 0 *)
    bits*: INTEGER   (* 0..128: 0 is every address *)
  END;

PROCEDURE IsDigit(ch: CHAR): BOOLEAN;
BEGIN RETURN (ch >= "0") & (ch <= "9")
END IsDigit;

(* ch's value as a hex digit, or -1. *)
PROCEDURE Hex(ch: CHAR): INTEGER;
BEGIN
  IF IsDigit(ch) THEN RETURN ORD(ch) - ORD("0")
  ELSIF (ch >= "a") & (ch <= "f") THEN RETURN ORD(ch) - ORD("a") + 10
  ELSIF (ch >= "A") & (ch <= "F") THEN RETURN ORD(ch) - ORD("A") + 10
  ELSE RETURN -1
  END
END Hex;

(* s[i..] as dotted IPv4, four decimal parts 0..255 with no leading
   zero (010 is octal to inet_aton, so it is refused rather than
   guessed at), up to end, the index after it, into b[0..3]. *)
PROCEDURE V4(s: ARRAY OF CHAR; i: LONGINT; VAR b: ARRAY OF INTEGER; VAR end: LONGINT): BOOLEAN;
  VAR part, digits, v: INTEGER;
BEGIN
  FOR part := 0 TO 3 DO
    IF part > 0 THEN
      IF s[i] # "." THEN RETURN FALSE END;
      INC(i)
    END;
    v := 0; digits := 0;
    WHILE IsDigit(s[i]) & (digits < 4) DO v := v * 10 + ORD(s[i]) - ORD("0"); INC(i); INC(digits) END;
    IF (digits = 0) OR (digits > 3) OR (v > 255) OR (digits > 1) & (s[i - digits] = "0") THEN
      RETURN FALSE
    END;
    b[part] := v
  END;
  end := i;
  RETURN TRUE
END V4;

(* s as IPv6 text: eight groups of one to four hex digits, one run of
   them shortened to "::", and the last two perhaps as dotted IPv4. *)
PROCEDURE V6(s: ARRAY OF CHAR; VAR a: Address): BOOLEAN;
  VAR g: ARRAY 8 OF LONGINT; b: ARRAY 4 OF INTEGER;
    n, gap, i, j, v, digits, k, end: LONGINT;
BEGIN
  n := 0; gap := -1; i := 0;
  IF s[0] = ":" THEN
    IF s[1] # ":" THEN RETURN FALSE END;
    gap := 0; i := 2
  END;
  LOOP
    IF s[i] = 0X THEN  (* only just after "::" *)
      IF (gap # n) OR (i = 0) THEN RETURN FALSE END;
      EXIT
    END;
    j := i; v := 0; digits := 0;
    WHILE (Hex(s[j]) >= 0) & (digits < 5) DO v := v * 16 + Hex(s[j]); INC(j); INC(digits) END;
    IF s[j] = "." THEN  (* dotted IPv4, the last two groups *)
      IF (n > 6) OR ~V4(s, i, b, end) OR (s[end] # 0X) THEN RETURN FALSE END;
      g[n] := b[0] * 256 + b[1]; g[n + 1] := b[2] * 256 + b[3]; INC(n, 2);
      EXIT
    END;
    IF (digits = 0) OR (digits > 4) OR (n = 8) THEN RETURN FALSE END;
    g[n] := v; INC(n); i := j;
    IF s[i] = 0X THEN EXIT
    ELSIF s[i] # ":" THEN RETURN FALSE
    ELSIF s[i + 1] = ":" THEN
      IF gap >= 0 THEN RETURN FALSE END;
      gap := n; INC(i, 2)
    ELSE
      INC(i);
      IF s[i] = 0X THEN RETURN FALSE END
    END
  END;
  IF (gap < 0) & (n # 8) OR (gap >= 0) & (n > 7) THEN RETURN FALSE END;
  FOR k := 0 TO Len - 1 DO a[k] := 0 END;
  IF gap < 0 THEN gap := n END;
  FOR k := 0 TO gap - 1 DO a[2 * k] := SHORT(g[k] DIV 256); a[2 * k + 1] := SHORT(g[k] MOD 256) END;
  (* the groups after "::" go to the end *)
  FOR k := gap TO n - 1 DO
    j := 8 - n + k;
    a[2 * j] := SHORT(g[k] DIV 256); a[2 * j + 1] := SHORT(g[k] MOD 256)
  END;
  RETURN TRUE
END V6;

(* s, IPv4 or IPv6 text, as a; a zone after "%" is dropped. FALSE if s
   is neither. v4 says which it was written as. *)
PROCEDURE Parse2(s: ARRAY OF CHAR; VAR a: Address; VAR v4: BOOLEAN): BOOLEAN;
  VAR t: ARRAY 64 OF CHAR; b: ARRAY 4 OF INTEGER; i, end: LONGINT; colon: BOOLEAN;
BEGIN
  i := 0; colon := FALSE;
  WHILE (i < LEN(s)) & (s[i] # 0X) & (s[i] # "%") DO
    IF i = LEN(t) - 1 THEN RETURN FALSE END;  (* too long for any address *)
    t[i] := s[i]; IF s[i] = ":" THEN colon := TRUE END; INC(i)
  END;
  t[i] := 0X;
  (* a zone only on IPv6, and not empty *)
  IF (i < LEN(s)) & (s[i] = "%") & (~colon OR (i + 1 >= LEN(s)) OR (s[i + 1] = 0X)) THEN
    RETURN FALSE
  END;
  v4 := ~colon;
  IF colon THEN RETURN V6(t, a) END;
  IF ~V4(t, 0, b, end) OR (t[end] # 0X) THEN RETURN FALSE END;
  FOR i := 0 TO 9 DO a[i] := 0 END;
  a[10] := 255; a[11] := 255;
  FOR i := 0 TO 3 DO a[12 + i] := b[i] END;
  RETURN TRUE
END Parse2;

(* s, IPv4 or IPv6 text, as a; a zone ("%eth0") is dropped. *)
PROCEDURE Parse*(s: ARRAY OF CHAR; VAR a: Address): BOOLEAN;
  VAR v4: BOOLEAN;
BEGIN RETURN Parse2(s, a, v4)
END Parse;

(* Whether a is in r. *)
PROCEDURE In*(VAR a: Address; VAR r: Range): BOOLEAN;
  VAR i, rest: INTEGER;
BEGIN
  i := 0;
  WHILE i < r.bits DIV 8 DO
    IF a[i] # r.a[i] THEN RETURN FALSE END;
    INC(i)
  END;
  rest := r.bits MOD 8;
  IF rest = 0 THEN RETURN TRUE END;
  (* the high rest bits of a[i]; r.a[i]'s others are 0 *)
  RETURN (a[i] DIV ASH(1, 8 - rest)) * ASH(1, 8 - rest) = r.a[i]
END In;

(* s as a range: an address alone (every bit counts), or address/bits,
   bits 0..32 for IPv4 and 0..128 for IPv6, with no bit set in the
   address past them, since 192.0.2.1/24 is more likely a mistake than
   a way to write 192.0.2.0/24. FALSE, with why, if s is not one. *)
PROCEDURE ParseRange*(s: ARRAY OF CHAR; VAR r: Range; VAR why: ARRAY OF CHAR): BOOLEAN;
  VAR t: ARRAY 64 OF CHAR; i, j, bits, max: LONGINT; v4: BOOLEAN; full: Range;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) & (s[i] # "/") & (i < LEN(t) - 1) DO t[i] := s[i]; INC(i) END;
  t[i] := 0X;
  IF ~Parse2(t, r.a, v4) THEN COPY("not an address or range", why); RETURN FALSE END;
  IF v4 THEN max := 32 ELSE max := 128 END;
  IF (i < LEN(s)) & (s[i] = "/") THEN
    j := i + 1; bits := 0;
    WHILE (j < LEN(s)) & IsDigit(s[j]) & (bits <= max) DO bits := bits * 10 + ORD(s[j]) - ORD("0"); INC(j) END;
    IF (j = i + 1) OR (j < LEN(s)) & (s[j] # 0X) OR (bits > max) OR (j > i + 2) & (s[i + 1] = "0") THEN
      COPY("a range's prefix is 0 to 32 bits for IPv4, 0 to 128 for IPv6", why); RETURN FALSE
    END
  ELSIF (i < LEN(s)) & (s[i] # 0X) THEN COPY("not an address or range", why); RETURN FALSE
  ELSE bits := max
  END;
  IF v4 THEN INC(bits, 96) END;
  r.bits := SHORT(bits);
  (* r.a in r, with only r.bits counting, is r.a with its rest zero *)
  full := r; full.bits := 128;
  FOR i := r.bits DIV 8 + 1 TO Len - 1 DO full.a[i] := 0 END;
  IF r.bits MOD 8 # 0 THEN
    i := r.bits DIV 8;
    full.a[i] := SHORT((r.a[i] DIV ASH(1, 8 - r.bits MOD 8)) * ASH(1, 8 - r.bits MOD 8))
  ELSIF r.bits < 128 THEN full.a[r.bits DIV 8] := 0
  END;
  FOR i := 0 TO Len - 1 DO
    IF full.a[i] # r.a[i] THEN
      COPY("an address with bits set past its range's prefix", why); RETURN FALSE
    END
  END;
  RETURN TRUE
END ParseRange;

(* a as text: an IPv4-mapped address in dotted IPv4, any other as
   RFC 5952 writes IPv6: lower-case hex without leading zeros, the
   longest run of two or more zero groups (the first, of equals) as
   "::". *)
PROCEDURE Format*(VAR a: Address; VAR s: ARRAY OF CHAR);
  CONST hex = "0123456789abcdef";
  VAR h: ARRAY 17 OF CHAR; g: ARRAY 8 OF LONGINT; t: ARRAY 48 OF CHAR;
    i, j, k, best, bestLen, run, v: LONGINT; started: BOOLEAN;
  PROCEDURE Put(ch: CHAR);
  BEGIN t[j] := ch; INC(j)
  END Put;
  PROCEDURE Dec(n: INTEGER);
  BEGIN
    IF n >= 100 THEN Put(CHR(ORD("0") + n DIV 100)) END;
    IF n >= 10 THEN Put(CHR(ORD("0") + n DIV 10 MOD 10)) END;
    Put(CHR(ORD("0") + n MOD 10))
  END Dec;
BEGIN
  h := hex; j := 0;
  i := 0; WHILE (i < 10) & (a[i] = 0) DO INC(i) END;
  IF (i = 10) & (a[10] = 255) & (a[11] = 255) THEN
    FOR i := 12 TO 15 DO Dec(a[i]); IF i < 15 THEN Put(".") END END
  ELSE
    FOR i := 0 TO 7 DO g[i] := a[2 * i] * 256 + a[2 * i + 1] END;
    best := -1; bestLen := 1; i := 0;
    WHILE i < 8 DO
      run := 0; WHILE (i + run < 8) & (g[i + run] = 0) DO INC(run) END;
      IF run > bestLen THEN best := i; bestLen := run END;
      IF run > 0 THEN INC(i, run) ELSE INC(i) END
    END;
    i := 0;
    WHILE i < 8 DO
      IF i = best THEN
        Put(":"); IF i = 0 THEN Put(":") END;
        INC(i, bestLen)
      ELSE
        v := g[i]; started := FALSE;
        FOR k := 3 TO 0 BY -1 DO
          IF started OR (ASH(v, -4 * k) MOD 16 # 0) OR (k = 0) THEN
            Put(h[ASH(v, -4 * k) MOD 16]); started := TRUE
          END
        END;
        IF i < 7 THEN Put(":") END;
        INC(i)
      END
    END
  END;
  t[j] := 0X; COPY(t, s)
END Format;

(* Whether a and b are the same address. *)
PROCEDURE Same*(VAR a, b: Address): BOOLEAN;
  VAR i: INTEGER;
BEGIN
  i := 0; WHILE (i < Len) & (a[i] = b[i]) DO INC(i) END;
  RETURN i = Len
END Same;

(* The range of every address, IPv4 and IPv6. *)
PROCEDURE All*(VAR r: Range);
  VAR i: INTEGER;
BEGIN FOR i := 0 TO Len - 1 DO r.a[i] := 0 END; r.bits := 0
END All;

END GemAddresses.
