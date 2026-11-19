MODULE GemFiles; (* A capsule's files, served *)

(* A request's path names a file under the capsule's root, its document
   root: "/a/b.gmi" is <root>/a/b.gmi. What is served:

   - a regular file, with status 20 and the MIME type its name's
     extension gives (Type), text/gemini for .gmi and .gemini;
   - for a directory asked for with a final "/", its index.gmi; asked
     for without, a redirect (31) to the same path with the "/" added,
     so that the links in its index resolve against the directory;
   - for a directory asked for with a final "/" that has no index.gmi,
     a listing (List), if the capsule has listings (GemConfig), and
     otherwise 51;
   - nothing else: 51 for a name that isn't there, anything not a regular file
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

   A file or directory inside a require (GemConfig) is served only as
   GemAccess allows, judged by the path it really has, under the root:
   the request's path was judged already (pogemini), and a link may
   lead into a require from outside it.

   The root is resolved once (Resolve) and the file's path resolved and
   compared with it for each request; the file is then opened by its
   resolved path, without following a final link. A link swapped in
   for a directory above it between the two could still lead out: only
   whoever may write under the root could do that, and they can already
   change what is served.

   A listing is a text/gemini page with a link for each file and
   directory in the directory that would be served, and nothing else:
   no hidden name, nothing a link takes outside the root or into a
   hidden name, nothing not a regular file or directory, nothing in a
   require the client may not have, and no name a link line couldn't
   carry (a control character, or not UTF-8). Directories come first,
   then files, each by the bytes of their names. At most MaxEntries
   are listed, with a line saying there are more, since a page beyond
   that helps no one.

   A file is read and sent in pieces of Piece bytes, so any size is
   served in little memory. A read from a disk stops every task for its
   length, which is short beside the network. If reading fails part way
   through, what was sent is all the client gets, ended as if complete:
   Gemini has no way to say otherwise. *)

IMPORT Strings, UnixErrors, UnixFiles, GeminiUrls, GeminiHeaders, GeminiTextWriter,
  GeminiServer, GemConfig, GemAccess;

CONST
  Piece* = 16384;  (* bytes read and sent at a time *)
  Index* = "index.gmi";
  PathLen = 2200;  (* a root, a request's path and Index *)
  MaxEntries* = 10000;  (* listed at most *)

  (* What Open finds *)
  File = 0; Missing = 1; Directory = 2; Failed = 3;

TYPE
  Buffer = POINTER TO ARRAY Piece OF CHAR;
  PathBuf = POINTER TO ARRAY PathLen OF CHAR;  (* kept off a task's stack *)

  (* A name a listing shows *)
  Entry = POINTER TO EntryDesc;
  EntryDesc = RECORD
    name: POINTER TO ARRAY OF CHAR;
    dir: BOOLEAN;
    next: Entry
  END;

  (* A listing's gemtext, written by GeminiTextWriter, which refuses a
     line that would read back as another, and gathered into pieces,
     since each write to the connection is a TLS record of its own (a
     GeminiServer.Writer writes each part of a line as it comes). url
     and label hold an entry's link, off the task's stack. *)
  Page = POINTER TO PageDesc;
  PageDesc = RECORD (GeminiTextWriter.WriterDesc)
    x: GeminiServer.Exchange;
    buf: Buffer;
    n: LONGINT;
    url: ARRAY 3 * UnixFiles.NameLen + 2 OF CHAR;
    label: ARRAY UnixFiles.NameLen + 2 OF CHAR
  END;

(* path with every symbolic link, "." and ".." resolved, in real: FALSE
   if it can't be, or is too long for real. *)
PROCEDURE Resolve*(path: ARRAY OF CHAR; VAR real: ARRAY OF CHAR): BOOLEAN;
  VAR err: UnixErrors.Error;
BEGIN
  RETURN UnixFiles.Resolve(path, real, err)
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
  ELSIF (ext = "txt") OR (ext = "text") THEN COPY("text/plain", type)
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

(* Whether path has a segment beginning with ".". CheckRequest has
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

(* Whether err, from resolving or opening a file, means only that there
   is no such file to serve: none, or none the server may read. *)
PROCEDURE NotThere(VAR err: UnixErrors.Error): BOOLEAN;
  VAR c: INTEGER;
BEGIN
  c := err.code;
  RETURN (c = UnixErrors.ENOENT) OR (c = UnixErrors.ENOTDIR)
    OR (c = UnixErrors.ENAMETOOLONG) OR (c = UnixErrors.EACCES)
    OR (c = UnixErrors.ELOOP) OR (c = UnixErrors.EPERM)
END NotThere;

(* path, resolved, in real, and opened for reading: its descriptor, with
   kind File, if it is a regular file; otherwise -1, and kind Directory
   for a directory, Missing for nothing that may be served (none,
   outside root, a name under root beginning with ".", not readable,
   not a regular file), Failed for anything else (too many files open,
   an I/O error). real is "" for anything but a file or a directory.

   root is a resolved path (Resolve). The file is opened by its
   resolved path, non-blocking, so a FIFO doesn't stop the server in
   open, and without following a final link, in case the last name
   became one since it was resolved. *)
PROCEDURE OpenResolved(root, path: ARRAY OF CHAR; VAR kind: INTEGER;
    VAR real: ARRAY OF CHAR): LONGINT;
  VAR err: UnixErrors.Error; n, i, fd: LONGINT; k: INTEGER;
BEGIN
  IF ~UnixFiles.Resolve(path, real, err) THEN
    IF NotThere(err) THEN kind := Missing ELSE kind := Failed END;
    real[0] := 0X; RETURN -1
  END;
  (* under root: root itself, or root and "/" before the rest; root "/"
     is a prefix of everything *)
  IF root = "/" THEN n := 0
  ELSE
    n := 0; WHILE (root[n] # 0X) & (real[n] = root[n]) DO INC(n) END;
    IF (root[n] # 0X) OR (real[n] # "/") & (real[n] # 0X) THEN
      kind := Missing; real[0] := 0X; RETURN -1
    END
  END;
  (* a hidden name after the root, asked for or reached through a link *)
  i := n;
  WHILE real[i] # 0X DO
    IF (real[i] = "/") & (real[i + 1] = ".") THEN kind := Missing; real[0] := 0X; RETURN -1 END;
    INC(i)
  END;
  IF ~UnixFiles.OpenRead(real, {UnixFiles.nonBlocking, UnixFiles.noFollow}, fd, err) THEN
    IF NotThere(err) THEN kind := Missing ELSE kind := Failed END;
    real[0] := 0X; RETURN -1
  END;
  IF ~UnixFiles.KindOf(fd, k, err) THEN
    UnixFiles.Close(fd); kind := Failed; real[0] := 0X; RETURN -1
  END;
  IF k = UnixFiles.regular THEN kind := File; RETURN fd END;
  UnixFiles.Close(fd);
  IF k = UnixFiles.directory THEN kind := Directory ELSE kind := Missing; real[0] := 0X END;
  RETURN -1
END OpenResolved;

(* Sends the regular file open on fd, of type, and closes fd. *)
PROCEDURE Send(x: GeminiServer.Exchange; fd: LONGINT; type: ARRAY OF CHAR);
  VAR buf: Buffer; n: LONGINT; err: UnixErrors.Error;
BEGIN
  IF x.Header(20, type) THEN
    NEW(buf);
    LOOP
      IF ~UnixFiles.Read(fd, buf^, 0, Piece, n, err) OR (n = 0)
        OR ~x.Write(buf^, 0, n) THEN EXIT END
    END
  END;
  UnixFiles.Close(fd)
END Send;

(* real, a path under k's root, as a path from the root: "/" for the
   root itself. *)
PROCEDURE Relative(k: GemConfig.Capsule; VAR real, rel: ARRAY OF CHAR);
  VAR i, n: LONGINT;
BEGIN
  (* the root "/" is a prefix of none *)
  IF k.root = "/" THEN n := 0 ELSE n := Strings.Length(k.root) END;
  i := 0; WHILE real[n + i] # 0X DO rel[i] := real[n + i]; INC(i) END;
  rel[i] := 0X;
  IF rel = "" THEN COPY("/", rel) END
END Relative;

(* Opens path, under root, as OpenResolved, and, for a file or a directory,
   checks that x may have it, by the path it really has: if not, x has
   its header, and the result is -1 and kind Missing. *)
PROCEDURE Open(x: GeminiServer.Exchange; k: GemConfig.Capsule; path: ARRAY OF CHAR;
    VAR kind: INTEGER): LONGINT;
  VAR real, rel: ARRAY PathLen OF CHAR; fd: LONGINT;
BEGIN
  fd := OpenResolved(k.root, path, kind, real);
  IF (kind = File) OR (kind = Directory) THEN
    Relative(k, real, rel);
    IF ~GemAccess.Allowed(x, k, rel) THEN
      IF kind = File THEN UnixFiles.Close(fd) END;
      kind := Missing; fd := -1
    END
  END;
  RETURN fd
END Open;

(* Sends what p holds; FALSE if the write failed. *)
PROCEDURE (p: Page) Flush(): BOOLEAN;
  VAR ok: BOOLEAN;
BEGIN
  ok := (p.n = 0) OR p.x.Write(p.buf^, 0, p.n); p.n := 0;
  RETURN ok
END Flush;

(* Adds s[0..n-1] to p, sending what p holds first if it wouldn't fit;
   FALSE if a write failed. *)
PROCEDURE (p: Page) Put*(s-: ARRAY OF CHAR; n: LONGINT): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF (p.n + n > Piece) & ~p.Flush() THEN RETURN FALSE END;
  IF n > Piece THEN RETURN p.x.Write(s, 0, n) END;
  i := 0; WHILE i < n DO p.buf[p.n] := s[i]; INC(p.n); INC(i) END;
  RETURN TRUE
END Put;

(* A link to e, percent-encoded, every byte but a letter, a digit and
   "-._~", RFC 3986's unreserved (GeminiUrls.Encode), so the link is a
   relative path whatever the name holds: "a:b" a name, not a scheme,
   "a?b" not a query. A directory's has "/" after it. A name beginning
   with whitespace, which a reader drops from a label, is linked with
   no label, so the reader shows the URL, which keeps it. FALSE only if
   a write failed. *)
PROCEDURE AddEntry(p: Page; e: Entry): BOOLEAN;
  VAR why: ARRAY 128 OF CHAR;
BEGIN
  IF GeminiUrls.Encode(e.name^, p.url) THEN
    COPY(e.name^, p.label);
    IF e.dir THEN Strings.Append("/", p.url); Strings.Append("/", p.label) END;
    IF ~GeminiTextWriter.Link(p, p.url, p.label, why) & ~p.x.failed THEN
      IF GeminiTextWriter.Link(p, p.url, "", why) THEN END
    END
  END;
  RETURN ~p.x.failed
END AddEntry;

(* Whether a comes before b in a listing: directories first, then by
   the bytes of the names. *)
PROCEDURE Before(a, b: Entry): BOOLEAN;
BEGIN
  IF a.dir # b.dir THEN RETURN a.dir END;
  RETURN a.name^ < b.name^
END Before;

(* list, n entries long, sorted by Before: a merge sort, stable and
   never worse than n log n, however the system keeps the names. *)
PROCEDURE Sort(list: Entry; n: LONGINT): Entry;
  VAR a, b, e, head, tail: Entry; i: LONGINT;
BEGIN
  IF n < 2 THEN RETURN list END;
  a := list; e := list; i := 1;
  WHILE i < n DIV 2 DO e := e.next; INC(i) END;
  b := e.next; e.next := NIL;
  a := Sort(a, n DIV 2); b := Sort(b, n - n DIV 2);
  head := NIL; tail := NIL;
  WHILE (a # NIL) & (b # NIL) DO
    IF Before(b, a) THEN e := b; b := b.next ELSE e := a; a := a.next END;
    IF tail = NIL THEN head := e ELSE tail.next := e END;
    tail := e
  END;
  IF a = NIL THEN a := b END;
  IF tail = NIL THEN head := a ELSE tail.next := a END;
  RETURN head
END Sort;

(* Whether name may be shown: not hidden, and fit for a link line, in
   UTF-8 with no control character. *)
PROCEDURE Showable(VAR name: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF name[0] = "." THEN RETURN FALSE END;
  i := 0;
  WHILE name[i] # 0X DO
    IF (name[i] < 20X) OR (name[i] = 7FX) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN GeminiUrls.Utf8(name, i)
END Showable;

(* Answers r with a listing of dir, the directory r names, which x may
   have (Serve). *)
PROCEDURE List(x: GeminiServer.Exchange; k: GemConfig.Capsule; VAR dir: ARRAY OF CHAR;
    VAR r: GeminiUrls.Request);
  VAR real, path, ereal, rel: PathBuf; d: UnixFiles.Directory; err: UnixErrors.Error;
    name: ARRAY UnixFiles.NameLen OF CHAR; meta: ARRAY 64 OF CHAR;
    list, e: Entry; n, fd, len: LONGINT; kind: INTEGER; more, ok: BOOLEAN; p: Page;
    why: ARRAY 128 OF CHAR;
BEGIN
  NEW(real); NEW(path); NEW(ereal); NEW(rel);
  fd := OpenResolved(k.root, dir, kind, real^);
  IF kind = Failed THEN IF x.Header(40, "can't read the directory") THEN END; RETURN
  ELSIF kind # Directory THEN
    IF fd >= 0 THEN UnixFiles.Close(fd) END;
    IF x.Header(51, "not found") THEN END; RETURN
  END;
  IF ~UnixFiles.OpenDirectory(real^, {UnixFiles.noFollow}, d, err) THEN
    IF NotThere(err) THEN IF x.Header(51, "not found") THEN END
    ELSIF x.Header(40, "can't read the directory") THEN
    END;
    RETURN
  END;
  len := Strings.Length(real^);
  list := NIL; n := 0; more := FALSE;
  LOOP
    IF ~UnixFiles.NextName(d, name, err) THEN
      IF err.code # UnixErrors.ENAMETOOLONG THEN
        UnixFiles.CloseDirectory(d);
        IF x.Header(40, "can't read the directory") THEN END; RETURN
      END
    ELSIF name = "" THEN EXIT
    ELSIF Showable(name) & (len + 1 + Strings.Length(name) < PathLen) THEN
      COPY(real^, path^); Strings.Append("/", path^); Strings.Append(name, path^);
      fd := OpenResolved(k.root, path^, kind, ereal^);
      IF fd >= 0 THEN UnixFiles.Close(fd) END;
      IF (kind = File) OR (kind = Directory) THEN
        Relative(k, ereal^, rel^);
        IF GemAccess.Refusal(x, k, rel^, meta) = 0 THEN
          IF n = MaxEntries THEN more := TRUE; EXIT END;
          NEW(e); NEW(e.name, Strings.Length(name) + 1); COPY(name, e.name^);
          e.dir := kind = Directory; e.next := list; list := e; INC(n)
        END
      END
    END
  END;
  UnixFiles.CloseDirectory(d);
  list := Sort(list, n);

  IF ~x.Header(20, "text/gemini") THEN RETURN END;
  NEW(p); GeminiTextWriter.Init(p); p.x := x; NEW(p.buf); p.n := 0;
  (* The path is CheckRequest's, which has no control character and
     begins with "/", so its heading is never refused; nor is any line
     here but an entry's, which AddEntry sees to. *)
  ok := GeminiTextWriter.Heading(p, 1, r.path, why) & GeminiTextWriter.Text(p, "", why);
  IF ok & (r.path # "/") THEN ok := GeminiTextWriter.Link(p, "../", "../", why) END;
  e := list;
  WHILE ok & (e # NIL) DO ok := AddEntry(p, e); e := e.next END;
  IF ok & more THEN
    ok := GeminiTextWriter.Text(p, "", why) & GeminiTextWriter.Text(p, "More entries are not listed.", why)
  END;
  IF ok & p.Flush() THEN END
END List;

(* Answers r, a request for a file of capsule k, whose root is one
   Resolve gave. *)
PROCEDURE Serve*(x: GeminiServer.Exchange; k: GemConfig.Capsule; VAR r: GeminiUrls.Request);
  VAR path: ARRAY PathLen OF CHAR; type: ARRAY 64 OF CHAR;
    meta: ARRAY GeminiHeaders.MaxMeta + 1 OF CHAR;
    kind: INTEGER; fd, n, dirLen: LONGINT;
BEGIN
  IF Hidden(r.path) OR (Strings.Length(k.root) + Strings.Length(r.path) + 16 >= PathLen) THEN
    IF x.Header(51, "not found") THEN END; RETURN
  END;
  COPY(k.root, path); Strings.Append(r.path, path);
  fd := Open(x, k, path, kind);
  IF x.status # 0 THEN RETURN END;  (* refused by GemAccess *)
  IF kind = Directory THEN
    n := Strings.Length(r.path);
    IF r.path[n - 1] # "/" THEN
      (* the path as sent, with "/" added, relative to the request *)
      IF Strings.Length(r.rawPath) + 2 + Strings.Length(r.query) > GeminiHeaders.MaxMeta THEN
        IF x.Header(51, "not found") THEN END; RETURN
      END;
      COPY(r.rawPath, meta); Strings.Append("/", meta);
      IF r.hasQuery THEN Strings.Append("?", meta); Strings.Append(r.query, meta) END;
      IF x.Header(31, meta) THEN END; RETURN
    END;
    dirLen := Strings.Length(path);
    Strings.Append(Index, path);
    fd := Open(x, k, path, kind);
    IF x.status # 0 THEN RETURN END;
    IF (kind = Missing) & k.listings THEN
      path[dirLen] := 0X; List(x, k, path, r); RETURN
    END;
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
