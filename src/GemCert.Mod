MODULE GemCert; (* A self-signed certificate for a capsule given none *)

(* A capsule with neither certificate nor key gets a self-signed pair,
   made once and kept, since Gemini clients pin the certificate they
   first see (TOFU): a new one at every start would look like an
   attack. pogeminilib's GeminiIdentities.Ensure does it: kept in the
   certificate directory as <name>.crt and <name>.key, the key readable
   by its owner only; a certificate directory made there is its
   owner's only (700 octal), and one that exists is left as it is.

   The pair is ECDSA P-256, signed with SHA-256, for the capsule's name
   and aliases (subject alternative names, which libtls matches SNI
   against), valid 3650 days from when it is made. A .key alone is
   given its certificate; a .crt alone is refused, never replaced. *)

IMPORT Platform, Strings, GeminiIdentities, GemConfig;

CONST
  Days = 3650;   (* how long a certificate made here is valid *)

(* The directory certificates are kept in by default:
   $XDG_DATA_HOME/pogemini/certs, or $HOME/.local/share/pogemini/certs.
   FALSE if neither is set. *)
PROCEDURE DefaultDir*(VAR dir: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF Platform.getEnv("XDG_DATA_HOME", dir) & (dir # "") THEN
    Strings.Append("/pogemini/certs", dir); RETURN TRUE
  ELSIF Platform.getEnv("HOME", dir) & (dir # "") THEN
    Strings.Append("/.local/share/pogemini/certs", dir); RETURN TRUE
  END;
  RETURN FALSE
END DefaultDir;

(* Gives k a certificate and key in dir: the pair made before, or, if
   there is none, a new one. k must have a name, and neither cert nor
   key. FALSE, with why, if the pair can't be had. *)
PROCEDURE Ensure*(dir: ARRAY OF CHAR; k: GemConfig.Capsule; VAR why: ARRAY OF CHAR): BOOLEAN;
  VAR names: ARRAY 5000 OF CHAR; i: INTEGER; id: GeminiIdentities.Identity;
BEGIN
  ASSERT((k.name # "") & (k.cert = "") & (k.key = ""), 105);
  COPY(k.name, names);
  FOR i := 0 TO k.nAliases - 1 DO Strings.Append(" ", names); Strings.Append(k.aliases[i], names) END;
  IF Strings.Length(names) >= LEN(names) - 1 THEN COPY("too many names for a certificate", why); RETURN FALSE END;
  IF ~GeminiIdentities.Ensure(dir, k.name, names, Days, id, why) THEN RETURN FALSE END;
  COPY(id.certFile, k.cert); COPY(id.keyFile, k.key);
  RETURN TRUE
END Ensure;

END GemCert.
