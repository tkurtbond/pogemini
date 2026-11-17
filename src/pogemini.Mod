MODULE pogemini; (* A Gemini server *)

(* Usage: pogemini [-config file] [-listen host] [-port port]
                   [-deadline ms] [-connections n] [-user name]
                   [-certdir dir] [-n count]
                   [-host name]... [-root dir [-listings]]
                   [-cert file -key file] [-require path]...

   Serves the capsules in the configuration file (GemConfig gives its
   format), and one more given on the command line: its name is the
   first -host, any others its aliases, with -root, -listings (its
   directories without index.gmi listed, as listings in the file),
   -cert, -key and -require (a path that needs a client certificate;
   identities, which narrow which, are given only in the file), and
   it comes first, so it is the one a client that sends no SNI is shown.
   Without -host, that capsule serves any host, and needs -cert and
   -key. Options given here override the file's.

   A capsule given neither certificate nor key gets a self-signed pair
   (GemCert), made in the certificate directory (certdir, default
   $XDG_DATA_HOME/pogemini/certs or ~/.local/share/pogemini/certs) the
   first time and used from then on.

   It listens on port (default 1965) at host (default: every local
   address, IPv6 and IPv4). Its first line on standard output is
   "port <n>", the port it listens on, so a program that starts it on
   port 0 learns which the kernel chose; then a line per connection
   (GemServer). Each connection has ms (default 10000) for the whole
   exchange, and n connections (default 256) are served at once at
   most. With count, it serves that many connections, waits for them to
   end, and exits 0, for the tests; without, it serves until SIGTERM or
   SIGINT, then waits likewise and exits 0. A mistake in the
   configuration is reported on standard error and it exits 1; a
   mistake in the options, 2.

   Started as root, it becomes user (-user, or user in the file) once
   it has its key pairs and listens, so that it serves files as user;
   without one it refuses to run, since a server reading files as root
   is one mistake from serving any of them. -user root keeps root, for
   whoever really wants it. Not started as root, user may only name
   the user it is.

   A request is checked by GemRequest, and answered by the capsule its
   host names (by name or alias), or else by the one for any host. One
   that names none, or for a port other than the one listened on, is
   refused, 53: this server is no proxy.

   A request for a path inside one of the capsule's requires is refused
   without a client certificate fit for it (GemAccess). Otherwise, a
   capsule with a root serves the files under it (GemFiles); one
   without answers "/" with a page naming it, and anything else 51. *)

IMPORT Platform, Out, Err, Args, Strings, Directories, Sockets, Tls,
  UnixErrors, UnixUsers, GemServer, GemRequest, GemConfig, GemCert, GemFiles, GemAccess;

VAR
  config: GemConfig.Config;
  any: GemConfig.Capsule;   (* the capsule for any host, or NIL *)
  port: LONGINT;            (* listened on *)

PROCEDURE Usage;
BEGIN
  Err.String("usage: pogemini [-config file] [-listen host] [-port port] [-deadline ms]"); Err.Ln;
  Err.String("                [-connections n] [-user name] [-certdir dir] [-n count]"); Err.Ln;
  Err.String("                [-host name]... [-root dir [-listings]] [-cert file -key file]"); Err.Ln;
  Err.String("                [-require path]..."); Err.Ln;
  Platform.Exit(2)
END Usage;

PROCEDURE Fail(what, why: ARRAY OF CHAR);
BEGIN
  Err.String("pogemini: "); IF what # "" THEN Err.String(what); Err.String(": ") END;
  Err.String(why); Err.Ln;
  Platform.Exit(1)
END Fail;

(* The capsule that serves r, or NIL if this server serves it not. *)
PROCEDURE CapsuleFor(VAR r: GemRequest.Request): GemConfig.Capsule;
  VAR k: GemConfig.Capsule;
BEGIN
  IF r.port # port THEN RETURN NIL END;
  k := config.Find(r.host);
  IF k = NIL THEN k := any END;
  RETURN k
END CapsuleFor;

PROCEDURE Respond(x: GemServer.Exchange);
  VAR r: GemRequest.Request; why: ARRAY 128 OF CHAR; status: INTEGER;
    k: GemConfig.Capsule;
