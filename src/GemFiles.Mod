MODULE GemFiles; (* A capsule's files, served *)

(* A request's path names a file under the capsule's root, its document
   root: "/a/b.gmi" is <root>/a/b.gmi. What is served:

   - a regular file, with status 20 and the MIME type its name's
     extension gives (Type), text/gemini for .gmi and .gemini;
   - for a directory asked for with a final "/", its index.gmi; asked
     for without, a redirect (31) to the same path with the "/" added,
     so that the links in its index resolve against the directory;
   - nothing else: 51 for a name that isn't there, a directory without
     index.gmi (there are no listings), anything not a regular file
     (a FIFO, a device, a socket), anything the server can't read, a
     name beginning with "." (".git", ".htaccess": hidden, by Unix
     custom), and anything whose real path, once symbolic links are
     resolved, lies outside the root or passes through a hidden name.
     All say only "not found", so a client learns nothing of what is
     there. 40 for a failure of the server's own (too many files open,
     an I/O error).

   A symbolic link inside the root to something else inside it is
   followed, so a capsule may link one file to another; one leading out
   is refused, as if a file under the root that someone made a link
   could be used to read the rest of the system.

   The root is resolved once (Resolve) and the file's path resolved and
   compared with it for each request; the file is then opened by its
   resolved path, without following a final link. A link swapped in
   for a directory above it between the two could still lead out: only
   whoever may write under the root could do that, and they can already
   change what is served.

   A file is read and sent in pieces of Piece bytes, so any size is
   served in little memory. A read from a disk stops every task for its
   length, which is short beside the network. If reading fails part way
   through, what was sent is all the client gets, ended as if complete:
   Gemini has no way to say otherwise. *)

IMPORT SYSTEM, Strings, GemServer, GemRequest;

