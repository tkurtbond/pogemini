#!/usr/bin/env python3
"""A mild concurrent load test of a Gemini server.

Usage: load-test.py [host [port [levels [seconds [pid]]]]]

  host     the server, and the SNI and URL host (default localhost)
  port     default 1965
  levels   comma-separated numbers of clients at once (default 1,8,32,64)
  seconds  how long each level runs (default 15)
  pid      the server's process, to report its memory and open file
           descriptors from /proc (Linux only; omit to skip)

It crawls the capsule from gemini://host/ (links on the same host, at
most 300 URLs), then, for each level, runs that many clients, each
fetching random URLs from the crawl one after another, a new TLS
connection per request, without verifying the certificate.  It prints
requests per second, bytes per second, latency percentiles, the status
codes and any errors.  docs/mild-load-test.md has a run and what it
showed.
"""
import os, random, re, socket, ssl, sys, threading, time
import urllib.parse
from urllib.parse import urljoin, urlparse

# urljoin resolves relative links only for schemes it knows.
urllib.parse.uses_relative.append("gemini")
urllib.parse.uses_netloc.append("gemini")

args = sys.argv[1:]
HOST = args[0] if len(args) > 0 else "localhost"
PORT = int(args[1]) if len(args) > 1 else 1965
LEVELS = [int(x) for x in (args[2] if len(args) > 2 else "1,8,32,64").split(",")]
SECS = float(args[3]) if len(args) > 3 else 15.0
PID = int(args[4]) if len(args) > 4 else None

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def fetch(url):
    """Fetch url; return (header line, body, seconds taken)."""
    t = time.monotonic()
    with socket.create_connection((HOST, PORT), timeout=15) as s:
        with ctx.wrap_socket(s, server_hostname=HOST) as ts:
            ts.sendall((url + "\r\n").encode())
            chunks = []
            while True:
                b = ts.recv(65536)
                if not b:
                    break
                chunks.append(b)
    data = b"".join(chunks)
    hdr, _, body = data.partition(b"\r\n")
    return hdr.decode(errors="replace"), body, time.monotonic() - t


def server_stats():
    if PID is None:
        return ""
    try:
        st = open(f"/proc/{PID}/status").read()
        rss = int(re.search(r"VmRSS:\s+(\d+)", st).group(1))
        fds = len(os.listdir(f"/proc/{PID}/fd"))
        return f"; server rss={rss // 1024} MiB fds={fds}"
    except Exception as e:
        return f"; server stats unavailable ({e})"


def crawl():
    base = f"gemini://{HOST}/" if PORT == 1965 else f"gemini://{HOST}:{PORT}/"
    seen, queue, urls = {base}, [base], []
    while queue and len(urls) < 300:
        u = queue.pop(0)
        try:
            h, body, _ = fetch(u)
        except Exception as e:
            print("crawl error", u, e)
            continue
        if h[:1] != "2":
            print("crawl:", u, "answered", h)
            continue
        urls.append(u)
        if "text/gemini" not in h:
            continue
        for line in body.decode(errors="replace").splitlines():
            if not line.startswith("=>"):
                continue
            parts = line[2:].split()
            if not parts:
                continue
            v = urljoin(u, parts[0])
            p = urlparse(v)
            if (p.scheme == "gemini" and p.hostname == HOST
                    and (p.port or 1965) == PORT and v not in seen):
                seen.add(v)
                queue.append(v)
    return urls


def run_level(n, urls):
    lat, statuses, errors, nbytes = [], {}, {}, [0]
    lock = threading.Lock()
    stop = time.monotonic() + SECS

    def worker():
        r = random.Random()
        while time.monotonic() < stop:
            u = r.choice(urls)
            try:
                h, body, dt = fetch(u)
                with lock:
                    lat.append(dt)
                    nbytes[0] += len(body)
                    statuses[h[:2]] = statuses.get(h[:2], 0) + 1
            except Exception as e:
                with lock:
                    k = type(e).__name__
                    errors[k] = errors.get(k, 0) + 1

    ts = [threading.Thread(target=worker) for _ in range(n)]
    t0 = time.monotonic()
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    el = time.monotonic() - t0
    lat.sort()

    def q(p):
        return lat[min(len(lat) - 1, int(p * len(lat)))] * 1000 if lat else 0

    print(f"c={n:3d}: {len(lat)} ok in {el:.1f}s = {len(lat) / el:.0f} req/s, "
          f"{nbytes[0] / el / 1e6:.1f} MB/s; ms p50={q(.5):.1f} p95={q(.95):.1f} "
          f"p99={q(.99):.1f} max={q(1):.1f}; status={statuses} errors={errors}"
          f"{server_stats()}")


def main():
    urls = crawl()
    if not urls:
        sys.exit(f"nothing to fetch at gemini://{HOST}:{PORT}/")
    print(f"crawled {len(urls)} URLs{server_stats()}")
    for n in LEVELS:
        run_level(n, urls)
    time.sleep(2)
    print(f"after{server_stats() or ': done'}")


if __name__ == "__main__":
    main()
