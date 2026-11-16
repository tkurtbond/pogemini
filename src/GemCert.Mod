MODULE GemCert; (* A self-signed certificate for a capsule given none *)

(* A capsule with neither certificate nor key gets a self-signed pair,
   made once by running openssl (libtls can't make one) and kept, since
   Gemini clients pin the certificate they first see (TOFU): a new one
   at every start would look like an attack. It is kept in the
   certificate directory as <name>.crt and <name>.key, the key readable
   by its owner only, and is used as it is from then on.

   The pair is ECDSA P-256, signed with SHA-256, for the capsule's name
   and aliases (subject alternative names, which libtls matches SNI
   against), valid 3650 days. It is made as polibtls's
   test/make-certs.sh makes its own, with only what OpenSSL 3 and
   LibreSSL both have, and the digest named, since LibreSSL's would
   otherwise be SHA-1 for some commands, which GnuTLS rejects.

   The key is written under a temporary name and renamed last but one,
   the certificate last, so a pair is complete exactly when its .crt
   exists: a .key alone is what an interrupted run left, and is made
   again. A .crt alone is refused, never replaced. *)

IMPORT Platform, Strings, GemConfig;

CONST
  CmdLen = 16384;
  NotFound = 127;   (* the shell's status for a missing command *)

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

(* s appended to cmd in single quotes; s has none (Ensure checks). *)
PROCEDURE Quoted(s: ARRAY OF CHAR; VAR cmd: ARRAY OF CHAR);
BEGIN
  Strings.Append("'", cmd); Strings.Append(s, cmd); Strings.Append("'", cmd)
END Quoted;

(* A file in dir: dir/name ext, in path. *)
PROCEDURE Join(dir, name, ext: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
BEGIN
  COPY(dir, path); Strings.Append("/", path); Strings.Append(name, path); Strings.Append(ext, path)
END Join;

(* name as a subject alternative name, appended to san. *)
PROCEDURE AppendSan(name: ARRAY OF CHAR; VAR san: ARRAY OF CHAR);
BEGIN
  IF san # "" THEN Strings.Append(",", san) END;
  IF GemConfig.IsAddress(name) THEN Strings.Append("IP:", san) ELSE Strings.Append("DNS:", san) END;
  Strings.Append(name, san)
END AppendSan;

(* Gives k a certificate and key in dir: the pair made before, or, if
   there is none, a new one. k must have a name, and neither cert nor
   key. FALSE, with why, if the pair can't be had. *)
PROCEDURE Ensure*(dir: ARRAY OF CHAR; k: GemConfig.Capsule; VAR why: ARRAY OF CHAR): BOOLEAN;
  VAR crt, key: GemConfig.Path; san: ARRAY 5000 OF CHAR; cmd: ARRAY CmdLen OF CHAR;
    i, status: INTEGER;
BEGIN
  ASSERT((k.name # "") & (k.cert = "") & (k.key = ""), 105);
  IF dir = "" THEN COPY("no directory for certificates", why); RETURN FALSE END;
  IF Strings.Pos("'", dir, 0) >= 0 THEN
    COPY("a certificate directory with ' in its name", why); RETURN FALSE
  END;
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

  san := ""; AppendSan(k.name, san);
  FOR i := 0 TO k.nAliases - 1 DO AppendSan(k.aliases[i], san) END;
  cmd := "command -v openssl >/dev/null 2>&1 || exit 127; umask 077 && mkdir -p ";
  Quoted(dir, cmd); Strings.Append(" && cd ", cmd); Quoted(dir, cmd);
  Strings.Append(" && printf '[req]\ndistinguished_name = dn\n[dn]\n[x]\nbasicConstraints = critical,CA:FALSE\nsubjectAltName = ", cmd);
  Strings.Append(san, cmd); Strings.Append("\n' > ", cmd); Quoted(k.name, cmd); Strings.Append(".cnf.tmp", cmd);
  Strings.Append(" && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -out ", cmd);
  Quoted(k.name, cmd); Strings.Append(".key.tmp 2>/dev/null", cmd);
  Strings.Append(" && openssl req -config ", cmd); Quoted(k.name, cmd);
  Strings.Append(".cnf.tmp -new -x509 -sha256 -days 3650 -extensions x -subj /CN=", cmd);
  Quoted(k.name, cmd); Strings.Append(" -key ", cmd); Quoted(k.name, cmd);
  Strings.Append(".key.tmp -out ", cmd); Quoted(k.name, cmd);
  Strings.Append(".crt.tmp && chmod 644 ", cmd); Quoted(k.name, cmd);
  Strings.Append(".crt.tmp && mv -f ", cmd); Quoted(k.name, cmd); Strings.Append(".key.tmp ", cmd);
  Quoted(k.name, cmd); Strings.Append(".key && mv -f ", cmd); Quoted(k.name, cmd);
  Strings.Append(".crt.tmp ", cmd); Quoted(k.name, cmd);
  Strings.Append(".crt; s=$?; rm -f ", cmd); Quoted(k.name, cmd); Strings.Append(".cnf.tmp ", cmd);
  Quoted(k.name, cmd); Strings.Append(".key.tmp ", cmd); Quoted(k.name, cmd);
  Strings.Append(".crt.tmp; exit $s", cmd);
  IF Strings.Length(cmd) >= CmdLen - 1 THEN COPY("too many names for a certificate", why); RETURN FALSE END;

  status := Platform.System(cmd);
  IF status = NotFound * 256 THEN
    COPY("no certificate or key given, and openssl, which would make them, isn't on PATH", why);
    RETURN FALSE
  ELSIF (status # 0) OR ~Exists(crt) OR ~Exists(key) THEN
    COPY("openssl failed to make a certificate in ", why); Strings.Append(dir, why); RETURN FALSE
  END;
  COPY(crt, k.cert); COPY(key, k.key);
  RETURN TRUE
END Ensure;

END GemCert.
