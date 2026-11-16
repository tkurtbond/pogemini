/* Child.c -- the C part of module Child: a command run as a child
   process, such as the server under test, with its output read while
   it runs and when it ends. Copied from polibtls's test/TestPeers.c.
   Labelled Child.-<name>. */

#define _GNU_SOURCE  /* pipe2 */

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define NAME(n) __asm__("Child.-" n)

int32_t child_spawn(const char *command, const char *input,
    int64_t inputlen, int64_t *out) NAME("spawn");
int32_t child_wait(int32_t pid, int64_t out, char *got, int64_t gotmax,
    int64_t *gotlen) NAME("wait");
int32_t child_readline(int64_t out, char *line, int64_t max,
    int32_t ms) NAME("readline");
void child_kill(int32_t pid) NAME("kill");

/* Runs command with /bin/sh -c, its standard input
   a pipe given input and then closed, its standard output and error one
   pipe, whose reading end goes to *out: the child's pid, or -1. The
   input must fit a pipe's buffer (64 KiB on Linux), since nothing reads
   it until the caller is ready, and so must the output, since nothing
   drains it until child_wait. */
int32_t child_spawn(const char *command, const char *input,
    int64_t inputlen, int64_t *out)
{
	int in[2], o[2];
	pid_t pid;

	if (pipe2(in, O_CLOEXEC) != 0)
		return -1;
	if (pipe2(o, O_CLOEXEC) != 0) {
		close(in[0]); close(in[1]);
		return -1;
	}
	pid = fork();
	if (pid == 0) {
		dup2(in[0], 0); dup2(o[1], 1); dup2(o[1], 2);
		execl("/bin/sh", "sh", "-c", command, (char *)NULL);
		_exit(127);
	}
	close(in[0]); close(o[1]);
	if (pid < 0) {
		close(in[1]); close(o[0]);
		return -1;
	}
	if (inputlen > 0 && write(in[1], input, inputlen) != inputlen) {
		close(in[1]); close(o[0]);
		waitpid(pid, NULL, 0);
		return -1;
	}
	close(in[1]);
	*out = o[0];
	return pid;
}

/* Reads the child's output from out to its end, keeping up to gotmax
   bytes (gotlen says how many in all), closes out, and waits for the
   child: its exit status, or -1 if it didn't exit normally. */
int32_t child_wait(int32_t pid, int64_t out, char *got, int64_t gotmax,
    int64_t *gotlen)
{
	char buf[4096];
	ssize_t n;
	int64_t len = 0;
	int status;

	while ((n = read((int)out, buf, sizeof buf)) > 0) {
		if (len < gotmax)
			memcpy(got + len, buf, n < gotmax - len ? n : gotmax - len);
		len += n;
	}
	close((int)out);
	*gotlen = len;
	if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status))
		return -1;
	return WEXITSTATUS(status);
}

/* Reads the child's output from out up to and including a newline, or
   until max - 1 bytes, into line, 0-terminated, waiting at most ms for
   each byte, and leaves the rest for child_wait: so a test learns
   the port a server it started is listening on. A byte at a time, so it
   never reads past the line. Its length, or -1 if the output ended or
   ms passed first. */
int32_t child_readline(int64_t out, char *line, int64_t max, int32_t ms)
{
	struct pollfd p = { .fd = (int)out, .events = POLLIN };
	int64_t n = 0;
	char c;

	while (n < max - 1) {
		if (poll(&p, 1, ms) != 1 || read((int)out, &c, 1) != 1)
			return -1;
		line[n++] = c;
		if (c == '\n')
			break;
	}
	line[n] = '\0';
	return (int32_t)n;
}

/* Ends a child that a test can't let finish by itself, such as a server
   waiting for connections that won't come; child_wait still reaps
   it. */
void child_kill(int32_t pid)
{
	kill(pid, SIGTERM);
}
