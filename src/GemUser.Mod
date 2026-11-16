MODULE GemUser; (* Running as another user *)

(* A server started as root, to read keys only root may, or by a system
   that starts everything so, should serve as a user of its own, who
   can read the capsules and nothing more. pogemini becomes it once
   its key pairs are loaded and it listens: after that it reads only the
   capsules' files. *)

IMPORT SYSTEM;

PROCEDURE ["C", "GemUser.-root"] CRoot(): SYSTEM.INT32;
PROCEDURE ["C", "GemUser.-become"] CBecome(user: ARRAY OF CHAR;
  VAR why: ARRAY OF CHAR; max: SYSTEM.INT64): SYSTEM.INT32;

(* Whether the process runs as root. *)
PROCEDURE Root*(): BOOLEAN;
BEGIN RETURN CRoot() # 0
END Root;

(* Becomes user, with its groups, for good, so that root can't be had
   back: FALSE, with why, if it can't. As root, any user; otherwise only
   the one it is already. *)
PROCEDURE Become*(user: ARRAY OF CHAR; VAR why: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN CBecome(user, why, LEN(why)) = 0
END Become;

END GemUser.
