MODULE GemAccess; (* Paths that need a client certificate *)

(* A capsule's requires (GemConfig) name the paths that need a client
   certificate, and perhaps which ones. A request within one is refused
   with:

   - 60 if it came with no certificate;
   - 62 if its certificate is outside its dates, now: libtls checks
     nothing of a client's certificate (Gemini's are self-signed, so the
     server accepts any), so the server checks the dates itself;
   - 61 if the require lists identities and the certificate's hash is
     none of them.

   Every require the path is within applies, so nesting one inside
   another can only narrow who is let in. A certificate need be valid only
   where one is required: elsewhere it is only logged.

   GemFiles checks again with the path a file really has, once symbolic
   links are resolved, so a link can't lead into a require from outside
   it. A hard link can: whoever makes one could copy the file as well. *)

IMPORT Instants, Clocks, GemServer, GemConfig;

(* 0 if x may have path, in capsule k; if not, the status that refuses
   it, with its meta, and x is left as it was, as for a directory's
   listing, which leaves out what x may not have (GemFiles). *)
PROCEDURE Refusal*(x: GemServer.Exchange; k: GemConfig.Capsule; path: ARRAY OF CHAR;
    VAR meta: ARRAY OF CHAR): INTEGER;
  VAR i, j: INTEGER; a: GemConfig.Area; t: Instants.Instant; now: HUGEINT;
BEGIN
  FOR i := 0 TO k.nAreas - 1 DO
    a := k.areas[i];
    IF GemConfig.Within(path, a.path) THEN
      IF x.certHash = NIL THEN COPY("client certificate required", meta); RETURN 60 END;
      Clocks.Now(t); now := Instants.UnixSeconds(t);
      IF (x.notBefore < 0) OR (now < x.notBefore) OR (now > x.notAfter) THEN
        COPY("certificate not valid", meta); RETURN 62
      END;
      IF a.nIds > 0 THEN
        j := 0; WHILE (j < a.nIds) & (a.ids[j] # x.certHash^) DO INC(j) END;
        IF j = a.nIds THEN COPY("certificate not authorised", meta); RETURN 61 END
      END
    END
  END;
  meta[0] := 0X;
  RETURN 0
END Refusal;

(* Whether x may have path, in capsule k; if not, x has its header. *)
PROCEDURE Allowed*(x: GemServer.Exchange; k: GemConfig.Capsule; path: ARRAY OF CHAR): BOOLEAN;
  VAR meta: ARRAY 64 OF CHAR; status: INTEGER;
BEGIN
  status := Refusal(x, k, path, meta);
  IF status = 0 THEN RETURN TRUE END;
  IF x.Header(status, meta) THEN END;
  RETURN FALSE
END Allowed;

END GemAccess.