CONST
  Piece* = 16384;  (* bytes read and sent at a time *)
  Index* = "index.gmi";
  PathLen = 2200;  (* a root, a request's path and Index *)

  (* GemFiles.c's kinds *)
  File = 0; Missing = 1; Directory = 2; Failed = 3;

PROCEDURE ["C", "GemFiles.-resolve"] CResolve(path: ARRAY OF CHAR;
  VAR out: ARRAY OF CHAR; max: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "GemFiles.-open"] COpen(root, path: ARRAY OF CHAR;
  VAR kind: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "GemFiles.-read"] CRead(fd: SYSTEM.INT32; VAR buf: ARRAY OF CHAR;
  pos, len: SYSTEM.INT64): SYSTEM.INT64;
PROCEDURE ["C", "GemFiles.-close"] CClose(fd: SYSTEM.INT32);

TYPE
  Buffer = POINTER TO ARRAY Piece OF CHAR;

(* path with every symbolic link, "." and ".." resolved, in real: FALSE
   if it can't be, or is too long for real. *)
PROCEDURE Resolve*(path: ARRAY OF CHAR; VAR real: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN CResolve(path, real, LEN(real)) = 0
END Resolve;

PROCEDURE Lower(c: CHAR): CHAR;
BEGIN
  IF (c >= "A") & (c <= "Z") THEN RETURN CHR(ORD(c) + 32) END;
  RETURN c
END Lower;

(* The MIME type for name, by its extension, in lower case or not:
   application/octet-stream for one unknown or none. Text is UTF-8,
   which the specification makes the default, so no charset is given. *)
PROCEDURE Type*(name: ARRAY OF CHAR; VAR type: ARRAY OF CHAR);
  VAR ext: ARRAY 16 OF CHAR; i, j, n: LONGINT;
BEGIN
  n := Strings.Length(name); i := n;
  WHILE (i > 0) & (name[i - 1] # ".") & (name[i - 1] # "/") DO DEC(i) END;
  ext := "";
  IF (i > 1) & (name[i - 1] = ".") & (name[i - 2] # "/") & (n - i < LEN(ext)) THEN
    j := 0; WHILE i < n DO ext[j] := Lower(name[i]); INC(i); INC(j) END; ext[j] := 0X
  END;
  IF (ext = "gmi") OR (ext = "gemini") THEN COPY("text/gemini", type)
  ELSIF ext = "txt" THEN COPY("text/plain", type)
  ELSIF (ext = "md") OR (ext = "markdown") THEN COPY("text/markdown", type)
  ELSIF (ext = "html") OR (ext = "htm") THEN COPY("text/html", type)
  ELSIF ext = "css" THEN COPY("text/css", type)
  ELSIF ext = "csv" THEN COPY("text/csv", type)
  ELSIF ext = "xml" THEN COPY("text/xml", type)
  ELSIF (ext = "atom") THEN COPY("application/atom+xml", type)
  ELSIF (ext = "rss") THEN COPY("application/rss+xml", type)
  ELSIF ext = "json" THEN COPY("application/json", type)
  ELSIF ext = "pdf" THEN COPY("application/pdf", type)
  ELSIF ext = "zip" THEN COPY("application/zip", type)
  ELSIF ext = "gz" THEN COPY("application/gzip", type)
  ELSIF ext = "tar" THEN COPY("application/x-tar", type)
  ELSIF ext = "png" THEN COPY("image/png", type)
  ELSIF (ext = "jpg") OR (ext = "jpeg") THEN COPY("image/jpeg", type)
  ELSIF ext = "gif" THEN COPY("image/gif", type)
  ELSIF ext = "webp" THEN COPY("image/webp", type)
  ELSIF ext = "svg" THEN COPY("image/svg+xml", type)
  ELSIF ext = "ico" THEN COPY("image/vnd.microsoft.icon", type)
  ELSIF ext = "mp3" THEN COPY("audio/mpeg", type)
  ELSIF (ext = "ogg") OR (ext = "oga") THEN COPY("audio/ogg", type)
  ELSIF ext = "opus" THEN COPY("audio/opus", type)
  ELSIF ext = "flac" THEN COPY("audio/flac", type)
  ELSIF ext = "wav" THEN COPY("audio/wav", type)
  ELSIF ext = "mp4" THEN COPY("video/mp4", type)
  ELSIF ext = "webm" THEN COPY("video/webm", type)
  ELSE COPY("application/octet-stream", type)
  END
END Type;

(* Whether path has a segment beginning with ".". GemRequest has
   resolved "." and "..", so any such segment is a hidden name. *)
PROCEDURE Hidden(path: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i + 1 < LEN(path)) & (path[i] # 0X) DO
    IF (path[i] = "/") & (path[i + 1] = ".") THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END Hidden;

(* Sends the regular file open on fd, of type, and closes fd. *)
PROCEDURE Send(x: GemServer.Exchange; fd: SYSTEM.INT32; type: ARRAY OF CHAR);
  VAR buf: Buffer; n: SYSTEM.INT64;
BEGIN
  IF x.Header(20, type) THEN
    NEW(buf);
    LOOP
      n := CRead(fd, buf^, 0, Piece);
      IF (n <= 0) OR ~x.Write(buf^, 0, SYSTEM.VAL(LONGINT, n)) THEN EXIT END
    END
  END;
  CClose(fd)
END Send;

(* Answers r, a request for a file under root, a path Resolve gave. *)
PROCEDURE Serve*(x: GemServer.Exchange; root: ARRAY OF CHAR; VAR r: GemRequest.Request);
  VAR path: ARRAY PathLen OF CHAR; type: ARRAY 64 OF CHAR;
    meta: ARRAY GemServer.MaxMeta + 1 OF CHAR;
    kind, fd: SYSTEM.INT32; n: LONGINT;
BEGIN
  IF Hidden(r.path) OR (Strings.Length(root) + Strings.Length(r.path) + 16 >= PathLen) THEN
    IF x.Header(51, "not found") THEN END; RETURN
  END;
  COPY(root, path); Strings.Append(r.path, path);
  fd := COpen(root, path, kind);
  IF kind = Directory THEN
    n := Strings.Length(r.path);
    IF r.path[n - 1] # "/" THEN
      (* the path as sent, with "/" added, relative to the request *)
      IF Strings.Length(r.rawPath) + 2 + Strings.Length(r.query) > GemServer.MaxMeta THEN
        IF x.Header(51, "not found") THEN END; RETURN
      END;
      COPY(r.rawPath, meta); Strings.Append("/", meta);
      IF r.hasQuery THEN Strings.Append("?", meta); Strings.Append(r.query, meta) END;
      IF x.Header(31, meta) THEN END; RETURN
    END;
    Strings.Append(Index, path);
    fd := COpen(root, path, kind);
    COPY(Index, path)  (* its name, for its type *)
  ELSE
    COPY(r.path, path)
  END;
  IF kind = File THEN Type(path, type); Send(x, fd, type)
  ELSIF kind = Failed THEN IF x.Header(40, "can't read the file") THEN END
  ELSE IF x.Header(51, "not found") THEN END
  END
END Serve;

END GemFiles.
