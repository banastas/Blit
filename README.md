# Blit

**A native macOS utility that moves big files fast and verifies every byte.**

Blit moves data between three places, and does nothing else:

- **SFTP servers**, including high-latency ones on another continent
- **Local and external drives**
- **NAS shares** on the home network (SMB)

The name comes from *bit block transfer*: copy a block of memory as fast as the hardware allows.

> **Status:** 0.1, M0–M5 complete. Blit is a notarized native Mac app: parallel, resumable seedbox downloads verified against the server's SHA-256, SSD → NAS copies at wire speed verified on the NAS, a Finder-style browser with favorites and drag-to-transfer, the pixel-terminal transfer HUD, a durable queue that survives quits and network drops, a menu bar extra, ⌘K and Finder integration. The `blit` command-line tool exposes the same engine. This README is the living product requirements document (PRD).

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
14. [Building](#building)
15. [Benchmark tools](#benchmark-tools)

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
│ ● ● ●   ‹ ›   seedbox:~/files/downloads/2026.09.16 Weekly Pack  ⌘K │
├──────────────┬─────────────────────────────────────────────────────┤
│ Favorites    │   Name             Modified ▼       Size      Status│
│  Incoming    │ ▓ Main Week        today 09:41      6.12 GB   64%   │
│ ⇣Movies      │   INDIE Week       today 09:12      2.58 GB   ✓     │
│  TV          │ ▓ Manga Week       yesterday        1.94 GB   queued│
│ Servers      │   readme.nfo       sep 16           4 KB            │
│  ● seedbox   │ ▓                                                   │
│ Drives       │                                                     │
│  Photography │                                                     │
│ NAS          │                                                     │
│  Media       │                                                     │
├──────────────┴─────────────────────────────────────────────────────┤
│ ↓ Main Week → Incoming  ▬▬▬▬▬ ▬▬▬▬ ▬▬▬▬▬  74.1 MB/s · 3 conn       │
│   09:43:07 ✓ sha256 ef61845e… verified (cached on server)          │
└────────────────────────────────────────────────────────────────────┘
  ▓ = alternating row background   ⇣ = drop target (dragging onto a favorite)
```

### Principles

- **Finder's layout, with nothing new to learn.** A sidebar grouped into Servers, Drives, and NAS, and one file list. A second pane is one keystroke away and hidden by default.
- **Copy and paste starts a transfer.** ⌘C on the seedbox, then ⌘V on the SSD, is a parallel, verified download. Drag and drop works the same way.
- **⌘K jumps anywhere.** Fuzzy search across servers, drives, and recent folders.
- **One transfer strip at the bottom.** It shows the current job, one bar per connection, total speed, and time left. Click it to expand the full queue.
- **Quiet status.** A checkmark means verified. A dot in the sidebar shows connection health. There are no popups unless a decision is needed.
- **Favorites are drop targets.** The sidebar's Favorites section pins key folders on any location (an SSD folder, `Media › Movies` on the NAS, a folder on the seedbox). Dropping files on one transfers them there with the right engine and the same verification.
- **Standard controls.** Built from standard SwiftUI and AppKit components, so it picks up the macOS 27 look (Liquid Glass) automatically. A menu bar icon shows progress when the window is closed.

### Visual language

**Native macOS everywhere, with one instrument panel that has its own character.** Following Apple's Human Interface Guidelines matters more than a theme.

- **Browser, sidebar, sheets and settings are standard macOS:** system controls, SF Pro and SF Symbols, standard row heights and native alternating row colors, as in the original layout.
- **Follows the system appearance** (light or dark); nothing is forced.
- **Selection and focus use the system accent color.** For an all-grey look, choose the *Graphite* accent in System Settings → Appearance and Blit follows it.
- **Numbers use monospaced digits** (SF Pro, like Finder) so sizes and dates line up; SF Mono only for hashes and paths in the log.
- **The transfer HUD is the one exception** (below): a bounded, always-dark, 1-bit pixel-terminal panel, like an instrument built into the window.
- **Muted red (#b35c5c) only for failures,** in both the native UI and the HUD. Status is never carried by color alone: every state also has a glyph or word.

### Transfer HUD

The transfer strip expands into a 1-bit, pixel-terminal HUD (references: 1-bit pixel art, pixel icon sets, the *Alien* Nostromo interface).

**Condensed (default), two lines:**
1. `▲ 02/05` transfer count (click to expand) · item `→` destination · 24-cell segmented progress · percent · mini 30-second throughput histogram · large rate · one square per active connection (or file stream), with a short link summary (`3× · 148MS` for SFTP, `SMB · EN7` for copies).
2. The latest log line: verification results, resumes, ETA.

A failure adds a compact red `✕ N warning` tag in the top line (in place of the histogram) and turns the log line muted red; clicking it opens the full HUD at the WARNING panel.

**Pixel accents outside the HUD** (status and motion only; everything you read or click stays native):
- **Menu bar:** a pixel arrow into a tray; its stem's dashes march down while a transfer runs.
- **Dock icon:** a strip of pixel progress cells while transferring; a pixel ✓ for five seconds when a batch finishes verified.
- **Verified badge:** a small pixel ✓ after the names of local files Blit copied and verified by SHA-256 (server, NAS or read-back), from the transfer log, while their size still matches; hover for how and when. Renames and moves in Blit keep it for the session.
- **Spinners:** a pixel dot chasing round a 3×3 ring (Refreshing…, expanding folders, first load).
- **Drop targets:** pixel marching ants instead of a dashed outline.
- **NAS verification shield:** a pixel shield with a check knocked out.
- **About Blit:** the pixel-terminal style, with version and build.

**Results that need attention:** a finished transfer with files that were only size-checked reads `= … · N SIZE ONLY, NOT HASH-VERIFIED` in muted red (not a ✓), and its notification says so. When the queue drains, the Dock icon keeps a pixel ✓ (all verified) or a muted-red ✕ (problems) until you're back in Blit. Settings › Notifications: each transfer (default), or only when the queue finishes (a summary: transfers, size, problems) plus problems, size-only results and disk-space waits, which always notify. ETAs read "5:12:03" past an hour and "~2 d 4 h" past a day; the menu bar panel shows how many more are queued.

**Sidebar status:** each server's browsing connection shows as 7×7 pixel signal bars: all lit when connected, filling left to right in a loop while connecting, dim when not connected, and a pixel ✕ in muted red on failure (hover for the reason).

**Expanded:** the full HUD described below. It opens by itself when a transfer starts (Settings; collapsing it keeps it collapsed until that batch finishes). File operations (delete, move…) only use the condensed strip. Switching between the two, or the HUD appearing and leaving, animates like a CRT: a bright line sweeps out, then opens vertically.

**Layout:** the HUD and strip float over the bottom of the window (an overlay), with matching space reserved below the file list. As a safe-area inset, every HUD update during a download (the percent ticking) re-sized the window's content; macOS then briefly reported a shorter toolbar for one layout pass and the list and HUD jumped.

**Verification progress:** the seedbox starts hashing each file when its first range is handed out, so the hash reads the file alongside the download instead of re-reading it cold afterwards. Where the server's `dd` supports `status=progress` (GNU coreutils), it reports bytes hashed about once a second. The HUD shows a *Server SHA256* row per file, the hash rate, and a verify ETA. Once only checksums remain, the strip's progress cells, percent and log line switch to verification progress, and the histogram shows the hash rate.

**Menu bar panel:** the condensed HUD stacked into a 320-pt column: count and item, destination, progress, big rate or SHA256 with ETA, and a warning tag.

- **Type:** pixel uppercase for labels (Silkscreen) and large terminal numerals for readouts (VT323). Both are SIL Open Font License, so they can be bundled with the app. The file browser keeps the system font and SF Mono.
- **Panels:** boxed readouts with 1-pixel borders: *Item* (name, route, segmented progress, per-connection chunk rows), *Throughput · 60 s* (big rate plus a pixel-column histogram, peak, ETA), *Link data* (connections, cipher, window, receive buffer, read size and depth, RTT, verification method), and *Log*.
- **Progress** is drawn as discrete cells, never a smooth bar. Crisp edges, no anti-aliased gradients.
- **Failures** appear as a Nostromo-style WARNING panel: muted red fill (#b35c5c) with near-black text, stating what failed, what was kept and what happens next (for example *SHA-256 mismatch · kept .blitpart · retry queued*).
- **Icons:** a pixel icon set for statuses and sidebar items, drawn on a strict grid, is an M4 polish task.

### Finder integration

Apple doesn't let third-party apps put their own interface in a Finder tab. What Blit does instead:

- **Quick Action (App Intents): "Blit to…"** Right-click reviewed files in Finder and send them to a NAS through Blit's verified copy engine. It's also available in Shortcuts. *(M4)*
- **Browse-only File Provider (later, low priority).** The seedbox would appear under Locations in Finder's sidebar, with downloads handed to Blit's engine. macOS's own File Provider transfers would lose parallel connections, split files, and checksums. File Provider files normally live on the boot drive. External APFS drives may be supported (to check), and exFAT drives aren't. Combined with the non-goal on Finder mounting, this stays low priority.

## Requirements

### Connections

- **R1.1** SFTP connections with password or SSH key auth. Passwords are stored in the Keychain. A server can sign in with a private key file instead (Sign in with › SSH Key, picked from `~/.ssh`): unencrypted OpenSSH or PEM keys of type ed25519 or ECDSA (P-256/384/521), which is what SwiftNIO SSH can sign with. Blit reads the key file at each connect and never copies it. RSA keys and passphrase-protected keys are refused with a clear message when you choose them. The CLI takes `$BLIT_KEY`. A refused password or key fails the sign-in immediately (not after the handshake timeout). A rejected key shows what to check rather than a password prompt.
- **R1.2** Per-server settings: host, port, username, starting path, maximum connections, and an optional separate **shell endpoint** for server-side checksums. Some servers run SFTP and shell on different ports with different path roots; see [findings](#benchmark-findings).
- **R1.3** Check host keys on first connect and pin them in Blit's own store, which can be seeded from `~/.ssh/known_hosts`. SwiftNIO SSH takes the **server's** preferred key type, which may differ from the one on file. For example, SFTPGo presents Ed25519 while `known_hosts` has only its ECDSA key. When that happens, show both fingerprints and ask; never accept silently. Refuse to connect if a pinned key changes.
- **R1.4** Local and external volumes appear automatically. Blit notices when a drive is ejected mid-transfer and recovers when it reconnects.
- **R1.5** NAS shares mounted through macOS SMB are used as normal filesystem paths. Blit can save and remount favorite shares.
- **R1.6** A NAS entry can have an SSH endpoint, used to compute checksums on the NAS (R4.2). This requires SSH enabled in DSM and an account in the administrators group. The entry maps the Mac's mount point to the share's path on the NAS (for example `/Volumes/Media` ↔ `/volume1/Media`).
- **R1.7** Warn when a NAS (or server) is reached over Wi-Fi while a wired interface is up, and name the cause (which interface macOS routes through, and why). This silently halved SSD → NAS throughput in the reference setup.

### Browser

- **R2.1** Two-pane browser, with any connection on either side.
- **R2.2** Keyboard-first: arrow keys, type-to-select, and copy with ⌘C or Return.
- **R2.3** Drag and drop between panes and to and from Finder.
- **R2.4** **Sort by date modified, newest first, by default.** Clicking a column header changes the sort. The choice is remembered per location, and the default is always newest at the top.
- **R2.5** **Alternating row backgrounds** in every file list, using the standard macOS alternating row colors so they match light and dark mode.
- **R2.6** Columns: Name, Date modified, Size, Status (queued, percent done, verified, failed). Columns can be shown, hidden, and resized.
- **R2.7** ⌘K command palette to jump to any server, drive, or recent folder.
- **R2.8** A single pane by default, with a keyboard shortcut to toggle a second pane.
- **R2.9** **Favorites:** pinned folders on any location (local drive, NAS share, remote server) at the top of the sidebar. Add by dragging a folder in or with ⌘D; reorder by dragging; remove from a context menu. Each shows its volume or server, and is dimmed when that isn't mounted or connected.
- **R2.10** **Dropping files on any sidebar item** (favorite, drive, share, server) starts a transfer to it: download, copy, or clone as appropriate, with the same verification as any other transfer. The target highlights while dragging. Dropping onto a folder in the file list works the same way.
- **R2.13** **Expand folders in place:** a disclosure triangle beside each folder (or → and ←) shows its contents nested in the list without leaving the current folder, as in Finder's list view. Expanded folders refresh with the list.
- **R2.14** **Persistent server sessions:** each server's browsing session opens at launch when its password is saved, stays open (a tiny request every 2 minutes keeps servers with idle timeouts from dropping it), and reopens in the background after sleep. The last listing of each folder shows at once while a fresh one loads.
- **R2.15** **Path bar** under the file list, as in Finder (View › Show/Hide Path Bar, ⌥⌘P; on by default). It shows the path of the selected item, or of the current folder, from its drive, share or server down. Click any folder in it to go there, or drop items on one to move or copy them into it (R2.11 rules). Each pane has its own.
- **R2.16** **Icon previews:** files on drives and NAS shares show tiny Quick Look thumbnails (images, most video, PDFs), made lazily for visible rows and cached; everything else shows its type's icon. Files on servers show type icons, since a thumbnail would mean downloading the file. View › Show Icon Previews turns thumbnails off.
- **R2.17** **Quick Look:** Space (or ⌘Y, or Quick Look in the context menu) previews the selection, as in Finder; while the panel is open it follows the selection, and ↑/↓ preview the previous or next file (skipping folders, and server files too big to preview). Server files up to 64 MB (images, .nfo, subtitles, samples) are downloaded to a temporary folder to preview; larger ones say to download them first.
- **R2.18** **Refresh:** View › Refresh (⌘R), Refresh in the file list's context menu, and Refresh on every sidebar item (favorite, server, drive, share) reload the listing, including expanded folders. From the sidebar, it reloads any pane showing that location (for a server, anything on it), or opens it. Servers also have Reconnect, which reopens the browsing session first. While a folder loads for more than a moment, the path bar shows a spinner with "Refreshing…" (or "Loading…" for a folder not seen before), gone once the listing, and any expanded folders, are in; with the path bar hidden, it shows in the list's top corner.
- **R2.11** **Drag rules follow Finder:** a drag within one volume or one server moves (a rename, instant); a drag across devices copies; holding ⌥ always copies.
- **R2.12** **File management** on drives, NAS shares and servers:
  - New Folder (⇧⌘N) creates "untitled folder" at once with its name ready to edit; Rename edits the name in place in the list (Return, as in Finder; the name without its extension starts selected; Return saves, Esc cancels, clicking away saves; if the new name has no real extension, the old one is added back, so a file keeps its type); Duplicate (local). Double-click, ⌘↓ or File › Open opens.
  - Drops between rows or below the last row go into the folder there (an expanded folder, or the current one), so items can be dragged out of an expanded folder into the folder being viewed.
  - Cut, Copy and Paste (⌘X/⌘C/⌘V), and Move Items Here (⌥⌘V). Local items also go on the pasteboard as file URLs, so copying in Finder and pasting in Blit (or the reverse) works.
  - Edit › Undo (⌘Z) for rename, moves within a volume or server, Move to Trash (puts items back), New Folder and Duplicate; cross-device transfers and permanent deletes can't be undone, and there's no redo. Get Info (⌘I) shows size (folders are totalled), where, dates and, for files Blit copied, the verification record: method, time, SHA-256 and source. Go › Go to Folder (⇧⌘G) opens a typed path on this Mac or, from a server pane, on that server.
  - Delete (⌘⌫). Local drives use the Trash, with no prompt. Servers and network shares have no Trash, so deletes there are permanent and always ask first.
  - A move across devices, or from a server, runs through the verified transfer engine. Each source file is removed only after its copy is verified by SHA-256. Files that were already present, only size-checked, or that failed stay where they were, and the log says so.
  - File operations that take more than a moment (deletes, moves, duplicates, trashing) show in the condensed transfer strip, with an item count, progress cells and the current item. A clean one leaves the strip after a few seconds; one with problems stays until dismissed.
  - Deleting on a server treats anything already gone as deleted (another client or the torrent client may have moved it), and removes a folder only after its listing is closed.
  - Uploads, and copies within or between servers, aren't supported yet. Blit says so rather than failing silently.

### Transfer engine

- **R3.1** Download and copy recursively, preserving folder structure and modification times. Empty folders are recreated; local symlinks are recreated as links (not followed), and a move removes them from the source once they exist at the destination. Symlinks on servers are skipped and each one is named in the log. After a move, source folders are removed deepest first once empty.
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

- **R4.1** **Remote to local:** compare the local file's SHA-256 with `sha256sum` run on the server over an SSH exec channel. This is the only way to get a remote hash: neither SFTPGo nor OpenSSH supports the SFTP `check-file` extension. Start the hash the moment a file finishes downloading, while it's still in the server's cache. Store hashes on the server under `~/.cache/blit/`, outside the download folders, keyed by path, size, and modification time, so a file is never hashed twice. Filenames are untrusted: pass them NUL-delimited over stdin (`xargs -0`) and never paste them into a shell command. If the server has no shell access, fall back to comparing sizes and warn. Only a server that genuinely can't hash (exec refused, or no `sha256sum`: exit 126/127) gets that fallback; a hash that was interrupted, or failed for one file, keeps the part file and retries. The script checks that the read succeeded and that the file didn't change while it was hashed before caching; the cache key also includes ctime and inode, and a cached hash that disagrees is recomputed once before the file fails.
- **R4.2** **Local to NAS:** hash the source while copying, then compare with `sha256sum` run **on the NAS** over SSH (R1.6), reusing R4.1's code. Reading the copy back over SMB isn't reliable: `F_NOCACHE` doesn't clear pages cached during the write, and the SMB client can answer reads from its local cache. So read-back is only a fallback, and is flagged as weaker, when a NAS has no SSH access; an interrupted NAS hash never falls back to it. Verification can be switched off for trusted paths, but it's on by default.
- **R4.3** A mismatch re-downloads the affected file, and a file that fails verification again (or keeps changing on the server) stops retrying instead of looping. Files are never silently accepted. The final rename never replaces something that appeared at the destination during the transfer, and range state is recorded only after its bytes are flushed to disk. Hashing each chunk on the server was ruled out, because reading ranges adds disk seeks on the server.
- **R4.4** Keep a per-transfer record (file, size, hash, source, destination, time) as an exportable log. Window › Transfer Log (⌥⌘L) shows it newest first, searchable by name, path or SHA-256, filterable (All / Verified / Not hash-verified / Failed), with the full record, Show in Finder and Copy SHA-256 for the selected file; it updates as transfers finish. File › Export Transfer Log… writes CSV.

### Queue and UX

- **R5.1** The queue survives app restarts and reboots.
- **R5.2** Pause, resume, reorder, and cancel, per item and globally. The HUD's Queue panel lists every transfer with its state; each row has Pause/Resume, Cancel (✕), ▲/▼ to reorder waiting jobs, and Retry for failed or cancelled ones, and clicking a row shows it in the HUD. Pause All / Resume All hold the whole queue (also in the menu bar panel and the strip's right-click menu). Pausing a running job closes its connections (downloads) or stops the copy at its next block; it resumes from its part files. Cancel keeps part files, so Retry picks up where it stopped; files already at the destination are skipped. Paused jobs and a paused queue survive a restart. The queue runs in two lanes, one download and one local copy at a time, since they use different links (the internet and the home network); within a lane jobs run in order. A copy whose source is, or holds, the destination of a download queued ahead of it waits for that download, so a pack isn't copied to the NAS half-downloaded.
- **R5.3** When a file already exists, apply a rule per queue: skip, overwrite, keep both, or overwrite only if different (size and hash). *Implemented* as Settings › When a file already exists, captured per transfer when queued (saved with the queue; shown as EXISTS in the HUD): **Skip if the same size** (default; a different size fails the file), **Replace if different** (same size: SHA-256 of both copies, on the server or NAS where possible; identical is left and counts as verified, so a move may remove its source; different is transferred again), **Replace** (always, verified as usual), **Keep both** (the new file becomes "name 2.ext").
- **R5.4** Show live throughput per connection and overall, plus time remaining.
- **R5.5** Send a notification when a queue finishes or fails.
- **R5.6** Keep the Mac awake while transfers run.
- **R5.7** A menu bar icon shows overall progress and speed when the main window is closed.
- **R5.8** **Queue-wide disk space:** before starting each item, check the destination's free space against everything still queued for it. If it would run out, pause the queue; don't fail the file. *Implemented per item:* after listing, a transfer works out the new space it needs (files already there, part files, which reserve their full size, and same-volume clones count as nothing) and, if the destination is short (plus a 1 GB reserve; APFS purgeable space counts), waits with `WAITING FOR SPACE · <volume> NEEDS <n> MORE`, notifies once, and rechecks every 15 s, continuing by itself; Pause and Cancel still work. Running out mid-transfer ("No space left on device") waits the same way instead of retrying into a full disk.

### Finder integration

- **R6.1** A "Blit to…" Quick Action (App Intents) for files selected in Finder, with destinations chosen from saved NAS and drive locations. It's also available in Shortcuts.
- **R6.2** *(Later, low priority)* A browse-only File Provider extension for servers. Downloads started from Finder go through Blit's engine. It's blocked on confirming whether File Provider can place files on an external drive (open question 7).

## Performance targets

Derived from the measurements below.

| Path | Target | Ceiling / notes |
|---|---|---|
| Remote → SSD, pack of many files | **≥ 55 MB/s** sustained (server-cached files) | M2: 54.3 MB/s for a 26-file pack including verification; 65–93 MB/s for cached single files. Uncached files are limited by the seedbox's shared disk (22–36 MB/s measured), not by Blit. See [cold-file results](#cold-file-results-m2). |
| Remote → SSD, single large file | **≥ 50 MB/s** | Needs chunked downloads. Transmit: 24.6 MB/s on one connection. M1 spike: 88.9–93.0 MB/s split 3 ways, written to disk and verified. |
| Remote, per connection | **≥ 24 MB/s** ✅ | **M1: 42.9 MB/s** (255 KB reads, 16 MB window, 7 MB receive buffer). OpenSSH: 10.7 MB/s. |
| SSD → NAS, today (1 GbE) | **≥ 105 MB/s** ✅ | **M3: 106.3 MB/s** for 29.9 GB (7 files), every file verified on the NAS. Link maximum is about 113 MB/s. |
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
4. **Transmit reached 24.6 MB/s on one connection,** which means about 3.6 MB in flight. **M1 answered why: the limit was the Mac.** macOS lets each TCP connection's automatic receive buffer grow only to 4 MB (`net.inet.tcp.autorcvbufmax`). With that default, the spike also stopped at 24.5 MB/s. Setting `SO_RCVBUF` to 7 MB on the connection raised it to 32–43 MB/s. See [M1 spike results](#m1-spike-results).
5. **16 connections was slower than 8 (46.9 vs 57.1 MB/s), and the cause is unknown.** Possible causes: disk seeking from many readers, sshd's `MaxStartups` (default `10:30:100`) randomly dropping near-simultaneous logins, 16 logins at 148 ms eating into the 20-second test, or ordinary variation between single runs on a shared server. Through SFTPGo, 16 connections was level with 8 rather than slower. The target is **3–4 connections with large windows** either way, for fair use and because of the disk ceiling.
6. **The SFTP and shell endpoints use different path roots.** `/files/…` in SFTPGo is `~/files/…` over OpenSSH. Blit needs a per-server path mapping between them (R1.2).

### M1 spike results

Measured on 2026-09-24 with [`spike/`](spike/): SwiftNIO SSH 0.15.0 and a minimal pipelined SFTP v3 client, against the OpenSSH endpoint unless noted. The 923 MB file had been read repeatedly that day and was probably in the server's cache.

| Test | MB/s |
|---|---:|
| SSH channel (`cat`), 2 MB window, automatic receive buffer | 10.3 |
| SSH channel, 8 MB window, automatic receive buffer (4 MB macOS cap) | 24.5 |
| SSH channel, 8 MB window, **7 MB `SO_RCVBUF`** | 32.5 |
| SSH channel, 16 MB window, 7 MB `SO_RCVBUF` | 35.1 |
| SFTP, 1 connection, 64 × 32 KB in flight (2 MB) | 12.8 |
| SFTP, 1 connection, 128 × 64 KB in flight | 39.8 |
| **SFTP, 1 connection, 32 × 255 KB in flight** | **42.9** |
| SFTP, 3 connections, file split 3 ways | 81.5–90.9 |
| SFTP, 3 connections, **written to disk + SHA-256 verified against the server** | **91.6–93.0** ✓ |
| SFTP, 4 connections | 89.7 |
| SFTPGo endpoint, 1 connection, 64 KB requests (7,204 short reads handled) | 23.7 |

What it settled:

1. **SwiftNIO SSH is confirmed as the library.** Host-key checks, password login, AES-GCM, window control through `maximumPacketSize`, exec channels, and half-closing stdin all work against the real server.
2. **The per-connection ceiling was the Mac's TCP receive buffer,** not the server and not the SSH window. Blit sets `SO_RCVBUF` to 7 MB before connecting. The maximum is about 7.1 MB under the default `kern.ipc.maxsockbuf` of 8 MB, and no system changes are needed.
3. **Keeping enough requests in flight matters as much as the window.** 64 × 32 KB fills only 2 MB and stays at 12.8 MB/s even with a 16 MB window.
4. **Handling shortened replies fixes SFTPGo.** One connection gets 23.7 MB/s, about what lftp needed 8 connections for.
5. **Writing to disk costs nothing at these speeds.** Saved runs matched discarded ones. An earlier 54 MB/s run coincided with 3.6 s connection setup (normally 1.2–1.9 s), so it was the server being busy.
6. **Server-side `sha256sum` with the path sent NUL-delimited over stdin works:** 923 MB in about 7 s (from cache), and it matched every time.
7. **SwiftNIO SSH reports failures but leaves the TCP connection open,** so the engine must close on error and apply handshake timeouts. The spike initially hung without them.

### Cold-file results (M2)

Measured on 2026-09-24 against parts of a 52 GB file that hadn't been read that day, so the server's page cache couldn't help.

| Test | MB/s |
|---|---:|
| Server disk, sequential `dd` (1 MB reads, no network), one reader | 132 |
| `blit get`, 3 connections (256 MB chunks) | 30–36, dipping to ~9 |
| SFTP, 1 connection reading sequentially | 35.3 |
| SFTP, 3 connections far apart | 36.4 (12 each) |
| SFTP, 3 connections, an hour later | 22.2 |
| SFTP, 3 connections + server-side `dd` prefetch of each region | 22.2 (prefetch `dd`s ran at 8.2 MB/s each) |

What it means:

1. **Uncached files are limited by the seedbox's shared disk,** and its speed swings widely with other customers' load: 132 MB/s for one idle sequential reader, versus 22–36 MB/s for SFTP reads at other times.
2. **More connections don't help on uncached files, but don't hurt either:** 35.3 MB/s with one versus 36.4 with three. On cached files, three are 2–3× faster, so **3 stays the default**.
3. **Server-side prefetch was tested and rejected.** Under load, the prefetch reads compete for the same disk and never get ahead of the downloads.
4. **Freshly completed downloads are the fast case.** A file the seedbox just finished writing is likely still in its page cache (65–93 MB/s measured on cached files). Fetching new downloads promptly is worth more than any client-side tuning; see open question 10.
5. **Every M1/M0 figure above 36 MB/s was from a cached file,** including the 86 MB/s `dd` in M0.

### LAN

- The Mac's 2.5 GbE USB adapter negotiates **1000baseT**, because the core switch has only gigabit ports. Every wired path is limited to about 113 MB/s.
- **The Mac reached the NAS over Wi-Fi, not the wire (found and fixed in M2/M3).** Its Wi-Fi was on the NAS's subnet (192.168.20.x) while the wired port was on 192.168.10.x, so macOS routed all NAS traffic over Wi-Fi. Reading a file from the Media share ran at **58.7 MB/s over Wi-Fi**; after the Mac's switch port was moved to the 20.x network and the shares remounted, the same test ran at **105.6 MB/s over the wire**. Existing SMB connections stay on the interface they were made on until the share is remounted. Blit should detect and warn when a NAS is reached over Wi-Fi while a wired interface is up (see R1.7).
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
- **Defaults (from M1):** `SO_RCVBUF` 7 MB, set before connect; 256 KB maximum packet (16 MB window); reads at the server's `limits@openssh.com` maximum read size (255 KB on OpenSSH) with 32 in flight, or 64 KB × 128 with short-read handling where the extension is missing (SFTPGo); 3 connections, 250 ms apart. Connection setup takes about 1.2–1.9 s (key exchange and password login at 148 ms).
- **Library: SwiftNIO SSH, with our own SFTP client.** SwiftNIO SSH sets each channel's window at the maximum packet size × 64. The default 128 KB packet gives an 8 MB window (about 54 MB/s at 148 ms). Raising the packet size to 256 KB gives 16 MB. There's no direct window setting. It supports key renegotiation (servers typically renegotiate every 1–4 GB, so 20 GB files depend on this) and AES-GCM, which matches the cipher plan.
- **Ruled out:** Citadel's SFTP client waits for each read before sending the next (no pipelining), so its wire-format types may be worth borrowing but not its read path. libssh2 has a fixed 2 MiB window, caps SFTP reads at 30,000 bytes, and gives no window control through its SFTP API, which puts it at OpenSSH's ~14 MB/s. It stays a fallback only if SwiftNIO SSH fails the M1 spike.
- **Per connection:** window ≥ 8 MB (packet size 128–256 KB), 64+ read requests in flight, and correct handling of shortened read replies (R3.4).
- **Scheduling:** a pool of up to N connections, 3–4 by default. Small files are spread across connections. Files over roughly 256 MB are split into chunks that share the same pool. A connection that finishes early takes remaining chunks from slower ones.
- **Auth:** password or key. Host keys are pinned.
- **Cipher:** prefer `aes128-gcm@openssh.com` (the server already negotiates it; it's hardware-accelerated on Apple Silicon). Compression is off.
- **Checksums:** use a second session to the shell endpoint to run `sha256sum` the moment each file finishes, and store the results in a hash cache (R4.1). The same code verifies NAS copies (R4.2).
- **Connection setup:** open connections a moment apart rather than all at once, to stay under sshd's `MaxStartups` limit. Close the TCP connection on any SwiftNIO SSH error, and time out handshakes. SwiftNIO SSH won't do either by itself.
- **Disk I/O:** writing from the network event loop cost nothing at ~93 MB/s in M1. The engine still moves file writes off the network threads to leave headroom.

### Local / SMB engine design notes

- For the same APFS volume, use `clonefile`. For large cross-volume copies, use a double-buffered loop with 4–8 MB buffers and `F_NOCACHE`, which hashes the source as it streams. `F_PREALLOCATE` and `F_FULLFSYNC` apply to local volumes only. Over SMB, use `fsync`.
- Verify NAS copies with `sha256sum` on the Synology over SSH (R4.2). An SMB read-back can be answered from the Mac's cache.
- For many small files, run 4–8 file copies at once. For large ones, copy one file at a time with deep buffering.

## Reference environment

The setup Blit is tuned against:

| Component | Details | Limit today |
|---|---|---|
| Mac | Mac mini M2 Pro (`Mac14,12`), macOS 27, 4× Thunderbolt 4 | Built-in Ethernet is 1 GbE only |
| Mac NIC | USB-C 2.5 GbE adapter, on 192.168.20.x (same network as both NAS units) | Negotiates 1 GbE (switch limit) |
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
| **M1** | SSH spike | Throwaway code: raw SwiftNIO SSH channel throughput with a ≥ 8 MB window against the real server, then a minimal pipelined read loop that handles shortened replies, plus `sha256sum` over an exec channel. **Done when one connection sustains more than 24.6 MB/s from the reference server.** Result: 42.9 MB/s on one connection, ~90 MB/s on 3, verified ([results](#m1-spike-results)). Carried into M2: `sha256sum` on DSM, and fixing the probe to time from first byte. | ✅ Done |
| **M2** | SFTP engine | `BlitKit` Swift package. Pipelined reads, connection pool with staggered setup, chunked files, remote checksums with hash cache, resume, stability gate, filename policy, host-key pin store. Target ≥ 55 MB/s from the reference server. **Delivered:** SFTP v3 protocol layer and read planner; SSH connections with M1 tuning, host-key verification (known_hosts + pinned fingerprints), close-on-error and handshake timeout; SFTP client with pipelined downloads and backpressured writes; parallel verified downloads (shared range queue, `.blitpart`, `F_FULLFSYNC`, server `sha256sum`, mtime, rename); **resume** (`.blitpart.state` with completed ranges, 256 MB chunks); server hash starts when the last range is handed out; **server-side hash cache** (`~/.cache/blit/sha256`); **stability gate**; `blit ls` / `blit get`. **Live (2026-09-24, 3 connections, 923.5 MB file):** fresh 64.8 MB/s, verified 4.8 s after the last byte; repeat 74.1 MB/s with the hash cached (0.7 s); killed at 339.6 MB then resumed with 232.8 MB reused and the whole file verified. 26-file pack: 26/26 verified. Host-key store with trust prompt (`blit hostkeys`); filename collision detection; SFTPGo endpoint verified live (35.1 MB/s over 3 connections, size-check fallback without a shell); cold-file throughput measured ([results](#cold-file-results-m2)). 38 unit tests. | ✅ Done |
| **M3** | Local engine | LocalCopyEngine, NAS-side checksums over SSH, `.blitpart` handling, queue-wide disk-space checks, Wi-Fi path warning (R1.7), `blit copy` in the CLI. Target ≥ 105 MB/s SSD → NAS. **Delivered:** `BlitLocal` module: 8 MB overlapped copy with the source hashed as it streams, `.blitpart` + sync + rename, mtime, APFS clone on one volume, NAS-side `sha256sum` with automatic share-path lookup (read-back fallback, labelled weaker), space preflight, Wi-Fi route warning, `blit copy`; 46 unit tests. **Live (2026-09-24):** external SSD → RS1619xs+ Media share over wired 1 GbE, 29.90 GB in 7 files at **106.3 MB/s**, 7/7 verified on the NAS, 15.7 s from last byte to verified. **Prerequisites confirmed:** DSM (RS1619xs+, OpenSSH 8.2) has `sha256sum`, GNU `stat -c`, `xargs`; Media share at `/volume1/Media`; no home folder for the SSH user, so NAS-side hashes aren't cached (fine: each copy is verified once). Baseline SMB read over the wire: 105.6 MB/s. | ✅ Done |
| **M4** | App | `Blit.xcodeproj` (bundle, signing, entitlements) depending on BlitKit as a local package. Native Finder-style browser (sorted newest first, alternating rows, ⌘K, optional second pane), Favorites with drag-and-drop onto sidebar targets (R2.9, R2.10), pixel-terminal transfer HUD (condensed and expanded), transfer strip, durable queue, server editor, Keychain, host-key pinning, notifications, menu bar icon, "Blit to…" Quick Action **Done so far:** Xcode project (hand-written, folder-synced, BlitKit linked locally; Hardened Runtime, not sandboxed, automatic signing with the developer team); native window with sidebar (Favorites: drag in, ⌘D, reorder, availability; Drives; NAS, live on mount/unmount) and a Finder-style Table (newest first, alternating rows, monospaced digits, back/forward/up, double-click to open). Servers (Keychain passwords, trust and password sheets, remote browsing), drag-to-transfer with a queue and the condensed pixel HUD (verification progress, bundled Silkscreen/VT323), hidden files (⇧⌘.), NAS verification per share (right-click → Verify Copies on NAS…). Expanded HUD, durable queue (restored on launch, resumes mid-file), notifications, skip-if-present, clean quit mid-transfer, menu bar extra + Settings, ⌘K palette with recents, Finder integration (Services "Send to Blit…" and the "Copy with Blit" App Intent / Quick Action), transfer log with CSV export, optional second pane, pixel glyphs for the HUD, pixel-art app icon, signed with the developer team. | ✅ Done |
| **M5** | Hardening | Handling network changes, sleep and wake, drive ejection, transfer log export, signing and notarization. **Done so far:** TCP keepalive and a 60 s SFTP stall watchdog (dead links detected in about a minute); automatic retry with backoff (10 s → 5 min), waiting for the network and for missing drives or shares to return, resuming from `.blitpart` state; permanent failures fail fast; idle sleep disabled while transferring; Developer ID signing via `scripts/release.sh` (cloud-managed certificate). **Released:** 0.1 (build 1) notarized by Apple, stapled, Gatekeeper-accepted, installed to `/Applications` (2026-09-25). | ✅ Done |

## Open questions

1. ~~**SSH library**~~ **Answered:** SwiftNIO SSH with our own SFTP client; libssh2 and Citadel were ruled out (see [SFTP engine design notes](#sftp-engine-design-notes)). M1 confirms it against the real server.
2. ~~**Per-connection ceiling**~~ **Answered (M1):** the Mac's 4 MB automatic TCP receive-buffer cap. With a 7 MB `SO_RCVBUF`, one connection reached 42.9 MB/s.
3. **Fair use:** what the remote provider allows for simultaneous connections. Defaults should be modest (3–4).
4. **Server-side hashing cost:** reduced by hashing each file as soon as it finishes, while it's in the server's cache, and by the hash cache (R4.1). Measure the real impact on the seedbox's disk in M2.
5. **SMB at 10 GbE:** keep using the macOS SMB client with `nsmb.conf` and multichannel tuning, or embed `libsmb2` if measurements show the macOS client is the bottleneck after the upgrade.
6. **Uploads:** out of scope for v1, but the engine shouldn't rule them out.
7. **Browse-only File Provider:** worth it after v1? Handing downloads from the extension to Blit's engine is feasible. Still to check: whether File Provider on macOS 27 can place files on an external APFS drive rather than the boot drive, and how reliable it is.
8. **Connection ramp:** does the seedbox's sshd drop near-simultaneous logins above `MaxStartups`? Opening 3–4 connections 250 ms apart worked every time in M1. 8–16 at once wasn't tested, and isn't needed at 3–4 connections.
9. ~~**Cold-file throughput**~~ **Answered (M2):** 22–36 MB/s, set by the seedbox's shared disk and its load; more connections and server-side prefetch don't raise it ([results](#cold-file-results-m2)).
10. **Fetch new downloads automatically?** Freshly completed files are usually still in the seedbox's cache and download 2–3× faster. A watch mode that fetches new completed downloads as they appear would take advantage of that. It's a candidate for after v1.

## Repository layout

```
blit/
├── README.md             this document (the PRD)
├── scripts/
│   ├── sftp-probe.sh     quick per-method SFTP speed probe (20 s each)
│   ├── sftp-bench.sh     longer parallel-file / chunked-file benchmark with checksums
│   ├── make-icon.swift   renders the pixel-art app icon (Blit/AppIcon.icon)
│   └── release.sh        Developer ID build, notarization, stapling, optional install
├── spike/                M1 throwaway: SwiftNIO SSH + minimal pipelined SFTP client
│   ├── Package.swift
│   ├── Sources/blit-spike/main.swift
│   ├── run-m1.sh         the M1 test matrix
│   └── run-m1b.sh        M1 follow-ups (SFTPGo, 255 KB reads, disk-write cost)
├── Blit.xcodeproj/       the Mac app (macOS 27, SwiftUI); Blit/ is a folder-synced group
├── Blit/                 app sources: BlitApp, Model/, Views/, Intents/, Resources/Fonts/, AppIcon.icon
├── Support/Info.plist    merged into the generated Info.plist (drag type, Services)
└── BlitKit/              the transfer engine (Swift package; the app links it locally)
    ├── Package.swift
    ├── Sources/BlitSFTP/   SFTP v3 protocol: messages, attributes, framer, read planner
    ├── Sources/BlitRemote/ SSH connections, host keys, SFTP client, parallel verified downloads
    ├── Sources/BlitLocal/  verified local/SMB copies, NAS-side checks, network-path check
    ├── Sources/blit/       command-line front end (`blit ls`, `blit get`, `blit copy`, `blit hostkeys`)
    └── Tests/
```

`Blit.xcodeproj` links BlitKit as a local package. Files added under `Blit/` are picked up automatically (folder-synced group), so the project file rarely changes.

## Building

Open `Blit.xcodeproj` in Xcode 27 and run the **Blit** scheme, or:

```bash
xcodebuild -project Blit.xcodeproj -scheme Blit -configuration Debug build
```

Release build (Developer ID, notarized, stapled; `INSTALL=1` also replaces `/Applications/Blit.app`):

```bash
# once: store notarization credentials in your Keychain (asks for an app-specific password)
xcrun notarytool store-credentials blit-notary --apple-id you@example.com --team-id F87BNUZAVJ
scripts/release.sh
```

Engine and command-line tool:

```bash
cd BlitKit
swift test                 # or open Package.swift in Xcode and press ⌘U
swift build -c release     # builds .build/release/blit

.build/release/blit ls  user@host:port <remote-folder>                 # newest first
.build/release/blit get user@host:port <remote-path> <local-folder>    # 3 connections, verified
```

This needs Xcode 27. If `xcode-select -p` shows `/Library/Developer/CommandLineTools`, either run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once, or prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

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

### Third-party fonts

Bundled in `Blit/Resources/Fonts/`, each with its license:

- **Silkscreen** by The Silkscreen Project Authors, SIL Open Font License 1.1 (`Silkscreen-OFL.txt`).
- **VT323** by The VT323 Project Authors, SIL Open Font License 1.1 (`VT323-OFL.txt`).