BEGIN
  status := GemRequest.Parse(x.request, r, why);
  IF status # GemRequest.Ok THEN
    IF x.Header(status, why) THEN END
  ELSE
    k := CapsuleFor(r);
    IF k = NIL THEN
      IF x.Header(GemRequest.Refused, "not served here") THEN END
    ELSIF ~GemAccess.Allowed(x, k, r.path) THEN  (* refused, with its header *)
    ELSIF k.root # "" THEN GemFiles.Serve(x, k, r)
    ELSIF r.path # "/" THEN
      IF x.Header(51, "not found") THEN END
    ELSIF x.Header(20, "text/gemini") & x.WriteString("# pogemini") & x.WriteString(0AX)
      & x.WriteString(0AX) THEN
      IF k.name = "" THEN
        IF x.WriteString("This capsule serves any host.") THEN END
      ELSIF x.WriteString("This capsule is ") & x.WriteString(k.name) & x.WriteString(".") THEN
      END;
      IF x.WriteString(0AX) & x.WriteString("It has no root, so it serves no files.") & x.WriteString(0AX) THEN END
    END
  END
END Respond;

(* Makes ready the capsules of config: a certificate and key for each,
   made in certdir if need be, and the root checked. *)
PROCEDURE Prepare(certdir: ARRAY OF CHAR);
  VAR i: INTEGER; k: GemConfig.Capsule; why: ARRAY GemConfig.ErrorLen OF CHAR;
    name: GemConfig.Name; real: GemConfig.Path;
BEGIN
  any := NIL;
  FOR i := 0 TO config.n - 1 DO
    k := config.capsules[i];
    IF k.name = "" THEN any := k; name := "the capsule for any host" ELSE name := k.name END;
    IF (k.cert = "") # (k.key = "") THEN
      Fail(name, "a certificate needs its key, and a key its certificate")
    ELSIF k.cert = "" THEN
      IF k.name = "" THEN Fail(name, "it needs -cert and -key") END;
      IF certdir = "" THEN
        Fail(name, "no certificate or key given, and no certdir, HOME or XDG_DATA_HOME to make them in")
      END;
      IF ~GemCert.Ensure(certdir, k, why) THEN Fail(name, why) END
    END;
    IF k.root # "" THEN
      IF ~Directories.IsDirectory(k.root) THEN
        COPY(k.root, why); Strings.Append(" is not a directory", why); Fail(name, why)
      ELSIF ~GemFiles.Resolve(k.root, real) THEN
        COPY(k.root, why); Strings.Append(" can't be resolved to a path", why); Fail(name, why)
      END;
      COPY(real, k.root)
    END
  END
END Prepare;

