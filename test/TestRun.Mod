MODULE TestRun; (* Running the server: stopping, its limit, its log, its user *)

(* Starts build/pogemini, with the tests' self-signed pair, and checks:

   - SIGTERM, with a client in the middle of its exchange (handshake
     made, request not yet sent): a new client is refused at once, the
     one in progress is still answered, and the server then exits 0,
     logging "stopping" and "stopped";
   - SIGINT with nothing in progress: it exits 0 at once;
   - -connections 1: while a client that says nothing holds the one
     connection, the next waits until it goes; with -connections 2 it
     doesn't wait;
   - every line of the log after the port begins with the time, UTC,
     as 2026-11-16T12:34:56Z;
   - -user: not root, the user it is serves, root and an unknown user
     stop it; as root, it refuses to start without -user;
   - allow and deny: "deny 127.0.0.1" refuses that client before its
     handshake, logging it, and serves ::1; "allow localhost" then "deny
     all" serves both, as the name's addresses, and still does after a
     refresh; "deny localhost" refuses both; a name that doesn't
     resolve stops the server as it starts. The configurations are
     written into ../build/test-run. *)

IMPORT Out, Platform, Tasks, Sockets, SocketTasks, Check, Child, GemClient, UnixUsers;

CONST
  Certs = "../build/certs/";
  StackSize = 1024 * 1024;  (* see TestServe *)
  CR = 0DX; LF = 0AX;
  Hold = 1000;   (* ms the silent client holds the one connection *)

TYPE
  Text = ARRAY 2048 OF CHAR;
  (* what a Test task does *)
  Test = POINTER TO RECORD (Tasks.TaskDesc)
    kind: INTEGER;
    v4, v6: BOOLEAN;   (* Rules: whether 127.0.0.1 and ::1 are to be served *)
    label: Text;
    wait: LONGINT      (* Rules: ms to wait first *)
  END;
  Closer = POINTER TO RECORD (Tasks.TaskDesc) s: Sockets.Socket END;

CONST
  Term = 1; Limited = 2; Unlimited = 3; Fetch = 4; Rules = 5;

VAR
  server: Child.Child;
  port: INTEGER; portText: ARRAY 8 OF CHAR;
  got: ARRAY 65536 OF CHAR; gotLen: LONGINT;

PROCEDURE Length(s: ARRAY OF CHAR): LONGINT;
  VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END; RETURN n
