MODULE GemServer; (* Listeners, and a task per connection *)

(* The server's engine, from polibtls's examples/GeminiHello: a server
   listens on one port, IPv6 and IPv4, with an accept task per
   listener, and serves each connection in a task of its own (poc's
   cooperative Tasks), so one thread serves them all and a slow or
   stalled client holds up no other. Each connection has a deadline for
   the whole exchange, handshake to close_notify.

   A connection's task makes the TLS handshake, reads the request line
   and hands it, as an Exchange, to the server's Responder, which
   answers with Header and Write. Then the task ends the response with
   TLS close_notify, which is how a Gemini client knows it has the
   whole of it, drains the socket (SocketTasks.LingeringClose) and
   closes it, and logs one line on standard output, beginning with the
   time, UTC:

     <time> <client address> <status> <request> <client certificate | ->
     <time> <client address> failed: <why>

   The request is written with its control characters as %XX, so a line
   in the log is always one line.

   At most a server's limit of connections are served at once (SetLimit);
   at the limit, the next waits in the kernel's queue until one ends.

   SIGTERM or SIGINT stops it cleanly: it stops accepting, closes its
   listeners, so that a new client is refused at once, and waits for the
   connections in progress, which their deadline bounds, logging

     <time> stopping on signal <n>, connections in progress: <k>
     <time> stopped

   A second signal ends it at once. *)

IMPORT SYSTEM, Out, Tasks, Sockets, SocketTasks, Tls, TlsTasks;

