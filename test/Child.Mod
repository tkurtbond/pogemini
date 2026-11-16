MODULE Child; (* A command run as a child process, for the tests *)

(* The server under test runs as a child process, as it will in use, so
   the tests see what a user sees: its exit status, and its log on
   standard output. Copied from polibtls's test/TestPeers. Spawn, Wait
   and ReadLine wait in the kernel and so stop every task: call them
   outside tasks. *)

IMPORT SYSTEM;

PROCEDURE ["C", "Child.-spawn"] CSpawn(command, input: ARRAY OF CHAR;
  inputlen: SYSTEM.INT64; VAR out: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "Child.-wait"] CWait(pid: SYSTEM.INT32; out: SYSTEM.INT64;
  VAR got: ARRAY OF CHAR; gotmax: SYSTEM.INT64; VAR gotlen: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "Child.-readline"] CReadLine(out: SYSTEM.INT64;
  VAR line: ARRAY OF CHAR; max: SYSTEM.INT64; ms: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "Child.-kill"] CKill(pid: SYSTEM.INT32);

TYPE
  Child* = RECORD pid: SYSTEM.INT32; out: SYSTEM.INT64 END;

(* Runs command with /bin/sh -c as a child process, giving it
   input[0..inputlen-1] (at most 64 KiB) on its standard input and then
   end of file. FALSE if it couldn't start. Its output, standard error
   included, must fit 64 KiB until Wait reads it. *)
PROCEDURE Spawn*(command, input: ARRAY OF CHAR; inputlen: LONGINT;
    VAR c: Child): BOOLEAN;
BEGIN
  c.pid := CSpawn(command, input, inputlen, c.out);
  RETURN c.pid > 0
END Spawn;

(* Waits for c to end: its output, standard error included, as much as
   fits in got, and how much there was in all; its exit status, or -1
   if it didn't exit normally. *)
PROCEDURE Wait*(VAR c: Child; VAR got: ARRAY OF CHAR; VAR gotlen: LONGINT): INTEGER;
  VAR n: SYSTEM.INT64; r: SYSTEM.INT32;
BEGIN
  r := CWait(c.pid, c.out, got, LEN(got), n);
  gotlen := SYSTEM.VAL(LONGINT, n);
  IF gotlen < LEN(got) THEN got[gotlen] := 0X ELSE got[LEN(got) - 1] := 0X END;
  RETURN r
END Wait;

(* Reads c's next line of output, while it runs, into line, the newline
   included, waiting at most ms for each byte; FALSE if its output ended
   or ms passed first. Wait gets what is left. *)
PROCEDURE ReadLine*(VAR c: Child; VAR line: ARRAY OF CHAR; ms: LONGINT): BOOLEAN;
BEGIN RETURN CReadLine(c.out, line, LEN(line), SHORT(ms)) >= 0
END ReadLine;

(* Ends c, as for a server that won't finish by itself; Wait for it
   afterwards. *)
PROCEDURE Kill*(VAR c: Child);
BEGIN CKill(c.pid)
END Kill;

END Child.