END Length;

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := Length(s); j := 0;
  WHILE (i < LEN(s) - 1) & (j < LEN(t)) & (t[j] # 0X) DO s[i] := t[j]; INC(i); INC(j) END;
  s[i] := 0X
END Append;

(* Runs command to its end, with no input: its exit status, and its
   output, standard error included, in got. *)
PROCEDURE Run(command: ARRAY OF CHAR): INTEGER;
  VAR c: Child.Child;
BEGIN
  gotLen := 0; got[0] := 0X;
  IF ~Child.Spawn(command, "", 0, c) THEN RETURN -1 END;
  RETURN Child.Wait(c, got, gotLen)
END Run;

(* Whether every line of log but "port <n>" begins with the time, as
   2026-11-16T12:34:56Z and a space. *)
PROCEDURE Timed(VAR log: ARRAY OF CHAR): BOOLEAN;
  CONST form = "dddd-dd-ddTdd:dd:ddZ ";
  VAR f: ARRAY 24 OF CHAR; i, j: LONGINT; ok: BOOLEAN;
BEGIN
  f := form; i := 0; ok := TRUE;
  WHILE ok & (log[i] # 0X) DO
    IF log[i] # "p" THEN
      j := 0;
      WHILE ok & (f[j] # 0X) DO
        IF f[j] = "d" THEN ok := (log[i + j] >= "0") & (log[i + j] <= "9")
        ELSE ok := log[i + j] = f[j]
        END;
        INC(j)
      END
    END;
    WHILE (log[i] # 0X) & (log[i] # LF) DO INC(i) END;
    IF log[i] = LF THEN INC(i) END
  END;
  RETURN ok
END Timed;

(* Starts the server with args, and reads the port it listens on. *)
PROCEDURE Start(args: ARRAY OF CHAR): BOOLEAN;
  VAR cmd: Text; line: ARRAY 64 OF CHAR; i, n: LONGINT;
BEGIN
  cmd := "exec $POGEMINI_UNDER ../build/pogemini -port 0 -cert "; Append(cmd, Certs); Append(cmd, "self-ec.crt -key ");
  Append(cmd, Certs); Append(cmd, "self-ec.key "); Append(cmd, args);
  IF ~Child.Spawn(cmd, "", 0, server) OR ~Child.ReadLine(server, line, 15000) OR (line[0] # "p") THEN
    Check.Check(FALSE, "the server starts and says its port");
    Child.Kill(server); IF Child.Wait(server, got, n) # 0 THEN END;
    Out.String(line); Out.String(got); Out.Ln;
    RETURN FALSE
  END;
  i := 5; port := 0;
  WHILE (line[i] >= "0") & (line[i] <= "9") DO
    portText[i - 5] := line[i]; port := port * 10 + ORD(line[i]) - ORD("0"); INC(i)
  END;
  portText[i - 5] := 0X;
  RETURN TRUE
END Start;

(* The request for "/", and its length. *)
PROCEDURE Request(VAR req: ARRAY OF CHAR; VAR len: LONGINT);
BEGIN
  COPY("gemini://localhost:", req); Append(req, portText); Append(req, "/");
  len := Length(req); req[len] := CR; req[len + 1] := LF; req[len + 2] := 0X; INC(len, 2)
END Request;

(* r is complete, its header 20 text/gemini. *)
PROCEDURE Served(r: GemClient.Response): BOOLEAN;
  VAR h: ARRAY 32 OF CHAR;
BEGIN
  COPY("20 text/gemini", h);
  IF ~r.ok THEN Out.String("  error: "); Out.String(r.error); Out.Ln; RETURN FALSE END;
  IF ~Check.Contains(r.data^, h) THEN Out.String("  response: "); Out.String(r.data^); Out.Ln; RETURN FALSE END;
  RETURN TRUE
END Served;

(* r served if served, else refused: no response at all. *)
PROCEDURE Admitted(r: GemClient.Response; served: BOOLEAN): BOOLEAN;
BEGIN
  IF served THEN RETURN Served(r) END;
  IF r.ok OR (r.len # 0) THEN Out.String("  response: "); Out.String(r.data^); Out.Ln; RETURN FALSE END;
  RETURN TRUE
END Admitted;

PROCEDURE (c: Closer) Run*;
BEGIN Tasks.Sleep(Hold); Sockets.Close(c.s)
END Run;

PROCEDURE (t: Test) Run*;
  VAR c: GemClient.Conn; r: GemClient.Response; tcp: Sockets.Socket; err: Sockets.Error;
    req: Text; error: ARRAY 256 OF CHAR; len, start, n: LONGINT; closer: Closer;
BEGIN
  Request(req, len);
  IF t.kind = Term THEN
    IF ~GemClient.Open("127.0.0.1", port, "", "", c, error) THEN
      Check.Check(FALSE, "a client connects"); Out.String("  "); Out.String(error); Out.Ln;
      Child.Kill(server); RETURN
    END;
    Child.Kill(server);
    Tasks.Sleep(600);
    Check.Check(~SocketTasks.Connect("127.0.0.1", port, 1000, tcp, err),
      "SIGTERM: a new client is refused (127.0.0.1)");
    Check.Check(~SocketTasks.Connect("::1", port, 1000, tcp, err), "  ... (::1)");
    Check.Check(GemClient.Send(c, req, len, error) & Served(GemClient.Receive(c)),
      "  ... the one in progress is answered");
    GemClient.Close(c)
  ELSIF (t.kind = Limited) OR (t.kind = Unlimited) THEN
    IF ~SocketTasks.Connect("127.0.0.1", port, 1000, tcp, err) THEN
      Check.Check(FALSE, "a silent client connects"); Out.String("  "); Out.String(err.text); Out.Ln;
      RETURN
    END;
    Tasks.Sleep(300);  (* so the server has accepted it first *)
    NEW(closer); closer.s := tcp; Tasks.Start(closer, StackSize);
    start := Platform.Time();
    r := GemClient.Fetch("127.0.0.1", port, req, len, "", "");
    n := Platform.Time() - start;
    IF t.kind = Limited THEN
      Check.Check(Served(r), "-connections 1: a second client is served");
      Check.Check((n >= Hold - 400) & (n < GemClient.Deadline), "  ... once the first has gone")
    ELSE
      Check.Check(Served(r), "-connections 2: a second client is served");
      Check.Check(n < Hold - 400, "  ... at once")
    END;
    Tasks.Join(closer)
  ELSIF t.kind = Rules THEN
    IF t.wait > 0 THEN Tasks.Sleep(t.wait) END;
    Check.Check(Admitted(GemClient.Fetch("127.0.0.1", port, req, len, "", ""), t.v4), t.label);
    Check.Check(Admitted(GemClient.Fetch("::1", port, req, len, "", ""), t.v6), "  ... ::1")
  ELSE
    Check.Check(Served(GemClient.Fetch("127.0.0.1", port, req, len, "", "")), "  ... and serves")
  END
END Run;

(* Writes the configuration file name in ../build/test-run: text, each
   "|" a line feed, by printf. *)
PROCEDURE Config(name, text: ARRAY OF CHAR);
  VAR cmd: Text; i, j: LONGINT;
BEGIN
  cmd := "printf '"; i := Length(cmd); j := 0;
  WHILE text[j] # 0X DO
    IF text[j] = "|" THEN cmd[i] := "\"; cmd[i + 1] := "n"; INC(i, 2)
    ELSE cmd[i] := text[j]; INC(i)
    END;
    INC(j)
  END;
  cmd[i] := 0X; Append(cmd, "' > ../build/test-run/"); Append(cmd, name);
  IF Platform.System(cmd) # 0 THEN Check.Check(FALSE, cmd) END
END Config;

(* With the server started already: fetches from 127.0.0.1 and ::1,
   after wait ms, served or refused as v4 and v6 say. *)
PROCEDURE DriveRules(v4, v6: BOOLEAN; wait: LONGINT; label: ARRAY OF CHAR);
  VAR t: Test;
BEGIN
  NEW(t); t.kind := Rules; t.v4 := v4; t.v6 := v6; t.wait := wait; COPY(label, t.label);
  Tasks.Start(t, StackSize); Tasks.Join(t)
END DriveRules;

(* Runs a Test of kind against the server started already. *)
PROCEDURE Drive(kind: INTEGER);
  VAR t: Test;
BEGIN NEW(t); t.kind := kind; Tasks.Start(t, StackSize); Tasks.Join(t)
END Drive;

PROCEDURE Main;
  VAR log: ARRAY 65536 OF CHAR; n: LONGINT; status: INTEGER; args: Text;
BEGIN
  (* a client the server refuses may write its ClientHello after the
     server has closed the connection *)
  Sockets.IgnoreBrokenPipe;
  IF Start("-deadline 5000") THEN
    Drive(Term);
    Check.Check(Child.Wait(server, log, n) = 0, "  ... and the server exits 0");
    Out.String(log);
    Check.Check(Check.Contains(log, " stopping on signal 15, connections in progress: 1")
      & Check.Contains(log, " stopped"), "  ... logging that it stops, and has");
    Check.Check(Check.Contains(log, " 127.0.0.1 20 gemini://localhost:"), "  ... and the one answered");
    Check.Check(Timed(log), "the log: each line begins with the time")
  END;

  IF Start("") THEN
    Child.Interrupt(server);
    Check.Check(Child.Wait(server, log, n) = 0, "SIGINT, nothing in progress: the server exits 0");
    Out.String(log);
    Check.Check(Check.Contains(log, " stopping on signal 2, connections in progress: 0"), "  ... logging it")
  END;

  IF Start("-connections 1 -n 2 -deadline 5000") THEN
    Drive(Limited);
    Check.Check(Child.Wait(server, log, n) = 0, "  ... and the server exits 0");
    Out.String(log);
    Check.Check(Check.Contains(log, " 127.0.0.1 failed: "), "  ... the silent one logged as failed")
  END;
  IF Start("-connections 2 -n 2 -deadline 5000") THEN
    Drive(Unlimited);
    Check.Check(Child.Wait(server, log, n) = 0, "  ... and the server exits 0")
  END;

  IF UnixUsers.Root() THEN
    status := Run("exec $POGEMINI_UNDER ../build/pogemini -port 0 -n 1 -cert ../build/certs/self-ec.crt -key ../build/certs/self-ec.key");
    Check.Check((status = 1) & Check.Contains(got, "started as root: give -user"),
      "as root without -user: refuses to start");
    Check.Skip("-user root, not root: refused")
  ELSE
    Check.Skip("as root without -user: refuses to start");
    status := Run("exec $POGEMINI_UNDER ../build/pogemini -port 0 -n 1 -user root -cert ../build/certs/self-ec.crt -key ../build/certs/self-ec.key");
    Check.Check((status = 1) & Check.Contains(got, "pogemini: become root: only root can become another user"),
      "-user root, not root: refused");
    IF (status # 1) THEN Out.String(got) END;
    args := "-n 1 -user $(id -un)";
    IF Start(args) THEN
      Check.Check(TRUE, "-user, the user it is: starts");
      Drive(Fetch);
      Check.Check(Child.Wait(server, log, n) = 0, "  ... and exits 0")
    END
  END;
  IF Platform.System("rm -rf ../build/test-run && mkdir -p ../build/test-run") # 0 THEN
    Check.Check(FALSE, "make ../build/test-run")
  END;
  Config("deny", "deny 127.0.0.1|");
  IF Start("-n 2 -config ../build/test-run/deny") THEN
    DriveRules(FALSE, TRUE, 0, "deny 127.0.0.1: refused");
    Check.Check(Child.Wait(server, log, n) = 0, "  ... and the server exits 0, the refused one counted");
    Out.String(log);
    Check.Check(Check.Contains(log, " 127.0.0.1 refused") & Check.Contains(log, " ::1 20 gemini://localhost:")
      & ~Check.Contains(log, " 127.0.0.1 failed"), "  ... logged as refused, and ::1 as served")
  END;
  Config("allow", "refresh 1|allow localhost|deny all|");
  IF Start("-n 4 -config ../build/test-run/allow") THEN
    DriveRules(TRUE, TRUE, 0, "allow localhost, deny all: 127.0.0.1 served");
    DriveRules(TRUE, TRUE, 1500, "  ... and after a refresh");
    Check.Check(Child.Wait(server, log, n) = 0, "  ... and the server exits 0");
    Out.String(log);
    Check.Check(~Check.Contains(log, "refused") & ~Check.Contains(log, "allow localhost"),
      "  ... nothing refused, and no change or failure reported")
  END;
  Config("denyname", "deny localhost|");
  IF Start("-n 2 -config ../build/test-run/denyname") THEN
    DriveRules(FALSE, FALSE, 0, "deny localhost: 127.0.0.1 refused");
    Check.Check(Child.Wait(server, log, n) = 0, "  ... and the server exits 0")
  END;
  Config("nowhere", "allow nowhere.invalid|");
  status := Run("exec $POGEMINI_UNDER ../build/pogemini -port 0 -n 1 -config ../build/test-run/nowhere -cert ../build/certs/self-ec.crt -key ../build/certs/self-ec.key");
  Check.Check((status = 1) & Check.Contains(got, "pogemini: allow nowhere.invalid: "),
    "a rule's name that doesn't resolve: the server doesn't start");
  IF status # 1 THEN Out.String(got) END;
  IF Platform.System("rm -rf ../build/test-run") # 0 THEN END;

  status := Run("exec $POGEMINI_UNDER ../build/pogemini -port 0 -n 1 -user no-such-user-pogemini -cert ../build/certs/self-ec.crt -key ../build/certs/self-ec.key");
  Check.Check((status = 1) & Check.Contains(got, "pogemini: become no-such-user-pogemini: no such user"),
    "-user, an unknown user: refused");
  Check.Summary
END Main;

BEGIN
  Main
END TestRun.