CONST
  MaxRequest* = 1024;  (* a request's URL at most, by the specification *)
  MaxMeta* = 1024;     (* a response header's meta at most, likewise *)
  DefaultDeadline* = 10000;  (* ms a connection has, at most *)
  DefaultLimit* = 256;       (* connections at once, at most *)

  Tick = 200;          (* ms an accept waits before looking at stop *)
  Linger = 2000;       (* ms a closed connection is drained for *)
  CR = 0DX; LF = 0AX;

  (* Halt codes (PLAN.md, "Halt codes") *)
  BadStatus = 100;     (* Header: a status outside 10..69, or a second header *)
  MetaTooLong = 101;   (* Header: meta over MaxMeta bytes *)
  NoBody = 102;        (* Write: no 2x header first *)
  NoHeader = 103;      (* a Responder returned without a header *)
  NotListening = 104;  (* Serve before Listen *)

PROCEDURE ["C", "GemServer.-catch"] CCatch;
PROCEDURE ["C", "GemServer.-caught"] CCaught(): SYSTEM.INT32;
PROCEDURE ["C", "GemServer.-now"] CNow(VAR out: ARRAY OF CHAR; max: SYSTEM.INT64);

TYPE
  (* One connection's request, and its response so far. *)
  Exchange* = POINTER TO ExchangeDesc;
  ExchangeDesc* = RECORD
    peer-: Sockets.Address;   (* the client's *)
    request-: ARRAY MaxRequest + 1 OF CHAR;  (* the line, without CR LF *)
    certHash-: Tls.String;    (* the client certificate's, NIL for none *)
    notBefore-, notAfter-: HUGEINT;  (* its dates, seconds since 1970;
                                 -1 for none *)
    status-: INTEGER;         (* the header's, 0 until sent *)
    failed-: BOOLEAN;         (* a write failed; the rest do nothing *)
    conn: Tls.Connection
  END;

  (* Answers x.request: Header once, then, after a 2x header only, the
     body by Write. Called in the connection's task, so it may wait. *)
  Responder* = PROCEDURE (x: Exchange);

  Server* = POINTER TO ServerDesc;
  Handler = POINTER TO RECORD (Tasks.TaskDesc)
    server: Server;
    s: Sockets.Socket;
    peer: Sockets.Address;
    next: Handler
  END;
  Acceptor = POINTER TO RECORD (Tasks.TaskDesc)
    server: Server;
    l: Sockets.Socket
  END;
  ServerDesc* = RECORD
    port-: INTEGER;           (* listened on, once Listen succeeds *)
    ctx: Tls.Context;
    respond: Responder;
    deadline: LONGINT;
    limit, active: LONGINT;   (* connections at once: at most, now *)
    ended: Tasks.Condition;   (* signalled as each connection ends *)
    listeners: ARRAY 2 OF Sockets.Socket;
    n: INTEGER;               (* listeners *)
    count, accepted: LONGINT; (* connections to serve (0: no end), so far *)
    stop: BOOLEAN;
    handlers: Handler         (* the connections' tasks not yet seen done *)
  END;

PROCEDURE Length(s: ARRAY OF CHAR): LONGINT;
  VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END; RETURN n
END Length;

(* Starts a line of the log: the time, UTC, and a space. *)
PROCEDURE OutTime;
  VAR t: ARRAY 32 OF CHAR;
BEGIN CNow(t, LEN(t)); Out.String(t); Out.Char(" ")
END OutTime;

(* Writes the response header, status and meta, "" for none. *)
PROCEDURE (x: Exchange) Header*(status: INTEGER; meta: ARRAY OF CHAR): BOOLEAN;
  VAR h: ARRAY MaxMeta + 5 OF CHAR; i, n, m: LONGINT;
BEGIN
  ASSERT((x.status = 0) & (status >= 10) & (status <= 69), BadStatus);
  n := Length(meta);
  ASSERT(n <= MaxMeta, MetaTooLong);
  x.status := status;
  h[0] := CHR(ORD("0") + status DIV 10); h[1] := CHR(ORD("0") + status MOD 10);
  i := 2;
  IF n > 0 THEN h[2] := " "; i := 3; m := 0; WHILE m < n DO h[i] := meta[m]; INC(i); INC(m) END END;
  h[i] := CR; h[i + 1] := LF;
  IF ~x.failed & ~TlsTasks.WriteAll(x.conn, h, 0, i + 2, m) THEN x.failed := TRUE END;
  RETURN ~x.failed
END Header;

(* Writes buf[pos..pos+len-1] of the body. *)
PROCEDURE (x: Exchange) Write*(buf-: ARRAY OF CHAR; pos, len: LONGINT): BOOLEAN;
  VAR m: LONGINT;
BEGIN
  ASSERT(x.status DIV 10 = 2, NoBody);
  IF ~x.failed & ~TlsTasks.WriteAll(x.conn, buf, pos, len, m) THEN x.failed := TRUE END;
  RETURN ~x.failed
END Write;

(* Writes s, up to its 0X, of the body. *)
PROCEDURE (x: Exchange) WriteString*(s: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN x.Write(s, 0, Length(s))
END WriteString;

(* Reads the request line, up to the first CR LF, into x.request without
   them: FALSE if reading failed, or, with x.request "", if there was no
   CR LF in the first MaxRequest + 2 bytes. Anything after the CR LF is
   ignored. *)
PROCEDURE ReadRequest(x: Exchange): BOOLEAN;
  VAR buf: ARRAY MaxRequest + 2 OF CHAR; n, m, i: LONGINT;
BEGIN
  n := 0; i := 0; x.request[0] := 0X;
  LOOP
    IF ~TlsTasks.Read(x.conn, buf, n, LEN(buf) - n, m) THEN RETURN FALSE END;
    INC(n, m);
    WHILE (i < n - 1) & ~((buf[i] = CR) & (buf[i + 1] = LF)) DO INC(i) END;
    IF i < n - 1 THEN
      m := 0; WHILE m < i DO x.request[m] := buf[m]; INC(m) END;
      x.request[i] := 0X;
      RETURN TRUE
    ELSIF n = LEN(buf) THEN
      RETURN TRUE
    END
  END
END ReadRequest;

(* Writes s with its control characters as %XX. *)
PROCEDURE OutEscaped(s: ARRAY OF CHAR);
  CONST hex = "0123456789ABCDEF";
  VAR i: LONGINT; h: ARRAY 17 OF CHAR;
BEGIN
  h := hex; i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    IF (s[i] < " ") OR (s[i] = 7FX) THEN
      Out.Char("%"); Out.Char(h[ORD(s[i]) DIV 16]); Out.Char(h[ORD(s[i]) MOD 16])
    ELSE Out.Char(s[i])
    END;
    INC(i)
  END
END OutEscaped;

(* Serves one connection: handshake, request, response, close_notify,
   all within the server's deadline; then logs how it went. *)
PROCEDURE (h: Handler) Run*;
  VAR x: Exchange; ok, closed: BOOLEAN; s: Server;
BEGIN
  s := h.server; closed := FALSE;
  NEW(x); x.peer := h.peer; x.status := 0; x.failed := FALSE; x.certHash := NIL;
  x.notBefore := -1; x.notAfter := -1;
  IF ~s.ctx.AcceptSocket(h.s.fd, x.conn) THEN
    OutTime; Out.String(h.peer.host); Out.String(" failed: "); Out.String(s.ctx.error.text^); Out.Ln
  ELSE
    x.conn.SetDeadline(s.deadline);
    ok := TlsTasks.Handshake(x.conn) & ReadRequest(x);
    IF ok THEN
      x.certHash := x.conn.PeerCertHash();
      IF x.certHash # NIL THEN
        x.notBefore := x.conn.PeerCertNotBefore(); x.notAfter := x.conn.PeerCertNotAfter()
      END;
      IF x.request = "" THEN
        IF x.Header(59, "request too long, or no CR LF") THEN END
      ELSE
        s.respond(x);
        ASSERT(x.status # 0, NoHeader)
      END;
      ok := ~x.failed & TlsTasks.Close(x.conn);
      (* A client may send its own close_notify straight after the
         request (gnutls-cli does), which is never read; closing a
         socket with unread data makes the kernel reset the connection,
         and a client that gets the reset before it has read the
         response loses it. So read and discard until the client closes,
         for Linger at most (polibtls's PLAN.md, Phase 8). *)
      IF ok THEN closed := TRUE; IF SocketTasks.LingeringClose(h.s, Linger) THEN END END
    END;
    (* One line, with no wait between its parts, so the lines of tasks
       never mix. *)
    OutTime; Out.String(h.peer.host); Out.Char(" ");
    IF ok THEN
      Out.Int(x.status, 0); Out.Char(" ");
      IF x.request = "" THEN Out.Char("-") ELSE OutEscaped(x.request) END;
      Out.Char(" ");
      IF x.certHash = NIL THEN Out.Char("-") ELSE Out.String(x.certHash^) END
    ELSE
      Out.String("failed: "); Out.String(x.conn.error.text^);
      x.conn.Discard
    END;
    Out.Ln
  END;
  IF ~closed THEN Sockets.Close(h.s) END;
  DEC(s.active); Tasks.Broadcast(s.ended)
END Run;

(* Whether a signal has asked the server to stop; it reads what the
   handler wrote every time. *)
PROCEDURE Stopping(): BOOLEAN;
BEGIN RETURN CCaught() # 0
END Stopping;

(* Drops from s.handlers those whose tasks are done, so that the list
   holds only those running, however long the server runs. *)
PROCEDURE Prune(s: Server);
  VAR h, prev: Handler;
BEGIN
  prev := NIL; h := s.handlers;
  WHILE h # NIL DO
    IF Tasks.Done(h) THEN
      IF prev = NIL THEN s.handlers := h.next ELSE prev.next := h.next END
    ELSE prev := h
    END;
    h := h.next
  END
END Prune;

(* Accepts connections on l, starting a Handler for each, until stop. *)
PROCEDURE (a: Acceptor) Run*;
  VAR h: Handler; err: Sockets.Error; s: Server;
BEGIN
  s := a.server;
  WHILE ~s.stop DO
    (* at the limit, until a connection ends *)
    WHILE s.active >= s.limit DO Tasks.Wait(s.ended) END;
    NEW(h); h.server := s;
    Sockets.SetDeadline(a.l, Tick);
    IF Stopping() THEN s.stop := TRUE
    ELSIF SocketTasks.Accept(a.l, h.s, h.peer, err) THEN
      Prune(s);
      h.next := s.handlers; s.handlers := h; INC(s.active);
      Tasks.Start(h, TlsTasks.stackSize);
      INC(s.accepted);
      IF s.accepted = s.count THEN s.stop := TRUE END
    ELSIF err.kind # Sockets.timedOut THEN
      (* EMFILE, or a connection reset while queued: report it, back
         off, go on *)
      OutTime; Out.String("accept failed: "); Out.String(err.text); Out.Ln; Tasks.Sleep(10)
    END
  END;
  Sockets.Close(a.l)
END Run;

(* A server with the key pairs in ctx, answering requests by respond. *)
PROCEDURE New*(ctx: Tls.Context; respond: Responder): Server;
  VAR s: Server;
BEGIN
  NEW(s); s.ctx := ctx; s.respond := respond; s.deadline := DefaultDeadline;
  s.n := 0; s.port := 0; s.count := 0; s.accepted := 0; s.stop := FALSE;
  s.limit := DefaultLimit; s.active := 0;
  s.handlers := NIL;
  RETURN s
END New;

(* Each connection's time, handshake to close_notify, in ms. *)
PROCEDURE (s: Server) SetDeadline*(ms: LONGINT);
BEGIN s.deadline := ms
END SetDeadline;

(* The most connections served at once, at least 1. *)
PROCEDURE (s: Server) SetLimit*(n: LONGINT);
BEGIN IF n < 1 THEN s.limit := 1 ELSE s.limit := n END
END SetLimit;

(* Listens on port at host, "" for every local address (IPv6 and IPv4
   alike), port 0 for one the kernel chooses: s.port says which. It
   catches SIGTERM and SIGINT from here on, not only in Serve, so a
   signal sent as soon as the port is known (by a program that started
   the server on port 0) stops it cleanly rather than killing it. *)
PROCEDURE (s: Server) Listen*(host: ARRAY OF CHAR; port: INTEGER;
    VAR err: Sockets.Error): BOOLEAN;
  VAR a: Sockets.Address;
BEGIN
  CCatch;
  IF ~Sockets.Listen(host, port, 16, TRUE, s.listeners, s.n, err)
    OR ~Sockets.LocalAddress(s.listeners[0], a, err) THEN
    RETURN FALSE
  END;
  (* With port 0, Listen gives both families the same port. *)
  s.port := a.port;
  RETURN TRUE
END Listen;

(* Serves count connections (0: until a signal stops it), then waits for
   them to end, having closed the listeners. Call it from the program's
   main body: it runs every task. A signal caught since Listen stops it
   at once. *)
PROCEDURE (s: Server) Serve*(count: LONGINT);
  VAR as: ARRAY 2 OF Acceptor; i: INTEGER; stopping: BOOLEAN;
BEGIN
  ASSERT(s.n > 0, NotListening);
  s.count := count;
  (* A client that goes away makes a write fail, not end the program. *)
  Sockets.IgnoreBrokenPipe;
  FOR i := 0 TO s.n - 1 DO
    NEW(as[i]); as[i].server := s; as[i].l := s.listeners[i];
    Tasks.Start(as[i], TlsTasks.stackSize)
  END;
  FOR i := 0 TO s.n - 1 DO Tasks.Join(as[i]) END;
  stopping := Stopping();
  IF stopping THEN
    OutTime; Out.String("stopping on signal "); Out.Int(CCaught(), 0);
    Out.String(", connections in progress: "); Out.Int(s.active, 0); Out.Ln
  END;
  WHILE s.handlers # NIL DO Tasks.Join(s.handlers); s.handlers := s.handlers.next END;
  IF stopping THEN OutTime; Out.String("stopped"); Out.Ln END;
  s.n := 0
END Serve;

END GemServer.