(* A server context with every capsule's key pair, the first the one a
   client without SNI is shown, which accepts any client certificate:
   Gemini's are mostly self-signed identities. libtls presents the pair
   whose certificate names the host a client's SNI asks for. *)
PROCEDURE Context(): Tls.Context;
  VAR c: Tls.Config; ctx: Tls.Context; i: INTEGER; k: GemConfig.Capsule; ok: BOOLEAN;
BEGIN
  c := Tls.NewConfig();
  FOR i := 0 TO config.n - 1 DO
    k := config.capsules[i];
    IF i = 0 THEN ok := c.SetKeypairFile(k.cert, k.key)
    ELSE ok := c.AddKeypairFile(k.cert, k.key)
    END;
    IF ~ok THEN Fail(k.cert, c.error.text^) END
  END;
  c.VerifyClientOptional; c.InsecureNoVerifyCert;
  ctx := Tls.NewServer();
  IF ~ctx.Configure(c) THEN Fail("certificate", ctx.error.text^) END;
  c.Close;
  RETURN ctx
END Context;

PROCEDURE Main;
  VAR arg, value, file, cert, key, root, certdir: GemConfig.Path;
    why: ARRAY GemConfig.ErrorLen OF CHAR;
    hosts: ARRAY GemConfig.MaxAliases + 1 OF GemConfig.Name;
    requires: ARRAY GemConfig.MaxAreas OF GemConfig.Path;
    count, x: LONGINT; i, j, nHosts, nRequires: INTEGER; listings: BOOLEAN;
    k: GemConfig.Capsule; a: GemConfig.Area; s: GemServer.Server; err: Sockets.Error;
    uerr: UnixErrors.Error;
BEGIN
  config := GemConfig.New();
  (* the file first, so the options can override it *)
  file := ""; i := 1;
  WHILE i < Args.argc DO
    Args.Get(i, arg);
    IF arg = "-listings" THEN INC(i)  (* the one option without a value *)
    ELSE
      IF i + 1 >= Args.argc THEN Usage END;
      IF arg = "-config" THEN Args.Get(i + 1, file) END;
      INC(i, 2)
    END
  END;
  IF (file # "") & ~GemConfig.Read(config, file, why) THEN Fail("", why) END;

  cert := ""; key := ""; root := ""; certdir := config.certdir; nHosts := 0; nRequires := 0; count := 0;
  listings := FALSE;
  i := 1;
  WHILE i < Args.argc DO
    Args.Get(i, arg); value := "";
    IF arg = "-listings" THEN
      listings := TRUE; DEC(i)  (* it has no value: the INC below passes it alone *)
    ELSE Args.Get(i + 1, value)
    END;
    IF arg = "-listings" THEN
    ELSIF arg = "-config" THEN
    ELSIF arg = "-host" THEN
      IF nHosts = LEN(hosts) THEN Usage END;
      COPY(value, hosts[nHosts]); INC(nHosts)
    ELSIF arg = "-listen" THEN COPY(value, config.listen)
    ELSIF arg = "-port" THEN
      IF ~GemConfig.Number(value, 0, 65535, x) THEN Usage END; config.port := x
    ELSIF arg = "-deadline" THEN
      IF ~GemConfig.Number(value, 1, 3600000, x) THEN Usage END; config.deadline := x
    ELSIF arg = "-connections" THEN
      IF ~GemConfig.Number(value, 1, GemConfig.MaxConnections, x) THEN Usage END; config.connections := x
    ELSIF arg = "-user" THEN
      IF Strings.Length(value) >= GemConfig.NameLen THEN Usage END; COPY(value, config.user)
    ELSIF arg = "-n" THEN
      IF ~GemConfig.Number(value, 0, 1000000000, count) THEN Usage END
    ELSIF arg = "-certdir" THEN COPY(value, certdir)
    ELSIF arg = "-root" THEN COPY(value, root)
    ELSIF arg = "-cert" THEN COPY(value, cert)
    ELSIF arg = "-key" THEN COPY(value, key)
    ELSIF arg = "-require" THEN
      IF nRequires = LEN(requires) THEN Usage END;
      COPY(value, requires[nRequires]); INC(nRequires)
    ELSE Usage
    END;
    INC(i, 2)
  END;
  IF listings & (root = "") THEN Fail("-listings", "it needs -root, whose directories it lists") END;
  IF (nHosts > 0) OR (cert # "") OR (key # "") OR (root # "") OR (nRequires > 0) THEN
    IF nHosts = 0 THEN hosts[0] := "" END;
    IF ~config.Add(hosts[0], TRUE, k, why) THEN Fail("-host", why) END;
    FOR j := 1 TO nHosts - 1 DO
      IF ~config.AddAlias(k, hosts[j], why) THEN Fail("-host", why) END
    END;
    k.cert := cert; k.key := key; k.root := root; k.listings := listings;
    FOR j := 0 TO nRequires - 1 DO
      IF ~GemConfig.AddArea(k, requires[j], a, why) THEN Fail("-require", why) END
    END
  END;
  IF config.n = 0 THEN Usage END;
  IF config.port < 0 THEN config.port := GemConfig.DefaultPort END;
  IF config.deadline < 0 THEN config.deadline := GemConfig.DefaultDeadline END;
  IF config.connections < 0 THEN config.connections := GemServer.DefaultLimit END;
  IF (config.user = "") & UnixUsers.Root() THEN
    Fail("", "started as root: give -user, a user to serve files as (-user root to stay root)")
  END;
  IF (certdir = "") & ~GemCert.DefaultDir(certdir) THEN certdir := "" END;

  Prepare(certdir);
  s := GemServer.New(Context(), Respond);
  s.SetDeadline(config.deadline); s.SetLimit(config.connections);
  IF ~s.Listen(config.listen, SHORT(config.port), err) THEN Fail("listen", err.text) END;
  IF (config.user # "") & ~UnixUsers.Become(config.user, uerr) THEN Fail("", uerr.text) END;
  port := s.port;
  Out.String("port "); Out.Int(s.port, 0); Out.Ln;
  s.Serve(count)
END Main;

BEGIN
  Main
END pogemini.
