# Blit

**A native macOS utility that moves big files fast and verifies every byte.**

Blit moves data between three places, and does nothing else:

- **SFTP servers**, including high-latency ones on another continent
- **Local and external drives**
- **NAS shares** on the home network (SMB)

The name comes from *bit block transfer*: copy a block of memory as fast as the hardware allows.

> **Status:** pre-alpha. The benchmarking phase (M0) is complete. The app itself hasn't been started yet. This README is the living product requirements document (PRD).

---

## Contents

1. [Why](#why)
2. [Goals and non-goals](#goals-and-non-goals)
3. [Target platform](#target-platform)
4. [Primary workflow](#primary-workflow)
5. [Requirements](#requirements)
6. [Performance targets](#performance-targets)
7. [Benchmark findings](#benchmark-findings)
8. [Architecture](#architecture)
9. [Reference environment](#reference-environment)
10. [Milestones](#milestones)
11. [Open questions](#open-questions)
12. [Repository layout](#repository-layout)
13. [Benchmark tools](#benchmark-tools)

---

## Why

Transmit (Panic) and ForkLift (Binary Nights) are great apps, but both have become unreliable on recent macOS releases. Most of what they do goes unused here: cloud providers, sync, and mounting remote servers as disks.

The real job is narrow and heavy: **about 27–30 TB a month**, roughly 75% of it downloaded from a remote SFTP server in Europe (~148 ms round-trip time). Files then land on an external SSD for review and finally move to a NAS. At that volume, the transfer engine is the product:

- Throughput is the top priority.
- Silent corruption is unacceptable.
- The app must recover from dropped connections unattended.

## Goals and non-goals

### Goals

- **Saturate whatever the bottleneck actually is.** That's the remote server's disk or plan limit, the WAN, the LAN, or the destination disk, never the client.
- **Verify every file end to end,** with checksums from the source.
- **Survive dropped connections, sleep, and restarts** without losing progress or leaving half-written files.
- **Feel native and stay out of the way:** fast launch, a two-pane browser, a transfer queue, and no clutter.

### Non-goals

- Cloud storage (S3, Dropbox, Google Drive, WebDAV)
- FTP or FTPS
- Two-way sync
- Mounting remote servers in Finder (File Provider or FUSE). This is a common source of instability in comparable apps.
- Remote file editing
- Mac App Store distribution
- Support for macOS versions before 27, or for Intel Macs

## Target platform

| | |
|---|---|
| OS | macOS 27 only |
| Hardware | Apple Silicon only |
| Language / UI | Swift 6, SwiftUI (AppKit where SwiftUI falls short) |
| Distribution | Developer ID signed and notarized. Not App Store, not sandboxed. |
| Credentials | Keychain |

Targeting only the latest macOS means no compatibility code for older versions. Skipping the sandbox avoids permission friction for external volumes and network mounts.

## Primary workflow

```
remote SFTP server ──(parallel SFTP, verified)──▶ external SSD ──(review)──▶ NAS (SMB)
```

1. Browse the remote server and queue a folder (for example, a weekly pack) or individual files.
2. Blit downloads to the external SSD using several connections at once, splitting large files into chunks.
3. Each file is checked against a SHA-256 computed on the server. Only then does it get its final name.
4. After manual review, move the files from the SSD to the NAS in one step, with verification.

## Requirements

### Connections

- **R1.1** SFTP connections with password or SSH key auth. Secrets are stored in the Keychain.
- **R1.2** Per-server settings: host, port, username, starting path, maximum connections, and an optional separate **shell endpoint** for server-side checksums. Some servers run SFTP and shell on different ports with different path roots; see [findings](#benchmark-findings).
- **R1.3** Check host keys on first connect and pin them after that. Refuse to connect if a host key changes.
- **R1.4** Local and external volumes appear automatically. Blit notices when a drive is ejected mid-transfer and recovers when it reconnects.
- **R1.5** NAS shares mounted through macOS SMB are used as normal filesystem paths. Blit can save and remount favorite shares.

### Browser

- **R2.1** Two-pane browser, with any connection on either side.
- **R2.2** Keyboard-first: arrow keys, type-to-select, and copy with ⌘C or Return.
- **R2.3** Drag and drop between panes and to and from Finder.

### Transfer engine

- **R3.1** Download and copy recursively, preserving folder structure and modification times.
- **R3.2** **Parallel files:** N files in flight at once, N configurable per server.
- **R3.3** **Split files:** files above a size threshold are downloaded in byte-range chunks over several connections.
- **R3.4** **Deep request pipelining:** many SFTP read requests in flight per connection, and a large SSH channel window. Read size adapts to the server; see [findings](#benchmark-findings).
- **R3.5** Write to `name.blitpart`, force it to disk (`F_FULLFSYNC`), verify, then rename. A partial file is never visible under its final name.
- **R3.6** **Resume:** after a dropped connection, reconnect with backoff and resume from what's already on disk.
- **R3.7** Preallocate the destination file, and use large buffers that bypass the system cache (`F_NOCACHE`) for local and SMB copies.
- **R3.8** Use APFS clones (`clonefile`) for copies within the same volume.

### Integrity

- **R4.1** **Remote to local:** compare the local file's SHA-256 with `sha256sum` run on the server over an SSH exec channel. If the server has no shell access, fall back to comparing sizes and warn.
- **R4.2** **Local to NAS:** hash while copying, then re-read the destination with caching off and compare. Verification can be switched off for trusted paths, but it's on by default.
- **R4.3** A mismatch re-downloads only the affected file, or the affected chunks when chunk hashes are available. Files are never silently accepted.
- **R4.4** Keep a per-transfer record (file, size, hash, source, destination, time) as an exportable log.

### Queue and UX

- **R5.1** The queue survives app restarts and reboots.
- **R5.2** Pause, resume, reorder, and cancel, per item and globally.
- **R5.3** When a file already exists, apply a rule per queue: skip, overwrite, keep both, or overwrite only if different (size and hash).
- **R5.4** Show live throughput per connection and overall, plus time remaining.
- **R5.5** Send a notification when a queue finishes or fails.
- **R5.6** Keep the Mac awake while transfers run.

## Performance targets

Derived from the measurements below.

| Path | Target | Ceiling / notes |
|---|---|---|
| Remote → SSD, pack of many files | **≥ 55 MB/s** sustained | Remote disk: 86 MB/s for one reader. Measured 57 MB/s with 8 connections. |
| Remote → SSD, single large file | **≥ 50 MB/s** | Needs chunked downloads. Transmit manages 24.6 MB/s on one connection. |
| Remote, per connection | **≥ 24 MB/s** | Needs a larger in-flight window than OpenSSH's (OpenSSH: 10.7 MB/s). |
| SSD → NAS, today (1 GbE) | **≥ 105 MB/s** | Link maximum is about 113 MB/s. |
| SSD → NAS, after the 10 GbE upgrade | Limited by the NAS disks | See [reference environment](#reference-environment). |
| Integrity | 100% of files verified | Zero silent corruption |

At about 55 MB/s, 22.5 TB a month takes about **4.7 days** of downloading. That compares with about 24.5 days on one standard connection, and about 9.6 days through the provider's SFTPGo endpoint.

## Benchmark findings

Measured on 2026-09-24 from the [reference environment](#reference-environment) with [`scripts/sftp-probe.sh`](scripts/sftp-probe.sh). Each method ran for up to 20 seconds.

### Remote server, SFTPGo endpoint (216 MB file)

| Method | MB/s |
|---|---:|
| OpenSSH `sftp`, 1 connection | 10.6 |
| lftp, 1 connection, defaults (16 × 32 KB requests in flight) | 2.9 |
| lftp, 1 connection, 64 × 32 KB | 10.7 |
| lftp, 1 connection, 64 × 64 KB | **0.36** |
| lftp, 4 connections (32 KB) | 21.9 |
| lftp, 8 connections (32 KB) | 26.7 |
| lftp, 16 connections (32 KB) | 26.2 |

### Same server, OpenSSH endpoint (923 MB file)

| Method | MB/s |
|---|---:|
| Server disk read (`dd`, one reader) | 86.1 |
| OpenSSH `sftp`, 1 connection | 10.7 |
| lftp, 1 connection, defaults | 2.8 |
| lftp, 1 connection, 64 × 32 KB | 10.6 |
| lftp, 1 connection, 64 × 64 KB | 10.9 |
| lftp, 4 connections | 43.6 |
| **lftp, 8 connections** | **57.1** |
| lftp, 16 connections | 46.9 |
| Transmit 5, 1 connection, 19.8 GB file | 24.6 |

### What the numbers mean

1. **The SFTPGo endpoint was the ceiling, not the server.** It levels off around 27 MB/s. Over OpenSSH on the same machine, speed scales almost linearly up to 8 connections.
2. **SFTPGo handles 64 KB reads badly.** Throughput fell about 30× (0.36 MB/s). OpenSSH handles 64 KB reads fine. Blit must discover each server's read size (the `limits@openssh.com` extension where supported) and fall back to 32 KB.
3. **OpenSSH's client caps each connection at about 10.7 MB/s** at 148 ms. That fits its ~2 MB channel window: 2 MB every 148 ms is about 13.5 MB/s at best.
4. **Transmit reached 24.6 MB/s on one connection,** which means about 3.6 MB in flight. A custom client can raise the window further. The next limit is probably the server's TCP send buffer (Linux's default maximum is 4 MB, which would be about 27 MB/s here). That last point is a hypothesis to confirm in M2.
5. **16 connections is slower than 8.** Many readers at different offsets likely make the server's hard drives seek. The target is **3–4 connections with large windows**, which should reach the disk ceiling with less load on a shared server.
6. **The SFTP and shell endpoints use different path roots.** `/files/…` in SFTPGo is `~/files/…` over OpenSSH. Blit needs a per-server path mapping between them (R1.2).

### LAN

- The Mac's 2.5 GbE USB adapter negotiates **1000baseT**, because the core switch has only gigabit ports. Every wired path is limited to about 113 MB/s.
- SMB to both Synology units uses SMB 3.1.1 with signing and encryption off, which is already the fastest configuration. No `/etc/nsmb.conf` tuning is needed.

## Architecture

```
┌──────────────────────────── SwiftUI app ─────────────────────────────┐
│  Browser (two panes)      Queue view      Server editor     Settings │
└───────────────┬──────────────────────────────────────────────────────┘
                │ async/await, AsyncSequence progress
┌───────────────▼──────────────────────────────────────────────────────┐
│  TransferCoordinator — scheduling, concurrency limits, retries, log  │
│  Queue store (SQLite) — durable jobs, chunk maps, resume state       │
├───────────────┬───────────────────────┬──────────────────────────────┤
│  SFTPEngine   │  LocalCopyEngine      │  Verifier                    │
│  • connection │  • copyfile / clone   │  • SHA-256 (CryptoKit)       │
│    pool       │  • large overlapped   │  • remote sha256sum          │
│  • pipelined  │    reads and writes   │    over SSH exec             │
│    reads      │  • F_NOCACHE,         │  • read-back verification    │
│  • chunked    │    F_PREALLOCATE      │    for local/SMB copies      │
│    files      │                       │                              │
├───────────────┴───────────────────────┴──────────────────────────────┤
│  SSH transport (SwiftNIO SSH or libssh2, decided in M2) · Keychain   │
└──────────────────────────────────────────────────────────────────────┘
```

### SFTP engine design notes

- **Protocol:** SFTP version 3, which covers every server that matters.
- **Per connection:** a large channel window (start at 16 MB and tune), 64+ read requests in flight, and read size discovered per server (32 KB fallback).
- **Scheduling:** a pool of up to N connections, 3–4 by default. Small files are spread across connections. Files over roughly 256 MB are split into chunks that share the same pool. A connection that finishes early takes remaining chunks from slower ones.
- **Auth:** password or key. Host keys are pinned.
- **Cipher:** prefer `aes128-gcm@openssh.com` (the server already negotiates it; it's hardware-accelerated on Apple Silicon). Compression is off.
- **Checksums:** use an optional second session to the shell endpoint to run `sha256sum`, in parallel with other downloads.

### Local / SMB engine design notes

- For the same APFS volume, use `clonefile`. For large cross-volume copies, use a double-buffered loop with 4–8 MB buffers, `F_NOCACHE` on both ends, and `F_PREALLOCATE`. That lets verification hash as data streams, without reading the source again.
- For many small files, run 4–8 file copies at once. For large ones, copy one file at a time with deep buffering.

## Reference environment

The setup Blit is tuned against:

| Component | Details | Limit today |
|---|---|---|
| Mac | Mac mini M2 Pro (`Mac14,12`), macOS 27, 4× Thunderbolt 4 | Built-in Ethernet is 1 GbE only |
| Mac NIC | USB-C 2.5 GbE adapter | Negotiates 1 GbE (switch limit) |
| Router | UniFi Dream Machine Pro | 10G SFP+ LAN port unused |
| Core switch | UniFi USW-24-PoE | Gigabit copper ports |
| NAS 1 | Synology RS1619xs+, main switch | 4× 1 GbE, **PCIe slot (10 GbE capable)** |
| NAS 2 | Synology DS920+, behind a USW Flex Mini | 2× 1 GbE, no PCIe slot |
| WAN | AT&T Fiber, 1 Gbps symmetrical | ~110 MB/s |
| Remote | SFTP server in Europe, ~148 ms round-trip time | ~57 MB/s measured (8 connections) |

**Recommended LAN upgrade** (the biggest SSD → NAS gain, independent of the app):

1. A Thunderbolt 10 GbE adapter for the Mac.
2. A 10 GbE PCIe card for the RS1619xs+, from Synology's compatibility list.
3. A small 10 GbE switch for those two, connected to the UDM Pro's 10G SFP+ LAN port.
4. Move the DS920+ off the Flex Mini onto the core switch. It stays a 1 GbE archive box.

## Milestones

| | Milestone | Scope | Status |
|---|---|---|---|
| **M0** | Benchmarks | Measure the network ceilings, find the bottlenecks, validate the approach | ✅ Done |
| **M1** | Local engine | Xcode project, LocalCopyEngine, Verifier, `.blitpart` handling, command-line test harness. Target ≥ 105 MB/s SSD → NAS. | Next |
| **M2** | SFTP engine | Evaluate SwiftNIO SSH vs libssh2, then build pipelined reads, window tuning, connection pool, chunked files, remote checksums, resume. Target ≥ 55 MB/s from the reference server. | |
| **M3** | App | Two-pane browser, durable queue, server editor, Keychain, host-key pinning, notifications | |
| **M4** | Hardening | Handling network changes, sleep and wake, drive ejection, transfer log export, signing and notarization | |

## Open questions

1. **SSH library:** SwiftNIO SSH (pure Swift, async, but needs a hand-written SFTP layer and control over window sizes) or libssh2 (proven SFTP support, C interop, historically limited pipelining). Decide with a spike in M2.
2. **Window ceiling:** is 24.6 MB/s per connection a server TCP-buffer limit (~4 MB) or a client choice? Measure with a custom client and a 16 MB+ window.
3. **Fair use:** what the remote provider allows for simultaneous connections. Defaults should be modest (3–4).
4. **Server-side hashing cost:** `sha256sum` reads each file again from the server's disk, adding load to the 86 MB/s ceiling. Options: hash on the server while the download runs (so the file may already be in the server's cache), or hash per chunk.
5. **SMB engine:** keep using the macOS SMB client, or embed `libsmb2` if measurements show the macOS client is the bottleneck after the 10 GbE upgrade.
6. **Uploads:** out of scope for v1, but the engine shouldn't rule them out.

## Repository layout

```
blit/
├── README.md             this document (the PRD)
└── scripts/
    ├── sftp-probe.sh     quick per-method SFTP speed probe (20 s each)
    └── sftp-bench.sh     longer parallel-file / chunked-file benchmark with checksums
```

The Xcode project will be added in M1.

## Benchmark tools

Both scripts need `lftp` (`brew install lftp`). They prompt once for the password in the terminal. The password is passed only through environment variables and is never written to disk. Test downloads go to a temporary folder that's deleted afterward.

```bash
# Quick probe: one file, 20 s per method (OpenSSH sftp, lftp at 1/4/8/16 connections)
PORT=3232 SHELL_PORT=3232 scripts/sftp-probe.sh user@host "path/to/file.mkv"

# Full benchmark: a ~2.5 GB set of files, 1/4/8/16 files at once, SHA-256 checked against the server
PORT=3232 scripts/sftp-bench.sh user@host "path/to/folder/"
```

`SHELL_PORT` / `SSH_PORT` set the SSH shell endpoint used for the server's disk-read test and checksums, when it differs from the SFTP port. Connect once with `ssh -p PORT user@host` first, so the host key is trusted before running the scripts.

## License

TBD.
