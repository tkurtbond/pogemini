/* GemServer.c -- the C part of module GemServer: the signals that stop
   the server, and the time for its log. POSIX only (sigaction, time,
   gmtime_r, strftime), so the same on Linux and the BSDs. Labelled
   GemServer.-<name>. */

#include <signal.h>
#include <stdint.h>
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
   (at least 21). */
void gemserver_now(char *out, int64_t max)
{
	time_t t = time(NULL);
	struct tm tm;

	if (gmtime_r(&t, &tm) == NULL
	    || strftime(out, (size_t)max, "%Y-%m-%dT%H:%M:%SZ", &tm) == 0)
		strncpy(out, "0000-00-00T00:00:00Z", (size_t)max);
}
