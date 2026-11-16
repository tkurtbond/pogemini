/* GemFiles.c -- the C part of module GemFiles: a file under a
   capsule's root, resolved, checked and opened, and read. POSIX only
   (realpath, open, fstat, read), so the same on Linux and the BSDs.
   Labelled GemFiles.-<name>. */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define NAME(n) __asm__("GemFiles.-" n)

/* GemFiles.Mod's kinds */
enum { FILE_ = 0, MISSING = 1, DIRECTORY = 2, FAILED = 3 };

int32_t gemfiles_resolve(const char *path, char *out, int64_t max) NAME("resolve");
int32_t gemfiles_open(const char *root, const char *path, int32_t *kind) NAME("open");
int64_t gemfiles_read(int32_t fd, char *buf, int64_t pos, int64_t len) NAME("read");
void gemfiles_close(int32_t fd) NAME("close");

/* path with every symbolic link, "." and ".." resolved, in out, of
   max bytes: 0, or -1 if path can't be resolved or is too long. */
int32_t gemfiles_resolve(const char *path, char *out, int64_t max)
{
	char real[PATH_MAX];

	if (realpath(path, real) == NULL || (int64_t)strlen(real) >= max)
		return -1;
	strcpy(out, real);
	return 0;
}

/* Whether errno, after realpath or open failed, means only that there
   is no such file to serve. */
static int missing(int e)
{
	return e == ENOENT || e == ENOTDIR || e == ENAMETOOLONG || e == EACCES
	    || e == ELOOP || e == EPERM;
}

/* Opens path, which must lie under root (a resolved path, from
   gemfiles_resolve) once resolved, for reading: its descriptor, with
   *kind FILE_, if it is a regular file; otherwise -1, and *kind
   DIRECTORY for a directory, MISSING for nothing that may be served
   (none, outside root, a name under root beginning with ".", not
   readable, not a regular file), FAILED for anything else (too many
   files open, an I/O error). */
int32_t gemfiles_open(const char *root, const char *path, int32_t *kind)
{
	char real[PATH_MAX];
	size_t n = strlen(root);
	const char *p;
	struct stat st;
	int fd;

	if (realpath(path, real) == NULL) {
		*kind = missing(errno) ? MISSING : FAILED;
		return -1;
	}
	/* under root: root itself, or root and "/" before the rest; root
	   "/" is a prefix of everything */
	if (strncmp(real, root, n) != 0
	    || (real[n] != '/' && real[n] != '\0' && !(n == 1 && root[0] == '/'))) {
		*kind = MISSING;
		return -1;
	}
	/* a hidden name, asked for or reached through a link */
	for (p = n == 1 ? real : real + n; (p = strchr(p, '/')) != NULL; p++)
		if (p[1] == '.') {
			*kind = MISSING;
			return -1;
		}
	/* O_NONBLOCK, so a FIFO doesn't stop the server in open; O_NOFOLLOW
	   in case the last name became a link since realpath */
	fd = open(real, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0) {
		*kind = missing(errno) ? MISSING : FAILED;
		return -1;
	}
	if (fstat(fd, &st) != 0) {
		close(fd);
		*kind = FAILED;
		return -1;
	}
	if (!S_ISREG(st.st_mode)) {
		close(fd);
		*kind = S_ISDIR(st.st_mode) ? DIRECTORY : MISSING;
		return -1;
	}
	*kind = FILE_;
	return fd;
}

/* Reads up to len bytes into buf[pos..]: how many, 0 at the end, -1
   for an error. */
int64_t gemfiles_read(int32_t fd, char *buf, int64_t pos, int64_t len)
{
	ssize_t n;

	do
		n = read(fd, buf + pos, (size_t)len);
	while (n < 0 && errno == EINTR);
	return n;
}

void gemfiles_close(int32_t fd)
{
	close(fd);
}
