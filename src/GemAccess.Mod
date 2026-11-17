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

(* Whether x may have path, in capsule k; if not, x has its header. *)
PROCEDURE Allowed*(x: GemServer.Exchange; k: GemConfig.Capsule; path: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: INTEGER; a: GemConfig.Area; t: Instants.Instant; now: HUGEINT;
BEGIN
  FOR i := 0 TO k.nAreas - 1 DO
    a := k.areas[i];
    IF GemConfig.Within(path, a.path) THEN
      IF x.certHash = NIL THEN
        IF x.Header(60, "client certificate required") THEN END; RETURN FALSE
      END;
      Clocks.Now(t); now := Instants.UnixSeconds(t);
      IF (x.notBefore < 0) OR (now < x.notBefore) OR (now > x.notAfter) THEN
        IF x.Header(62, "certificate not valid") THEN END; RETURN FALSE
      END;
      IF a.nIds > 0 THEN
        j := 0; WHILE (j < a.nIds) & (a.ids[j] # x.certHash^) DO INC(j) END;
        IF j = a.nIds THEN
          IF x.Header(61, "certificate not authorised") THEN END; RETURN FALSE
        END
      END
    END
  END;
  RETURN TRUE
END Allowed;

END GemAccess.
