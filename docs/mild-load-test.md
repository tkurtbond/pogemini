# A mild load test

On 2026-11-17, `contrib/load-test.py` was run against pogemini at
01a0d05, serving a local copy of a real capsule on Linux (Fedora,
x86_64), with the client on the same machine:

    pogemini -host localhost -listen localhost -root .../gmi -port 1965
    contrib/load-test.py localhost 1965 1,8,32,64 15 <pid>

The script crawls the capsule from `gemini://localhost/` (196 pages and
files here), then, for each level, runs that many clients for 15 s,
each fetching random URLs from the crawl one after another with no
pause, a new TLS connection per request.

## Results

About 150,000 requests in all, every one answered `20`, with no errors
and no timeouts.

| Clients | req/s | MB/s | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| 1 | 1,403 | 403 | 0.6 ms | 1.2 ms | 1.6 ms | 4 ms |
| 8 | 2,935 | 842 | 2.6 ms | 3.8 ms | 4.6 ms | 13 ms |
| 32 | 2,684 | 772 | 8.1 ms | 10.8 ms | 12.5 ms | 2.1 s |
| 64 | 2,607 | 748 | 10.3 ms | 13.9 ms | 1.0 s | 2.3 s |

- **Resources stayed flat.** The server's resident memory stayed
  between 9 and 11 MiB, and it held 7 open file descriptors before and
  after every level: nothing leaked.
- **Throughput levels off at about 8 clients.** The server runs in a
  single thread, with tasks, so this is close to what one CPU core does
  with a TLS handshake for every request. It is far above any real
  Gemini traffic.
- **The 1–2 s outliers at 32 and 64 clients come from the listen queue,
  not the server's work.** `GemServer.Listen` passes a backlog of 16 to
  `Sockets.Listen`, so the kernel queues only 16 connections waiting to
  be accepted. During a 10 s run at 64 clients, `nstat` counted 380
  `TcpExtListenOverflows` (and as many `TcpExtListenDrops`). Each
  dropped SYN is retried by the client's TCP after 1 s, then 3 s, which
  are exactly the outliers.

## The backlog raised to 128

The backlog of 16 was smaller than `-connections` (256 by default), so
under a burst a client could wait for a SYN retry rather than in the
queue, as pogemini(1) describes. With it raised to 128, the 64-client
level was run twice for each backlog, on another port, the same
capsule, counting the kernel's drops with `nstat`:

| Backlog | req/s | Drops | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| 16 | 2,699 / 2,662 | 590 / 567 | 9.9 ms | 12.7 ms | 1,021 ms | 3,070 ms |
| 128 | 2,716 / 2,759 | 0 / 0 | 23 ms | 27 ms | 30–35 ms | 93–128 ms |

- **No drops, so no retries:** the worst request took about 0.1 s
  instead of 3 s.
- **Throughput is unchanged**, about 2,700 requests a second: the
  queue changes how clients wait, not how fast they are served.
- **The median rose from 10 to 23 ms, and that is the honest figure.**
  With 16, many clients were at any moment sleeping in a SYN retry, so
  fewer competed; with 128, all 64 wait their turn, and 64 clients at
  2,750 requests a second is 23 ms each.
- The server's resident memory rose from 10–11 MiB to 12 MiB, serving
  more connections at once; it still held 7 file descriptors.

`make test` passed with the change, and pogemini now passes 128. It
matters little for real Gemini traffic, which rarely has 16 handshakes
arriving at once. The kernel caps the backlog (`net.core.somaxconn`,
4096 here on Linux); the BSD hosts' caps have not been checked.

## Running it again

    contrib/load-test.py [host [port [levels [seconds [pid]]]]]

The pid, if given, makes it report the server's memory and open file
descriptors from `/proc`, so only on Linux; without it the script runs
anywhere with Python 3. To check for listen-queue overflows on Linux,
run `nstat -n` before and `nstat -z TcpExtListenOverflows
TcpExtListenDrops` after. The script doesn't verify certificates and
sends no client certificate, so it fetches only what needs none.
