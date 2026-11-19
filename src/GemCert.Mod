MODULE GemCert; (* A self-signed certificate for a capsule given none *)

(* A capsule with neither certificate nor key gets a self-signed pair,
   made once, through polibtls's TlsMake, and kept, since Gemini
   clients pin the certificate they first see (TOFU): a new one at
   every start would look like an attack. It is kept in the
   certificate directory as <name>.crt and <name>.key, the key readable
   by its owner only, and is used as it is from then on.

   The pair is ECDSA P-256, signed with SHA-256, for the capsule's name
   and aliases (subject alternative names, which libtls matches SNI
   against), valid 3650 days from when it is made.

   TlsMake writes each file whole or not at all, the key first, so a
   pair is complete exactly when its .crt exists. A .key alone is what
   an interrupted run left, or a key the user put there, and is given
   its certificate; a .crt alone is refused, never replaced. *)

IMPORT Platform, Strings, Directories, Instants, Clocks, Tls, TlsMake, GemConfig;

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

PROCEDURE Exists(name: ARRAY OF CHAR): BOOLEAN;
  VAR id: Platform.FileIdentity;
BEGIN
  RETURN Platform.IdentifyByName(name, id) = 0
END Exists;

(* A file in dir: dir/name ext, in path. *)
PROCEDURE Join(dir, name, ext: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
BEGIN
  COPY(dir, path); Strings.Append("/", path); Strings.Append(name, path); Strings.Append(ext, path)
END Join;

(* Gives k a certificate and key in dir: the pair made before, or, if
   there is none, a new one. k must have a name, and neither cert nor
   key. FALSE, with why, if the pair can't be had. *)
PROCEDURE Ensure*(dir: ARRAY OF CHAR; k: GemConfig.Capsule; VAR why: ARRAY OF CHAR): BOOLEAN;
  VAR crt, key: GemConfig.Path; names: ARRAY 5000 OF CHAR; i: INTEGER;
    t: Instants.Instant; now: HUGEINT; error: Tls.String;
BEGIN
  ASSERT((k.name # "") & (k.cert = "") & (k.key = ""), 105);
  IF dir = "" THEN COPY("no directory for certificates", why); RETURN FALSE END;
  IF Strings.Length(dir) + Strings.Length(k.name) + 8 >= GemConfig.PathLen THEN
    COPY("the certificate directory's name is too long", why); RETURN FALSE
  END;
  Join(dir, k.name, ".crt", crt); Join(dir, k.name, ".key", key);
  IF Exists(crt) THEN
    IF ~Exists(key) THEN
      COPY(crt, why); Strings.Append(" has no key beside it", why); RETURN FALSE
    END;
    COPY(crt, k.cert); COPY(key, k.key); RETURN TRUE
  END;

  COPY(k.name, names);
  FOR i := 0 TO k.nAliases - 1 DO Strings.Append(" ", names); Strings.Append(k.aliases[i], names) END;
  IF Strings.Length(names) >= LEN(names) - 1 THEN COPY("too many names for a certificate", why); RETURN FALSE END;
  IF ~Directories.MakeDirectory(dir) THEN
    COPY("can't make the certificate directory ", why); Strings.Append(dir, why); RETURN FALSE
  END;
  IF ~Exists(key) & ~TlsMake.EcKey(key, error) THEN COPY(error^, why); RETURN FALSE END;
  Clocks.Now(t); now := Instants.UnixSeconds(t);
  IF ~TlsMake.SelfSigned(key, crt, k.name, names, FALSE, now, now + Days * 86400, error) THEN
    COPY(error^, why); RETURN FALSE
  END;
  COPY(crt, k.cert); COPY(key, k.key);
  RETURN TRUE
END Ensure;

END GemCert.
