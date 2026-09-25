# Blit

**A native macOS utility that moves big files fast and verifies every byte.**

Blit moves data between three places, and does nothing else:

- **SFTP servers**, including high-latency ones on another continent
- **Local and external drives**
- **NAS shares** on the home network (SMB)

The name comes from *bit block transfer*: copy a block of memory as fast as the hardware allows.

> **Status:** pre-alpha. Benchmarking (M0) is complete and the PRD has had a technical review. Next up is the SSH spike (M1). The app itself hasn't been started yet. This README is the living product requirements document (PRD).

---

## Contents

1. [Why](#why)
2. [Goals and non-goals](#goals-and-non-goals)
3. [Target platform](#target-platform)
4. [Primary workflow](#primary-workflow)
5. [Design](#design)
6. [Requirements](#requirements)
7. [Performance targets](#performance-targets)
8. [Benchmark findings](#benchmark-findings)
9. [Architecture](#architecture)
10. [Reference environment](#reference-environment)
11. [Milestones](#milestones)
12. [Open questions](#open-questions)
13. [Repository layout](#repository-layout)
14. [Benchmark tools](#benchmark-tools)

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

## Design

**One minimal window that feels like Finder, with a transfer engine underneath.**

```
┌────────────────────────────────────────────────────────────────────┐
│ ● ● ●   ‹ ›   seedbox › downloads › 2026.09.16 Weekly Pack    ⌘K   │
├──────────────┬─────────────────────────────────────────────────────┤
│ Servers      │   Name             Date modified ▼  Size      Status│
│  ● seedbox   │ ▓ Main Week        Today 09:41      6.12 GB   64%   │
│ Drives       │   INDIE Week       Today 09:12      2.58 GB   ✓     │
│  Scratch SSD │ ▓ Manga Week       Yesterday        1.94 GB   queued│
│  Macintosh HD│   readme.nfo       Sep 16           4 KB            │
│ NAS          │ ▓                                                   │
│  RS1619xs+   │                                                     │
│  DS920+      │                                                     │
├──────────────┴─────────────────────────────────────────────────────┤
│ ↓ Main Week → Scratch SSD  ▬▬▬▬▬ ▬▬▬▬ ▬▬▬▬▬  58.4 MB/s · 3 conn    │
└────────────────────────────────────────────────────────────────────┘
  ▓ = alternating row background
```

### Principles

- **Finder's layout, with nothing new to learn.** A sidebar grouped into Servers, Drives, and NAS, and one file list. A second pane is one keystroke away and hidden by default.
- **Copy and paste starts a transfer.** ⌘C on the seedbox, then ⌘V on the SSD, is a parallel, verified download. Drag and drop works the same way.
- **⌘K jumps anywhere.** Fuzzy search across servers, drives, and recent folders.
- **One transfer strip at the bottom.** It shows the current job, one bar per connection, total speed, and time left. Click it to expand the full queue.
- **Quiet status.** A checkmark means verified. A dot in the sidebar shows connection health. There are no popups unless a decision is needed.
- **Standard controls.** Built from standard SwiftUI and AppKit components, so it picks up the macOS 27 look (Liquid Glass) automatically. A menu bar icon shows progress when the window is closed.

### Finder integration

Apple doesn't let third-party apps put their own interface in a Finder tab. What Blit does instead:

- **Quick Action (App Intents): "Blit to…"** Right-click reviewed files in Finder and send them to a NAS through Blit's verified copy engine. It's also available in Shortcuts. *(M4)*
- **Browse-only File Provider (later, low priority).** The seedbox would appear under Locations in Finder's sidebar, with downloads handed to Blit's engine. macOS's own File Provider transfers would lose parallel connections, split files, and checksums. File Provider files normally live on the boot drive. External APFS drives may be supported (to check), and exFAT drives aren't. Combined with the non-goal on Finder mounting, this stays low priority.

## Requirements

### Connections

- **R1.1** SFTP connections with password or SSH key auth. Secrets are stored in the Keychain.
- **R1.2** Per-server settings: host, port, username, starting path, maximum connections, and an optional separate **shell endpoint** for server-side checksums. Some servers run SFTP and shell on different ports with different path roots; see [findings](#benchmark-findings).
- **R1.3** Check host keys on first connect and pin them after that. Refuse to connect if a host key changes.
- **R1.4** Local and external volumes appear automatically. Blit notices when a drive is ejected mid-transfer and recovers when it reconnects.
- **R1.5** NAS shares mounted through macOS SMB are used as normal filesystem paths. Blit can save and remount favorite shares.
- **R1.6** A NAS entry can have an SSH endpoint, used to compute checksums on the NAS (R4.2). This requires SSH enabled in DSM and an account in the administrators group.

### Browser

- **R2.1** Two-pane browser, with any connection on either side.
- **R2.2** Keyboard-first: arrow keys, type-to-select, and copy with ⌘C or Return.
- **R2.3** Drag and drop between panes and to and from Finder.
- **R2.4** **Sort by date modified, newest first, by default.** Clicking a column header changes the sort. The choice is remembered per location, and the default is always newest at the top.
- **R2.5** **Alternating row backgrounds** in every file list, using the standard macOS alternating row colors so they match light and dark mode.
- **R2.6** Columns: Name, Date modified, Size, Status (queued, percent done, verified, failed). Columns can be shown, hidden, and resized.
- **R2.7** ⌘K command palette to jump to any server, drive, or recent folder.
- **R2.8** A single pane by default, with a keyboard shortcut to toggle a second pane.

### Transfer engine

- **R3.1** Download and copy recursively, preserving folder structure and modification times.
- **R3.2** **Parallel files:** N files in flight at once, N configurable per server.
- **R3.3** **Split files:** files above a size threshold are downloaded in byte-range chunks over several connections.
- **R3.4** **Deep request pipelining:** many SFTP read requests in flight per connection, and a large SSH channel window. **Shortened read replies are normal:** when a server returns fewer bytes than requested (SFTPGo caps replies at 32 KB), request the remainder and keep the pipeline full. Use `limits@openssh.com` to choose the read size where the server offers it (OpenSSH 8.5 and later). See [findings](#benchmark-findings).
- **R3.5** Write to `name.blitpart`, force it to disk, verify, then rename. A partial file is never visible under its final name. On local APFS or HFS+ volumes use `F_FULLFSYNC`. Over SMB, use `fsync`; `F_FULLFSYNC` isn't supported there, and the NAS-side checksum (R4.2) provides the guarantee.
- **R3.6** **Resume:** after a dropped connection, reconnect with backoff and resume from what's already on disk.
- **R3.7** Use large buffers that bypass the system cache (`F_NOCACHE`). Preallocate the destination (`F_PREALLOCATE`) on local volumes only; it's often unsupported over SMB.
- **R3.8** Use APFS clones (`clonefile`) for copies within the same volume.
- **R3.9** **Stability gate:** a remote file is eligible for download only once its size and modification time are unchanged across two checks, because files may still be written or assembled on the seedbox. If the size changed since listing, re-list; don't treat it as corruption.
- **R3.10** **Filename policy:** Linux allows any bytes in a filename, but APFS requires valid UTF-8 and treats different Unicode normalizations of a name as the same file, and SMB forbids some characters. Blit escapes names that can't be stored, detects names that would collide, and records the original name in the transfer log.
- **R3.11** **Timestamps:** SFTP v3 modification times are whole seconds. Comparisons (R2.4, R5.3) allow for that.

### Integrity

- **R4.1** **Remote to local:** compare the local file's SHA-256 with `sha256sum` run on the server over an SSH exec channel. This is the only way to get a remote hash: neither SFTPGo nor OpenSSH supports the SFTP `check-file` extension. Start the hash the moment a file finishes downloading, while it's still in the server's cache. Store hashes on the server under `~/.cache/blit/`, outside the download folders, keyed by path, size, and modification time, so a file is never hashed twice. Filenames are untrusted: pass them NUL-delimited over stdin (`xargs -0`) and never paste them into a shell command. If the server has no shell access, fall back to comparing sizes and warn.
- **R4.2** **Local to NAS:** hash the source while copying, then compare with `sha256sum` run **on the NAS** over SSH (R1.6), reusing R4.1's code. Reading the copy back over SMB isn't reliable: `F_NOCACHE` doesn't clear pages cached during the write, and the SMB client can answer reads from its local cache. So read-back is only a fallback, and is flagged as weaker, when a NAS has no SSH access. Verification can be switched off for trusted paths, but it's on by default.
- **R4.3** A mismatch re-downloads the affected file. Files are never silently accepted. Hashing each chunk on the server was ruled out, because reading ranges adds disk seeks on the server.
- **R4.4** Keep a per-transfer record (file, size, hash, source, destination, time) as an exportable log.

### Queue and UX

- **R5.1** The queue survives app restarts and reboots.
- **R5.2** Pause, resume, reorder, and cancel, per item and globally.
- **R5.3** When a file already exists, apply a rule per queue: skip, overwrite, keep both, or overwrite only if different (size and hash).
- **R5.4** Show live throughput per connection and overall, plus time remaining.
- **R5.5** Send a notification when a queue finishes or fails.
- **R5.6** Keep the Mac awake while transfers run.
- **R5.7** A menu bar icon shows overall progress and speed when the main window is closed.
- **R5.8** **Queue-wide disk space:** before starting each item, check the destination's free space against everything still queued for it. If it would run out, pause the queue; don't fail the file.

### Finder integration

- **R6.1** A "Blit to…" Quick Action (App Intents) for files selected in Finder, with destinations chosen from saved NAS and drive locations. It's also available in Shortcuts.
- **R6.2** *(Later, low priority)* A browse-only File Provider extension for servers. Downloads started from Finder go through Blit's engine. It's blocked on confirming whether File Provider can place files on an external drive (open question 7).

## Performance targets

Derived from the measurements below.

| Path | Target | Ceiling / notes |
|---|---|---|
| Remote → SSD, pack of many files | **≥ 55 MB/s** sustained | Remote disk: 86 MB/s for one reader. Measured 57 MB/s with 8 connections. |
| Remote → SSD, single large file | **≥ 50 MB/s** | Needs chunked downloads. Transmit manages 24.6 MB/s on one connection. |
| Remote, per connection | **≥ 24 MB/s** | Needs a larger in-flight window than OpenSSH's (OpenSSH: 10.7 MB/s). M1 exit criterion: more than 24.6 MB/s. |
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
2. **64 KB reads through SFTPGo collapsed to 0.36 MB/s, but the problem was lftp, not the server.** SFTPGo is built on `pkg/sftp`, which caps read replies at 32,768 bytes. A 64 KB request gets a shortened 32 KB reply, which the protocol allows, and lftp handles that badly. SFTPGo also doesn't support `limits@openssh.com`, so read-size discovery wouldn't help there. The fix is handling shortened replies correctly (R3.4). A client that does can use 64 KB requests against SFTPGo safely.
3. **OpenSSH's client caps each connection at about 10.7 MB/s** at 148 ms. That fits its fixed 2 MiB channel window (`CHAN_SES_WINDOW_DEFAULT` = 64 × 32 KB, which can't be changed). 2 MiB every 148 ms is about 14.2 MB/s at best. `sftp`'s `-B` and `-R` options add more requests in flight, but the window still caps the total.
4. **Transmit reached 24.6 MB/s on one connection,** which means about 3.6 MB in flight. Where the next ceiling sits is **unknown**. Linux counts buffer overhead against its TCP send-buffer limit, so a default 4 MB limit carries only about half that in data. Transmit's 3.6 MB means either the seedbox's buffers are already tuned above the default, or Transmit limits itself (a ~4 MB window inside the app). The M1 spike answers this.
5. **16 connections was slower than 8 (46.9 vs 57.1 MB/s), and the cause is unknown.** Possible causes: disk seeking from many readers, sshd's `MaxStartups` (default `10:30:100`) randomly dropping near-simultaneous logins, 16 logins at 148 ms eating into the 20-second test, or ordinary variation between single runs on a shared server. Through SFTPGo, 16 connections was level with 8 rather than slower. The target is **3–4 connections with large windows** either way, for fair use and because of the disk ceiling.
6. **The SFTP and shell endpoints use different path roots.** `/files/…` in SFTPGo is `~/files/…` over OpenSSH. Blit needs a per-server path mapping between them (R1.2).

### LAN

- The Mac's 2.5 GbE USB adapter negotiates **1000baseT**, because the core switch has only gigabit ports. Every wired path is limited to about 113 MB/s.
- SMB to both Synology units uses SMB 3.1.1 with signing and encryption off. **At 1 GbE**, no `/etc/nsmb.conf` tuning is needed, because the link is the bottleneck. That's unproven for the planned 10 GbE upgrade, where `nsmb.conf` settings and SMB multichannel can matter.

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
│    reads      │  • F_NOCACHE,         │  • NAS sha256sum over SSH    │
│  • chunked    │    F_PREALLOCATE      │    (read-back as fallback)   │
│    files      │                       │                              │
├───────────────┴───────────────────────┴──────────────────────────────┤
│  SSH transport: SwiftNIO SSH · SFTP v3 client (own) · Keychain       │
└──────────────────────────────────────────────────────────────────────┘
```

### SFTP engine design notes

- **Protocol:** SFTP version 3, which covers every server that matters.
- **Library: SwiftNIO SSH, with our own SFTP client.** SwiftNIO SSH sets each channel's window at the maximum packet size × 64. The default 128 KB packet gives an 8 MB window (about 54 MB/s at 148 ms). Raising the packet size to 256 KB gives 16 MB. There's no direct window setting. It supports key renegotiation (servers typically renegotiate every 1–4 GB, so 20 GB files depend on this) and AES-GCM, which matches the cipher plan.
- **Ruled out:** Citadel's SFTP client waits for each read before sending the next (no pipelining), so its wire-format types may be worth borrowing but not its read path. libssh2 has a fixed 2 MiB window, caps SFTP reads at 30,000 bytes, and gives no window control through its SFTP API, which puts it at OpenSSH's ~14 MB/s. It stays a fallback only if SwiftNIO SSH fails the M1 spike.
- **Per connection:** window ≥ 8 MB (packet size 128–256 KB), 64+ read requests in flight, and correct handling of shortened read replies (R3.4).
- **Scheduling:** a pool of up to N connections, 3–4 by default. Small files are spread across connections. Files over roughly 256 MB are split into chunks that share the same pool. A connection that finishes early takes remaining chunks from slower ones.
- **Auth:** password or key. Host keys are pinned.
- **Cipher:** prefer `aes128-gcm@openssh.com` (the server already negotiates it; it's hardware-accelerated on Apple Silicon). Compression is off.
- **Checksums:** use a second session to the shell endpoint to run `sha256sum` the moment each file finishes, and store the results in a hash cache (R4.1). The same code verifies NAS copies (R4.2).
- **Connection setup:** open connections a moment apart rather than all at once, to stay under sshd's `MaxStartups` limit.

### Local / SMB engine design notes

- For the same APFS volume, use `clonefile`. For large cross-volume copies, use a double-buffered loop with 4–8 MB buffers and `F_NOCACHE`, which hashes the source as it streams. `F_PREALLOCATE` and `F_FULLFSYNC` apply to local volumes only. Over SMB, use `fsync`.
- Verify NAS copies with `sha256sum` on the Synology over SSH (R4.2). An SMB read-back can be answered from the Mac's cache.
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
| **M1** | SSH spike | Throwaway code: raw SwiftNIO SSH channel throughput with a ≥ 8 MB window against the real server, then a minimal pipelined read loop that handles shortened replies, plus `sha256sum` over an exec channel (also check it on DSM). Fix the probe to time from first byte. **Done when one connection sustains more than 24.6 MB/s from the reference server.** This settles the library choice, the window ceiling, and the number of connections. | Next |
| **M2** | SFTP engine | Pipelined reads, connection pool with staggered setup, chunked files, remote checksums with hash cache, resume, stability gate, filename policy. Target ≥ 55 MB/s from the reference server. | |
| **M3** | Local engine | LocalCopyEngine, NAS-side checksums over SSH, `.blitpart` handling, queue-wide disk-space checks, command-line test harness. Target ≥ 105 MB/s SSD → NAS. | |
| **M4** | App | Finder-style browser (sorted newest first, alternating rows, ⌘K, optional second pane), transfer strip, durable queue, server editor, Keychain, host-key pinning, notifications, menu bar icon, "Blit to…" Quick Action | |
| **M5** | Hardening | Handling network changes, sleep and wake, drive ejection, transfer log export, signing and notarization | |

## Open questions

1. ~~**SSH library**~~ **Answered:** SwiftNIO SSH with our own SFTP client; libssh2 and Citadel were ruled out (see [SFTP engine design notes](#sftp-engine-design-notes)). M1 confirms it against the real server.
2. **Per-connection ceiling:** is Transmit's 24.6 MB/s its own limit, or the server's TCP buffers? The M1 spike measures it with 8 and 16 MB windows. If one connection can't beat about 25 MB/s, the design moves toward more connections.
3. **Fair use:** what the remote provider allows for simultaneous connections. Defaults should be modest (3–4).
4. **Server-side hashing cost:** reduced by hashing each file as soon as it finishes, while it's in the server's cache, and by the hash cache (R4.1). Measure the real impact on the seedbox's disk in M2.
5. **SMB at 10 GbE:** keep using the macOS SMB client with `nsmb.conf` and multichannel tuning, or embed `libsmb2` if measurements show the macOS client is the bottleneck after the upgrade.
6. **Uploads:** out of scope for v1, but the engine shouldn't rule them out.
7. **Browse-only File Provider:** worth it after v1? Handing downloads from the extension to Blit's engine is feasible. Still to check: whether File Provider on macOS 27 can place files on an external APFS drive rather than the boot drive, and how reliable it is.
8. **Connection ramp:** does the seedbox's sshd drop near-simultaneous logins above `MaxStartups`? M1 checks it by opening 8–16 connections at once and a moment apart.

## Repository layout

```
blit/
├── README.md             this document (the PRD)
└── scripts/
    ├── sftp-probe.sh     quick per-method SFTP speed probe (20 s each)
    └── sftp-bench.sh     longer parallel-file / chunked-file benchmark with checksums
```

Throwaway spike code arrives in M1. The Xcode project arrives with M2.

## Benchmark tools

Both scripts need `lftp` (`brew install lftp`). They prompt once for the password in the terminal. The password is passed only through environment variables and is never written to disk. Test downloads go to a temporary folder that's deleted afterward.

```bash
# Quick probe: one file, 20 s per method (OpenSSH sftp, lftp at 1/4/8/16 connections)
PORT=3232 SHELL_PORT=3232 scripts/sftp-probe.sh user@host "path/to/file.mkv"

# Full benchmark: a ~2.5 GB set of files, 1/4/8/16 files at once, SHA-256 checked against the server
PORT=3232 scripts/sftp-bench.sh user@host "path/to/folder/"
```

`SHELL_PORT` / `SSH_PORT` set the SSH shell endpoint used for the server's disk-read test and checksums, when it differs from the SFTP port. Connect once with `ssh -p PORT user@host` first, so the host key is trusted before running the scripts.

**Known limitation:** `sftp-probe.sh` starts timing before login, so higher connection counts pay more login time within the 20-second window. That understates their speed; fixing it to time from first byte is part of M1.

## License

TBD.
