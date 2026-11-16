MODULE pogemini; (* A Gemini server *)

(* Usage: pogemini [-listen host] [-port port] [-deadline ms] [-n count]
                   -cert file -key file

   Serves one capsule with the certificate and key in the files given,
   on port (default 1965) at host (default: every local address, IPv6
   and IPv4). Its first line on standard output is "port <n>", the port
   it listens on, so a program that starts it on port 0 learns which
   the kernel chose; then a line per connection (GemServer). Each
   connection has ms (default 10000) for the whole exchange. With
   count, it serves that many connections, waits for them to end, and
   exits 0, for the tests; without, it serves until killed.

   Phase 1 (PLAN.md): every request is answered with the same page. *)

IMPORT Platform, Out, Err, Args, Sockets, Tls, GemServer;

CONST DefaultPort = 1965;

PROCEDURE Usage;
BEGIN
  Err.String("usage: pogemini [-listen host] [-port port] [-deadline ms] [-n count] -cert file -key file");
  Err.Ln; Platform.Exit(2)
END Usage;

PROCEDURE Fail(what, why: ARRAY OF CHAR);
BEGIN
  Err.String("pogemini: "); Err.String(what); Err.String(": "); Err.String(why); Err.Ln;
  Platform.Exit(1)
END Fail;

PROCEDURE Respond(x: GemServer.Exchange);
BEGIN
  IF x.Header(20, "text/gemini") & x.WriteString("# pogemini") & x.WriteString(0AX)
    & x.WriteString(0AX)
    & x.WriteString("This server is running, but serves no files yet.") & x.WriteString(0AX) THEN
  END
END Respond;

(* A server context with the key pair in cert and key, which accepts any
   client certificate: Gemini's are mostly self-signed identities. *)
PROCEDURE Context(cert, key: ARRAY OF CHAR): Tls.Context;
  VAR c: Tls.Config; ctx: Tls.Context;
BEGIN
  c := Tls.NewConfig();
  IF ~c.SetKeypairFile(cert, key) THEN Fail("certificate", c.error.text^) END;
  c.VerifyClientOptional; c.InsecureNoVerifyCert;
  ctx := Tls.NewServer();
  IF ~ctx.Configure(c) THEN Fail("certificate", ctx.error.text^) END;
  c.Close;
  RETURN ctx
END Context;

PROCEDURE Main;
  VAR arg, host, cert, key: ARRAY 1024 OF CHAR; port, deadline, count: LONGINT;
    i: INTEGER; s: GemServer.Server; err: Sockets.Error;
BEGIN
  host := ""; cert := ""; key := "";
  port := DefaultPort; deadline := GemServer.DefaultDeadline; count := 0;
  i := 1;
  WHILE i < Args.argc DO
    Args.Get(i, arg);
    IF i + 1 >= Args.argc THEN Usage
    ELSIF arg = "-listen" THEN Args.Get(i + 1, host)
    ELSIF arg = "-port" THEN port := -1; Args.GetInt(i + 1, port)
    ELSIF arg = "-deadline" THEN deadline := -1; Args.GetInt(i + 1, deadline)
    ELSIF arg = "-n" THEN count := -1; Args.GetInt(i + 1, count)
    ELSIF arg = "-cert" THEN Args.Get(i + 1, cert)
    ELSIF arg = "-key" THEN Args.Get(i + 1, key)
    ELSE Usage
    END;
    INC(i, 2)
  END;
  IF (cert = "") OR (key = "") OR (port < 0) OR (port > 65535) OR (deadline <= 0)
    OR (count < 0) THEN
    Usage
  END;
  s := GemServer.New(Context(cert, key), Respond);
  s.SetDeadline(deadline);
  IF ~s.Listen(host, SHORT(port), err) THEN Fail("listen", err.text) END;
  Out.String("port "); Out.Int(s.port, 0); Out.Ln;
  s.Serve(count)
END Main;

BEGIN
  Main
END pogemini.
