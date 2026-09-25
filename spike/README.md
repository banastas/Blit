# blit-spike (M1)

Throwaway code that answered M1's questions: can SwiftNIO SSH plus a hand-written, pipelined SFTP v3 client beat Transmit's 24.6 MB/s on one connection to a server 148 ms away? It did: **42.9 MB/s on one connection, and ~90 MB/s on 3, verified against the server's SHA-256.** Full results and conclusions are in the repo [README](../README.md#m1-spike-results).

This isn't the engine. M2 rewrites it properly.

## Build

```bash
swift build -c release    # Command Line Tools are enough
```

## Modes

```bash
B=.build/release/blit-spike

$B hostkey user@host:port                           # show the host key and whether it's trusted (no login)
$B raw     user@host:port path --packet 256 --rcvbuf 7168     # `cat` over SSH: channel throughput, no SFTP
$B sftp    user@host:port path --requests 32 --read 255 --rcvbuf 7168 --packet 256
$B sftp    user@host:port path --conns 3 --seconds 0 --out /tmp/f   # full split download, then verify
$B hash    user@host:port path                      # sha256sum on the server, path sent over stdin
```

The password comes from `$BLIT_PASSWORD` or a prompt. The host key must be in `~/.ssh/known_hosts`, or pinned for the run with `--trust SHA256:…`. Run `blit-spike` with no arguments for all options.

## Test runners

- `run-m1.sh`: the main matrix covering window sizes, receive buffer, request depth, and connection counts, plus a verified full download.
- `run-m1b.sh`: follow-ups covering SFTPGo short reads, 255 KB reads, and disk-write cost.

Both prompt once for the password and keep it only in the process environment.
