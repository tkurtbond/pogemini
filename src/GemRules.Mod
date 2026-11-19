MODULE GemRules; (* allow and deny at work: who is served, and the names' lookups *)

(* The configuration's rules (GemConfig) as the server's Admitter
   (pogeminilib's GeminiServer.SetAdmit), asked as each connection is
   accepted, before its handshake, so a refused client costs the server
   no TLS and no task.

   A rule's host name is looked up when the server starts (Start), each
   in turn, waiting at most LookupLimit ms: one that doesn't resolve
   stops the server, as any other mistake in the configuration does.
   Then a task (Refresher) looks each up again every refresh seconds,
   without stopping the server meanwhile (posockets' SocketTasks.
   Resolve, in a thread of its own). A lookup that fails keeps the
   addresses the name had, since a name server that is down for a
   moment shouldn't let in a client denied, or keep out one allowed;
   it is reported, as is a change. The new addresses replace the old
   in one assignment, which no other task can see half done, since
   tasks are cooperative. The Admitter itself never waits. *)

IMPORT Strings, Tasks, Sockets, SocketTasks, GeminiServer, GemAddresses, GemConfig;

CONST
  LookupLimit* = 10000;  (* ms a lookup has *)
  (* A lookup's addresses, at most: posockets halts on more than its
     caller can hold, so this is generous (PLAN.md, "Address rules"). *)
  MaxLookup = 256;
  StackSize = 64 * 1024;

TYPE
  (* Told of a rule's name looked up again: why says how it failed, or
     is "" if it now has new addresses. Called in the Refresher's task;
     it should write its line without waiting. *)
  Reporter* = PROCEDURE (r: GemConfig.Rule; why-: ARRAY OF CHAR);

  Refresher = POINTER TO RECORD (Tasks.TaskDesc)
    config: GemConfig.Config;
    report: Reporter
  END;

VAR
  config: GemConfig.Config;  (* whose rules Admit applies *)
  found: ARRAY MaxLookup OF Sockets.Address;  (* a lookup's, here, not on a task's stack *)

(* Whether the client at peer is served, by config's rules. A peer whose
   address can't be parsed, which accept never gives, is refused. *)
PROCEDURE Admit*(s: GeminiServer.Server; peer-: Sockets.Address): BOOLEAN;
  VAR a: GemAddresses.Address;
BEGIN
  RETURN GemAddresses.Parse(peer.host, a) & config.Admits(a)
END Admit;

(* found[0..n-1] as r's addresses: TRUE if they differ from those it had,
   in any way but order. *)
PROCEDURE Take(r: GemConfig.Rule; n: INTEGER): BOOLEAN;
  VAR addrs: GemConfig.Addresses; i, j, k: INTEGER; changed, seen: BOOLEAN;
BEGIN
  NEW(addrs, n); k := 0;
  FOR i := 0 TO n - 1 DO
    (* getaddrinfo may give one address twice *)
    IF GemAddresses.Parse(found[i].host, addrs[k]) THEN
      seen := FALSE;
      FOR j := 0 TO k - 1 DO
        IF GemAddresses.Same(addrs[j], addrs[k]) THEN seen := TRUE END
      END;
      IF ~seen THEN INC(k) END
    END
  END;
  changed := k # r.nAddrs;
  FOR i := 0 TO k - 1 DO
    seen := FALSE;
    FOR j := 0 TO r.nAddrs - 1 DO
      IF GemAddresses.Same(addrs[i], r.addrs[j]) THEN seen := TRUE END
    END;
    IF ~seen THEN changed := TRUE END
  END;
  r.addrs := addrs; r.nAddrs := k;  (* one step: no task sees it half made *)
  RETURN changed
END Take;

(* Looks each rule's name up again every refresh seconds, for ever: the
   program ends when its main body does, tasks or no. *)
PROCEDURE (t: Refresher) Run*;
  VAR i, n: INTEGER; r: GemConfig.Rule; err: Sockets.Error;
BEGIN
  LOOP
    Tasks.Sleep(t.config.refresh * 1000);
    FOR i := 0 TO t.config.nRules - 1 DO
      r := t.config.rules[i];
      IF r.name # "" THEN
        IF ~SocketTasks.Resolve(r.name, 0, LookupLimit, found, n, err) THEN t.report(r, err.text)
        ELSIF Take(r, n) THEN t.report(r, "")
        END
      END
    END
  END
END Run;

(* Applies c's rules from now on: looks up their names, waiting at most
   LookupLimit ms for each, and starts a task to look them up again
   every c.refresh seconds (if any, and if c.refresh isn't 0), telling
   report of each failure and change. FALSE, with why, if a name
   doesn't resolve, and c's rules not applied. *)
PROCEDURE Start*(c: GemConfig.Config; report: Reporter; VAR why: ARRAY OF CHAR): BOOLEAN;
  VAR i, n: INTEGER; r: GemConfig.Rule; err: Sockets.Error; names: BOOLEAN; t: Refresher;
BEGIN
  names := FALSE;
  FOR i := 0 TO c.nRules - 1 DO
    r := c.rules[i];
    IF r.name # "" THEN
      names := TRUE;
      IF ~Sockets.ResolveWithin(r.name, 0, LookupLimit, found, n, err) THEN
        IF r.allow THEN COPY("allow ", why) ELSE COPY("deny ", why) END;
        Strings.Append(r.name, why); Strings.Append(": ", why); Strings.Append(err.text, why);
        RETURN FALSE
      END;
      IF Take(r, n) THEN END
    END
  END;
  config := c;
  IF names & (c.refresh > 0) THEN
    NEW(t); t.config := c; t.report := report; Tasks.Start(t, StackSize)
  END;
  RETURN TRUE
END Start;

END GemRules.
