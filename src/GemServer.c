/* GemServer.c -- the C part of module GemServer: the signals that stop
   the server, and the time for its log. POSIX only (sigaction, time),
   so the same on Linux and the BSDs. Labelled GemServer.-<name>. */

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define NAME(n) __asm__("GemServer.-" n)

void gemserver_catch(void) NAME("catch");
int32_t gemserver_caught(void) NAME("caught");
void gemserver_now(char *out, int64_t max) NAME("now");

static volatile sig_atomic_t caught = 0;

static void stop(int number)
{
	caught = number;
}

/* Catches SIGTERM and SIGINT, noting which came. Only once each:
   SA_RESETHAND puts back the default, so a second one ends the server
   at once, without waiting for its connections. */
void gemserver_catch(void)
{
	struct sigaction action;

	memset(&action, 0, sizeof action);
	action.sa_handler = stop;
	sigemptyset(&action.sa_mask);
	action.sa_flags = SA_RESTART | SA_RESETHAND;
	sigaction(SIGTERM, &action, NULL);
	sigaction(SIGINT, &action, NULL);
}

/* The number of the signal caught, 0 for none yet. */
int32_t gemserver_caught(void)
{
	return caught;
}

/* The time now, UTC, as 2026-11-16T12:34:56Z, in out, of max bytes
   (at least 21). Worked out here, not by gmtime_r: it is called in a
   task, whose stack is small, and the first gmtime_r loads the UTC zone
   with tzload, which needs more than 64 KiB of stack on NetBSD and 32
   on OpenBSD, so it overran the task's stack and corrupted the heap. */
void gemserver_now(char *out, int64_t max)
{
	int64_t t = (int64_t)time(NULL);
	int64_t days = t / 86400, secs = t % 86400;
	int64_t z, era, doe, yoe, y, doy, mp, d, m;

	if (secs < 0) {
		secs += 86400;
		days--;
	}
	/* the civil date of a count of days since 1970-01-01 (Howard
	   Hinnant's civil_from_days): years run from March, so that the
	   leap day comes last */
	z = days + 719468;
	era = (z >= 0 ? z : z - 146096) / 146097;
	doe = z - era * 146097;
	yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	y = yoe + era * 400;
	doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	mp = (5 * doy + 2) / 153;
	d = doy - (153 * mp + 2) / 5 + 1;
	m = mp < 10 ? mp + 3 : mp - 9;
	if (m <= 2)
		y++;
	snprintf(out, (size_t)max, "%04lld-%02lld-%02lldT%02lld:%02lld:%02lldZ",
	    (long long)y, (long long)m, (long long)d, (long long)(secs / 3600),
	    (long long)(secs / 60 % 60), (long long)(secs % 60));
}
