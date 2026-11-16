/* GemUser.c -- the C part of module GemUser: becoming another user.
   POSIX and BSD (getpwnam, initgroups, setgid, setuid), so the same on
   Linux and the BSDs. Labelled GemUser.-<name>. */

#define _DEFAULT_SOURCE  /* initgroups */

#include <grp.h>
#include <pwd.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#define NAME(n) __asm__("GemUser.-" n)

int32_t gemuser_root(void) NAME("root");
int32_t gemuser_become(const char *user, char *why, int64_t max) NAME("become");

static void say(char *why, int64_t max, const char *s)
{
	strncpy(why, s, (size_t)max - 1);
	why[max - 1] = '\0';
}

/* 1 if the process runs as root, 0 if not. */
int32_t gemuser_root(void)
{
	return geteuid() == 0;
}

/* Becomes user, its groups and its user ID, for good: 0, or -1 with
   why. One not root can only "become" itself. */
int32_t gemuser_become(const char *user, char *why, int64_t max)
{
	struct passwd *pw = getpwnam(user);

	if (pw == NULL) {
		say(why, max, "no such user");
		return -1;
	}
	if (geteuid() != 0) {
		if (pw->pw_uid == getuid() && pw->pw_uid == geteuid())
			return 0;
		say(why, max, "only root can become another user");
		return -1;
	}
	/* groups first: once the user ID is no longer root, they can't
	   be changed */
	if (initgroups(user, pw->pw_gid) != 0 || setgid(pw->pw_gid) != 0) {
		say(why, max, "can't take the user's groups");
		return -1;
	}
	if (setuid(pw->pw_uid) != 0) {
		say(why, max, "can't take the user's ID");
		return -1;
	}
	/* for good: root again must be impossible */
	if (pw->pw_uid != 0 && (setuid(0) == 0 || seteuid(0) == 0)) {
		say(why, max, "could become root again");
		return -1;
	}
	return 0;
}
