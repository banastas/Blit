# Blit

**A native macOS utility that moves big files fast and verifies every byte.**

Blit moves data between three places, and does nothing else:

- **SFTP servers**, including high-latency ones on another continent
- **Local and external drives**
- **NAS shares** on the home network (SMB)

The name comes from *bit block transfer*: copy a block of memory as fast as the hardware allows.

> **Status:** 0.2.45, M0–M6 complete. Blit is a notarized native Mac app: parallel, resumable seedbox downloads verified against the server's SHA-256, SSD → NAS copies at wire speed verified on the NAS, a Finder-style browser with favorites and drag-to-transfer, the pixel-terminal transfer HUD, a durable queue that survives quits and network drops, a menu bar extra, ⌘K and Finder integration. The `blit` command-line tool exposes the same engine. This README is the living product requirements document (PRD).

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
  - #b35c5c is the one failure hue, used for fills, tags and glyphs. Text on the red fill is black (4.6:1).
  - Failure *text* on dark backgrounds (the HUD, dark mode) uses its lighter tint #C98080 (6.5:1 on the HUD). #b35c5c itself falls under WCAG AA's 4.5:1 there.
  - In code these are `Color.failure`, `Color.failureText` (adaptive) and `HUDColor.failureText`. There are no other reds.
- **VoiceOver:**
  - Pixel glyphs speak ("done", "failed", "transferring", "paused", "to").
  - The sidebar signal announces Connected, Connecting, Not connected, or Connection failed with the reason.
  - The condensed strip reads as one summary (title, destination, percent, rate, files, warnings) and keeps its buttons reachable.
  - HUD buttons read as words ("Pause all", not "‖ PAUSE ALL"), and progress cells and the histogram carry live values.

### Transfer HUD

The transfer strip expands into a 1-bit, pixel-terminal HUD (references: 1-bit pixel art, pixel icon sets, the *Alien* Nostromo interface).

From the keyboard: View › Show/Hide Transfer Details (⇧⌘T; ⌥⌘T is the system's Show/Hide Toolbar). Escape closes what's open over the list, Quick Look first, then the full HUD.

**Condensed (default), two lines:**
1. `▲ 02/05` transfer count (click to expand) · item `→` destination · 24-cell segmented progress · percent · mini 30-second throughput histogram · large rate · one square per connection (or file stream), bright while it moved data in the last second and dim when idle or stalled, with a short link summary (`3× · 148MS` for SFTP, `SMB · EN7` for copies).
2. The latest log line: verification results, resumes, ETA.

A failure adds a compact red `✕ N warning` tag in the top line (in place of the histogram) and turns the log line muted red; clicking it opens the full HUD at the WARNING panel.

**Pixel accents outside the HUD** (status and motion only; everything you read or click stays native):
- **Menu bar:** a pixel arrow into a tray (out of it, pointing up, for copies onto a share); its stem's dashes march the way the data goes and the tray fills with progress. A shield while only checksums remain, ‖ paused, a check for a minute after the queue finishes, and a muted-red ✕ until the panel is opened after a failure.
- **Dock icon:** a strip of pixel progress cells while transferring; a pixel ✓ for five seconds when a batch finishes verified.
- **The finish moment:** when a big queue (10 GB, or two minutes of work) drains with every file verified by SHA-256, a band of bright pixel cells sweeps once across the strip or the full HUD, trailing sparks that twinkle out, in 1.6 s. Nothing with failures, size-only results or verification off; nothing with Reduce Motion on. Settings › General can add a sound (off by default; the system's Glass).
- **Verified badge:** a small pixel ✓ after the names of local files Blit copied and verified by SHA-256 (server, NAS or read-back), from the transfer log, while their size still matches; hover for how and when. Renames and moves in Blit keep it for the session.
- **Spinners:** a pixel dot chasing round a 3×3 ring (Refreshing…, expanding folders, first load).
- **Drop targets:** pixel marching ants instead of a dashed outline: file list, sidebar rows and path-bar segments. Sidebar rows (favorites, servers, drives, shares) also get a Finder-style tinted highlight while targeted, drawn inside the row, since a sidebar row clips anything past its edges.
- **NAS verification shield:** a pixel shield with a check knocked out.
- **About Blit:** the pixel-terminal style, with version and build.

**Results that need attention:** a finished transfer with files that were only size-checked reads `= … · N SIZE ONLY, NOT HASH-VERIFIED` in muted red (not a ✓), and its notification says so. When the queue drains, the Dock icon keeps a pixel ✓ (all verified) or a muted-red ✕ (problems) until you're back in Blit. Notifications say what happened and where ("Copied to Movies"), name the item as the subtitle, and give size, how it was verified and how long it took at what speed ("71.6 GB · verified on the NAS · 11 min at 108 MB/s"); clean ones offer Show in Finder, problems play a sound and offer Show Details, and they group as one stack. Settings › Notifications: each transfer (default), or only when the queue finishes (a summary: transfers, size, problems) plus problems, size-only results and disk-space waits, which always notify. ETAs read "5:12:03" past an hour and "~2 d 4 h" past a day; the menu bar panel shows how many more are queued.

**Sidebar status:** each server's browsing connection shows as 7×7 pixel signal bars: all lit when connected, filling left to right in a loop while connecting, dim when not connected, and a pixel ✕ in muted red on failure (hover for the reason).

**Expanded:** the full HUD described below. It opens by itself when a transfer starts (Settings; collapsing it keeps it collapsed until that batch finishes). File operations (delete, move…) only use the condensed strip. Switching between the two, or the HUD appearing and leaving, animates like a CRT: a bright line sweeps out, then opens vertically. The expanded HUD keeps a fixed height while it runs.
  - The log always shows six lines at a fixed line height.
  - Connections and server hashing share a fixed six-line area. Connections keep up to four lines; hashing gets at least a label and one file. Overflow is summed up ("+6 MORE · 42.0 MB/S", "SERVER SHA256 · +2 MORE").
  - The Link panel always has the same rows, with "—" where one doesn't apply.
  - The WARNING panel takes exactly the log's height and scrolls inside.
  - The queue panel appears once there's more than one job, always three rows tall, scrolling beyond. Measured: 461 pt with one job in every state, 586 pt with a queue.

**Layout:** the HUD and strip float over the bottom of the window (an overlay), with matching space reserved below the file list. As a safe-area inset, every HUD update during a download (the percent ticking) re-sized the window's content; macOS then briefly reported a shorter toolbar for one layout pass and the list and HUD jumped.

**Verification progress:** the seedbox starts hashing each file when its first range is handed out, so the hash reads the file alongside the download instead of re-reading it cold afterwards. Where the server's `dd` supports `status=progress` (GNU coreutils), it reports bytes hashed about once a second. The HUD shows a *Server SHA256* row per file, the hash rate, and a verify ETA. Once only checksums remain, the strip's progress cells, percent and log line switch to verification progress, and the histogram shows the hash rate.

**Menu bar panel:** a card for every running job (at most one per lane), each the condensed HUD stacked into a 320-pt column: count and item, destination, progress, big rate or SHA256 with ETA, a SHA256 line when checksums run alongside the transfer, and a warning tag. Clicking the tag opens Blit with the full HUD. It uses the strip's own count label (same glyphs, zero-padded) and hour-aware ETA. The count glyphs are ‖ paused, ▼ active into this Mac or ▲ out to a share, ✓ verified, = nothing transferred or size-only, and ✕ for failed, cancelled, or finished with failures.

- **Type:** pixel uppercase for labels (Silkscreen) and large terminal numerals for readouts (VT323). Both are SIL Open Font License, so they can be bundled with the app. The file browser keeps the system font and SF Mono.
- **Panels:** boxed readouts with 1-pixel borders: *Item* (name, route, segmented progress, per-connection chunk rows), *Throughput · 60 s* (big rate plus a pixel-column histogram, peak, ETA), *Link data* (connections, link with read size × depth and interface, RTT measured at connect and every 30 s under load, window and receive buffer, verification method, exists rule; the cipher isn't exposed by SwiftNIO SSH yet), and *Log*.
- **Progress** is drawn as discrete cells, never a smooth bar. Crisp edges, no anti-aliased gradients.
- **Failures** appear as a Nostromo-style WARNING panel: muted red fill (#b35c5c) with black text, stating what failed, what was kept and what happens next (for example *SHA-256 mismatch · kept .blitpart · retry queued*).
- **Icons:** a pixel icon set for statuses and sidebar items, drawn on a strict grid, is an M4 polish task.

### Finder integration

Apple doesn't let third-party apps put their own interface in a Finder tab. What Blit does instead:

- **Quick Action (App Intents): "Blit to…"** Right-click reviewed files in Finder and send them to a NAS through Blit's verified copy engine. It's also available in Shortcuts. *(M4)*
- **Browse-only File Provider (later, low priority).** The seedbox would appear under Locations in Finder's sidebar, with downloads handed to Blit's engine. macOS's own File Provider transfers would lose parallel connections, split files, and checksums. File Provider files normally live on the boot drive. External APFS drives may be supported (to check), and exFAT drives aren't. Combined with the non-goal on Finder mounting, this stays low priority.

## Requirements

### Connections

- **R1.1** SFTP connections with password or SSH key auth. Passwords are stored in the Keychain. A server can sign in with a private key file instead (Sign in with › SSH Key, picked from `~/.ssh`): unencrypted OpenSSH or PEM keys of type ed25519 or ECDSA (P-256/384/521), which is what SwiftNIO SSH can sign with. Blit reads the key file at each connect and never copies it. RSA keys and passphrase-protected keys are refused with a clear message when you choose them. The CLI takes `$BLIT_KEY`. A refused password or key fails the sign-in immediately (not after the handshake timeout). A rejected key shows what to check rather than a password prompt.
- **R1.2** Per-server settings: host, port, username, starting path, maximum connections, and an optional separate **shell endpoint** for server-side checksums. Some servers run SFTP and shell on different ports with different path roots; see [findings](#benchmark-findings). *Not planned:* the reference seedbox hashes over the same login, and NAS checks have their own login (R1.6). A server without shell access falls back to labelled size checks (R4.1).
- **R1.3** Check host keys on first connect and pin them in Blit's own store, which can be seeded from `~/.ssh/known_hosts`. SwiftNIO SSH takes the **server's** preferred key type, which may differ from the one on file. For example, SFTPGo presents Ed25519 while `known_hosts` has only its ECDSA key. When that happens, show both fingerprints and ask; never accept silently. Refuse to connect if a pinned key changes.
- **R1.4** Local and external volumes appear automatically. Blit notices when a drive is ejected mid-transfer and recovers when it reconnects.
- **R1.5** NAS shares mounted through macOS SMB are used as normal filesystem paths. Blit can save and remount favorite shares. *Implemented:* Blit remembers each SMB share's `smb://` address (never a password) and remounts it through NetFS with no UI, using the password macOS saved when the share was first connected in Finder. It reconnects when a queued transfer waits on the share (then every 30 s), when an unavailable favorite is opened, and from the favorite's Reconnect item.
- **R1.6** A NAS entry can have an SSH endpoint, used to compute checksums on the NAS (R4.2). This requires SSH enabled in DSM and an account in the administrators group. The entry maps the Mac's mount point to the share's path on the NAS (for example `/Volumes/Media` ↔ `/volume1/Media`).
- **R1.7** Warn when a NAS (or server) is reached over Wi-Fi while a wired interface is up, and name the cause (which interface macOS routes through, and why). This silently halved SSD → NAS throughput in the reference setup. Checked for SMB copies, seedbox downloads (the interface joins the link label, e.g. `3× · 255K×32 · EN7`) and browse sessions. The sidebar signal's hover shows the route and round trip ("Connected · 195 ms · en7"), refreshed by the 2-minute keep-alive. **A mounted share keeps the interface it connected on:** one that connected, or reconnected after a drop, while only Wi-Fi was up stays on Wi-Fi once the cable is back, though new connections take the cable. So for shares Blit reads the live connection (the session's server from `smbutil multichannel`, the interface of the TCP connection to it from `nettop`) when a transfer starts and every 30 s while it runs. When a share is on Wi-Fi and the cable reaches the NAS, Blit ejects and remounts it, with any other share on that NAS (they share the connection), before the transfer reads or writes it, so it comes back over the cable. Only when that's safe: no other transfer is using it, nothing else has a file open on it (a normal eject refuses), macOS has its password saved (so the remount can't stop at a password prompt), and it wasn't moved in the last 10 minutes. Otherwise the HUD log says why it stayed. Multichannel sessions are left alone.
- **R1.8** **Import Servers** (File › Import Servers from Transmit or ForkLift…, the + by Servers in the sidebar, or the link there while there are none): a sheet lists the SFTP favorites saved in Transmit and ForkLift, each ticked unless Blit already has that login (host, port and user), with where it came from and whether it signs in with a key file. The chosen ones become Blit servers with their name, host, port, user, starting folder and key file; the first is opened. Passwords aren't brought over (they stay in those apps' Keychain items): Blit asks for each on its first connection. Read only, never written: Transmit's connection store (`Connections.transmitstore`, a keyed archive read with stand-ins for Transmit's classes, groups included) or, failing that, its Spotlight files (`Metadata/*.favoriteMetadata`), for the direct and App Store versions; ForkLift's favorites file in any of its folders (JSON or a property list, read leniently: an entry naming a server over SFTP, or with no protocol on port 22). The Transmit reader was checked against a real Transmit 5 store; the ForkLift reader against written examples only (ForkLift wasn't on the development Mac). The same login in both apps is listed once; FTP, WebDAV, S3 and other kinds are left out.

### Browser

- **R2.1** Two-pane browser, with any connection on either side.
- **R2.2** Keyboard-first: arrow keys and type-to-select; ⌘C/⌘V copy and paste (a transfer across devices). Return renames the selection, as in Finder; ⌘↓ opens.
- **R2.3** Drag and drop between panes and to and from Finder. As in Finder, a drag that starts on a file's icon or name moves the files; one that starts on the rest of the row (the blank part of the Name column, the date, the size) selects rows as it goes. A drag takes the rows it starts on (the selection, when the pressed row is in it), even as a quick flick. A local file's drag carries the file itself, so Finder, Books and the Desktop take it; a server file has no file to hand to another app, so its drag carries only Blit's own payload and other apps refuse it. A drop onto a folder row goes into that folder, and onto a file inside an expanded folder into that folder; the folder lights up (an accent fill and marching ants). Anywhere else the drop goes into the folder the list shows, and the list outlines. A drag that rests on a closed folder opens it in place (spring loading, with System Settings' switch and delay), so it can go deeper without letting go. A folder never takes a drag of itself or of a folder it's inside, judged from what's dragged, so a folder selected in the receiving pane still takes a drag from the other pane. A drop target's highlight (a folder row, the list's outline, a sidebar row or the line between two) lives in an object of its own (DragHover), which ignores the "drag moved" macOS sends 310–370 ms after a drop (told from the next drag by the drag pasteboard) and clears itself if no mouse button is down; drop targets are never rebuilt during a drag (a rebuild as a quick flick let go lost the drop and left the drag stuck).
- **R2.4** **Sort by date modified, newest first, by default.** Clicking a column header, or View › Sort By (Finder's ⌃⌥⌘1/2/5/6 for Name/Kind/Date Modified/Size), changes the sort. The choice is remembered per folder, local or on a server, across launches. Choosing newest first again forgets it, and up to 1,000 folders are remembered. Every other folder opens newest at the top.
- **R2.5** **Alternating row backgrounds** in every file list, using the standard macOS alternating row colors so they match light and dark mode.
- **R2.6** Columns: Name, Date modified, Size, Video, Status, Kind. Right-click a column header to show or hide columns (Name always shows). Columns can be resized and reordered, and the layout is kept per window.
  - **Status** shows where a row stands in a transfer that's still in the strip. Rows match both as the transfer's source (the seedbox folder dragged from) and at its destination, including a `.blitpart` on its way.
  - For files: queued · ▲ transferring · verifying NN% (the server's hash progress) · ✓ verified / cloned · = size only / already there · ✕ failed (reason in the tooltip) · ‖ paused.
  - For folders: the dragged folder shows the job's percent while it runs, then ✓ done or ✕ N failed. Subfolders show how many files are done.
  - Glyph and word, never color alone. Once the transfer is dismissed from the strip, the Status clears, and the name's ✓ badge keeps the verification.
  - **Video** (hidden until shown from View › Columns or a header's menu): for MKV, WebM, MP4, M4V and MOV files on the Mac, drives and NAS shares, the picture and running time, e.g. "2160p DV · 2:14:05", as wide as the column allows ("2160p DV · HEVC · TrueHD Atmos 7.1 · 2:14:05" down to "2160p DV"). The tooltip has the rest: exact size and frame rate, codec, profile and bit depth, HDR10 (PQ), HLG or the Dolby Vision profile and its fallback, the main audio track and how many others, subtitles, duration. Only the header is read, never the frames: Matroska by Blit's own reader (a 64 KB read or two), MP4 and MOV through AVFoundation. When the container doesn't state HDR, the HEVC track's own parameter sets do; Atmos and the DTS-HD flavour come from the track's name, since only the frames carry them. Rows are read as they come on screen, two files at a time, and kept for the session; a file whose size or date changes is read again. Files on servers stay blank (it would take a download).
- **R2.7** ⌘K command palette (Go › Go to…) to jump to any server, drive, or recent folder.
- **R2.7a** **Search** in the toolbar (Edit › Find, ⌘F) filters the active pane's folder as you type, by name, ignoring case and accents. It includes expanded folders: a folder stays while it or something inside it matches. It clears on moving to another folder, and a search with no results says so.
- **R2.8** Two panes by default (View › Hide Second Pane, ⌥⌘2, for one), as in ForkLift. The active pane (where the sidebar, ⌘K and the file commands act) has an accent line under its header; each pane remembers its folder across launches (a share or drive that isn't mounted falls back to Favorites, checked against the mount table so a sleeping NAS can't hold up the launch). **Copy to Other Pane (F5)** and **Move to Other Pane (F6)** send the selection to the folder the other pane shows (a move removes each source only once its copy is verified); both are also in the right-click menu, with Open in Other Pane (⌥⌘→) for a folder. **Swap Panes (⌘U)** trades the two folders. View › Columns (or right-clicking a column header, which also has Show All) shows or hides Date Modified, Size, Status and Kind in both panes. Tab and ⇧Tab move the keyboard to the other pane. Each pair of panes lives in a tab (R2.18).
- **R2.9** **Favorites:** pinned folders on any location (local drive, NAS share, remote server) at the top of the sidebar. Add by dragging a folder in, with ⌘D (the folder being viewed, a drive's top level included), or by right-clicking a drive, NAS share or server › Add to Favorites. A favorited drive or share shows its drive icon, its volume name and the device serving it; reorder by dragging; remove from a context menu. Each shows its volume or server, and is dimmed when that isn't mounted or connected.
- **R2.10** **Dropping files on any sidebar item** (favorite, drive, share, server) starts a transfer to it: download, copy, or clone as appropriate, with the same verification as any other transfer. The target highlights while dragging. Dropping onto a folder in the file list works the same way. **Free space as you drag:** over a folder on the Mac, a drive or a NAS share, the target says what the drop would leave: "1.2 TB free → 0.9 TB after" in an accent capsule at the foot of the list (on a sidebar row, "→ 0.9 TB free" at its end), or "Needs 340 GB, 120 GB free" in orange when it won't fit (the drop still works and waits for space, R5.8). A drag is measured as it starts: its files' sizes at once, folders added up in the background (on a server through the pane's connection, as Get Info does), Finder's files when they first come over Blit; until a folder is added up, only the free space shows. What comes from the destination's own volume counts as nothing (a move there is a rename, a copy a clone). Servers and cloud folders show nothing.
- **R2.19** **Cloud folders with the drives:** iCloud Drive and the folders File Provider apps keep in sync (Proton Drive, Dropbox, Google Drive, OneDrive…, found in ~/Library/CloudStorage) are listed under Drives with a cloud icon and the provider's name (the account in the tooltip), and a pane, tab, badge and path bar call them by that name ("iCloud Drive › …", not …/Mobile Documents/com~apple~CloudDocs); no free space is shown for them, since the Mac's would read as the cloud's. To Blit they're local folders on the startup disk. A file that's only in the cloud (a placeholder, not downloaded) is never cloned, which would copy the placeholder, nor renamed out of its provider's folder: it's read, which downloads it, and verified by SHA-256; and a move never clones, since a source is removed only once its copy is verified. Tested with real files in iCloud Drive and Proton Drive, made online-only and copied and moved back out, each checked by SHA-256.
- **R2.21** **New since your last visit:** coming back to a folder, anything that wasn't in it when you last left it has a small accent dot after its name ("New since you last left this folder"), on servers, drives and NAS shares alike. Blit remembers the names each folder listed when it was left, for the 100 folders visited most recently: names, not dates, because a downloaded file keeps its server's modification time. Moving to another folder, closing a tab or quitting counts as leaving; names made in the pane itself (a rename, a new folder, a drop) aren't marked.
- **R2.22** **Compare Panes** (View › Compare Panes, ⌃⌘C; ⌥⌘C stays free for Finder's Copy as Pathname): each pane marks, after each name, how the item stands against the other pane's folder, so "is this archived yet?" reads at a glance with the SSD on one side and the NAS folder on the other. **only here** (accent colour): nothing of that name there. **= same**: a file of the same size there, or a folder of the name (what's inside a folder isn't compared). **✓ verified there**: that same-size copy is one Blit verified by SHA-256. **◐ partly there**: a `.blitpart` of it is still downloading there. **≠ differs** (orange): a different size, or a file where the other has a folder. The tooltip says which and names the other folder; the path bar adds the counts ("4 only here · 1 differs"). Names match ignoring case; rows inside expanded folders aren't marked, nor is anything while both panes show the same folder or the second pane is hidden. The marks follow either side live (a copy landing, a verification, a reload). The switch is remembered.
- **R2.23** **Suggested destinations:** Blit remembers where things like the selection went and offers those folders, so filing the next episode is one click; every move is still yours. Release names are read for a show and its season (`South.Park.S29E02…`, `South-Park_S29E02`, `3x07`, season packs like `Severance.S02…`) or a movie (a year and no episode, by resolution, so a 4K shelf and a 1080p shelf stay apart). Each move or copy of items from this Mac (a drop, a paste, F5/F6, Move To…) teaches the folder for their show or kind of movie, up to three folders each; downloads from a server don't, as they aren't filing. The latest two folders, never the one the items are in, are offered at the top of Copy To ▸ and Move To ▸ under "Suggested", as "Move to “Season 29”" in the context menu, and as File › Copy to / Move to “…” (⇧F5 / ⇧F6). A new season gets the matching folder beside the last season's ("Season 30" beside "Season 29", in the same style), made as the items move if it isn't there yet. A movie filed in a folder of its own ("The Gentlemen (2019)") teaches the shelf it's on. Photos and other non-video files, and selections mixing shows or kinds, get no suggestion. Kept in Application Support (the 2,000 most recently used shows and kinds).
- **R2.24** **Welcome (first run):** on a fresh install (no servers, no favorites), a five-step sheet sets Blit up after the window opens: what Blit does; your servers (Import from Transmit or ForkLift, with how many it found, or Add a Server…, and the servers so far); drives and NAS shares to keep as favorites (each mounted external drive and share with a switch, and Choose a Folder…); Full Disk Access (in place of its own first-launch sheet, R2.20); and how Blit works in four lines (SHA-256 and the ✓, F5/F6 and Compare Panes, Space, the strip). Skip Setup at any step; nothing is required. An install already set up never sees it; Help › Welcome to Blit… shows it again any time.
- **R2.20** **Full Disk Access, explained once:** macOS protects iCloud Drive, Desktop, Documents, Downloads and the Trash until the user allows an app in System Settings, and can't ask with a prompt; without it, moving, renaming or deleting there fails with "you don't have permission" (a Move to Trash in iCloud Drive did). At first launch, without it, Blit shows a sheet saying why and how, with Open System Settings (straight to Privacy & Security › Full Disk Access) and Not Now, shown once; it checks again whenever Blit comes back to the front and says ✓ once granted. Settings › General shows where it stands, with the same button. A file operation macOS turns away for it says so in its warning list, with the button. Blit tells by opening a file only Full Disk Access opens (macOS has no API for it). Drives and NAS shares don't need it: macOS asks about those the first time Blit opens one.
- **R2.13** **Expand folders in place:** a disclosure triangle beside each folder (or → and ←) shows its contents nested in the list without leaving the current folder, as in Finder's list view. Expanded folders refresh with the list.
- **R2.14** **Persistent server sessions:** each server's browsing session opens at launch when its password is saved, stays open (a tiny request every 2 minutes keeps servers with idle timeouts from dropping it), and reopens in the background after sleep. The last listing of each folder shows at once while a fresh one loads.
- **R2.15** **Path bar** under the file list, as in Finder (View › Show/Hide Path Bar, ⌥⌘P; on by default). It shows the path of the selected item, or of the current folder, from its drive, share or server down. Click any folder in it to go there, or drop items on one to move or copy them into it (R2.11 rules). Each pane has its own. Its right end counts the selection, as Finder's status bar does: "42 items", or "3 of 42 selected · 1.2 GB" (the size of the selected files; the tooltip notes that folders' contents aren't counted).
- **R2.16** **Icon previews:** files on drives and NAS shares show tiny Quick Look thumbnails (images, most video, PDFs), made lazily for visible rows and cached; everything else shows its type's icon. Files on servers show type icons, since a thumbnail would mean downloading the file. View › Show Icon Previews turns thumbnails off.
- **R2.17** **Quick Look:** Space (or ⌘Y, or Quick Look in the context menu) previews the selection, as in Finder; while the panel is open it follows the selection, and ↑/↓ preview the previous or next item (skipping server files too big to preview). Server files up to 64 MB (images, .nfo, subtitles, samples) are downloaded to a temporary folder to preview; larger ones say to download them first. **A folder previews as a summary,** on the Mac, a drive, a share or a server alike: its size and how many files in how many folders, the main video's details (the largest MKV, WebM, MP4 or MOV, read as the Video column reads it; on a server only an MKV's or WebM's first 256 KB is fetched), the five largest files, and the .nfo nearest the top, decoded from the DOS code page its box drawing is written in. Hidden files count only when shown. On a server the folder is listed through the browse connection, with a SUMMARY line in the strip while it's worked out. A summary is reused for 30 s. Right-click › Open opens local files in their default app, and Open With › lists the default app, every other app that can open all the selected items, and Other…. Blit opts in to Media Extensions (macOS 15+) at launch, so formats an installed extension adds (QuickLook Video: MKV, WebM, AVI) preview in Blit as they do in Finder.
- **R2.18** **Tabs of pairs:** a slim tab bar above the panes (shown with two or more tabs, in the same gutter as the cards) holds one tab per pair; tabs are at most 220 pt wide and sit at the left with + after them (tabs as wide as the panes lined up with them and read as pane headers), sharing the bar down to 100 pt each. Each tab keeps its own folders, history, sort, selection, scroll position and active side. A tab is named after its folders ("Seedbox Downloads · SSD Movies") unless renamed (double-click it, or right-click › Rename Tab…). File › New Tab (⌘T) opens the same pair beside the current tab; Close Tab (⌘W) closes it, and with one tab left ⌘W closes the window. The Window menu has Show Next / Previous Tab (⌃Tab, ⌃⇧Tab) and each tab by ⌘1…9; drag a tab along the bar to reorder it. A click shows a tab as the button goes down, as in Safari and Finder (its close button, a ⌃-click and a double-click to rename are left alone). The pixel look marks only what carries information: each tab's ⌘-number in the HUD face (a black chip on the shown tab), and a small HUD tag with the progress of a transfer started from that tab, while it runs (▼ 42%); names stay in the system font. The tag shows on that tab only, so tabs transferring at once each show their own, and goes away once the transfer stops (paused, queued or done). A transfer from a Shortcut, Finder or a since-closed tab counts as the tab showing most of its folders. The strip and HUD follow the shown tab: its own transfer (the one its tag shows), else another tab's running between its folders, else whatever runs; the HUD's queue list shows every transfer on any tab. Each transfer remembers its tab across relaunches. Tabs are saved as they change and come back on relaunch; a restored tab opens its folders when first shown, so a sleeping NAS neither holds up the launch nor loses a background tab's folder. The two panes' folders from 0.2.22 become the first tab.
- **R2.18** **Refresh:** View › Refresh (⌘R), Refresh in the file list's context menu, and Refresh on every sidebar item (favorite, server, drive, share) reload the listing, including expanded folders. From the sidebar, it reloads any pane showing that location (for a server, anything on it), or opens it. Servers also have Reconnect, which reopens the browsing session first. While a folder loads for more than a moment, the path bar shows a spinner with "Refreshing…" (or "Loading…" for a folder not seen before), gone once the listing, and any expanded folders, are in; with the path bar hidden, it shows in the list's top corner.
- **R2.11** **Drag rules follow Finder:** a drag within one volume or one server moves (a rename, instant); a drag across devices copies; holding ⌥ always copies.
- **R2.12** **File management** on drives, NAS shares and servers:
  - New Folder (⇧⌘N) creates "untitled folder" at once with its name ready to edit. With two or more items selected in one folder, right-click › New Folder with Selection (N Items), or File › New Folder with Selection (⌃⌘N), moves them into a new "New Folder With Items" beside them, its name ready to edit, as in Finder; one ⌘Z moves them back and removes the folder. Rename edits the name in place in the list (Return, as in Finder; the name without its extension starts selected; Return saves, Esc cancels, clicking away saves; if the new name has no real extension, the old one is added back, so a file keeps its type); Duplicate (local). Double-click, ⌘↓ or File › Open opens. Clicking the name of a file that is already the only one selected also renames it, after the double-click interval, as in Finder; a second click in time opens it instead. The rename field is a native text field that scrolls within its width, so a long name stays fully drawn as the cursor moves.
  - A drop onto a folder row goes into that folder, onto a file inside an expanded folder into that folder, and anywhere else (a file in the folder being viewed, or below the last row) into the folder being viewed, so items can be dragged out of an expanded folder into the folder being viewed.
  - Cut, Copy and Paste (⌘X/⌘C/⌘V), and Move Items Here (⌥⌘V). Local items also go on the pasteboard as file URLs, so copying in Finder and pasting in Blit (or the reverse) works.
  - Edit › Undo (⌘Z) for rename, moves within a volume or server, Move to Trash (puts items back), New Folder and Duplicate; cross-device transfers and permanent deletes can't be undone, and there's no redo. Get Info (⌘I) shows size (folders are totalled), where, dates and, for files Blit copied, the verification record: method, time, SHA-256 and source. Go › Go to Folder (⇧⌘G) opens a typed path on this Mac or, from a server pane, on that server.
  - Delete (⌘⌫). Local drives use the Trash, with no prompt. Servers and network shares have no Trash, so deletes there are permanent and always ask first.
  - A move across devices, or from a server, runs through the verified transfer engine. Each source file is removed only after its copy is verified by SHA-256. Files that were already present, only size-checked, or that failed stay where they were, and the log says so.
  - File operations that take more than a moment (deletes, moves, duplicates, trashing) show in the condensed transfer strip, with an item count, progress cells and the current item. A clean one leaves the strip after a few seconds; one with problems stays until dismissed.
  - Deleting on a server treats anything already gone as deleted (another client or the torrent client may have moved it), and removes a folder only after its listing is closed.
  - Uploads, and copies within or between servers, aren't supported yet. Blit says so rather than failing silently.
  - **Rename N Items…** (select several, then File › Rename or right-click), as in Finder, with a live preview of every new name.
    - Rules: Replace Text (match case, or a regular expression with `$1` groups), Add Text (before or after the name), or Format (name and index, counter, or date modified; custom text; start number).
    - The extension is kept unless "Include the extension" is on. A dot in a scene-style name isn't mistaken for one.
    - Names that are invalid, collide with another item in the folder, or would be given to two items are flagged, and Rename stays disabled until they're fixed.
    - A rule can have several steps, run in order. A later step can be set to run only if the step above changed the name, so a preset for one kind of name leaves others alone.
    - Rules are saved as presets for naming conventions. The last rule used comes back next time. Right-click › Rename With Preset ▸ applies one straight from the list: each preset is titled with what it would do (the new name for one item, how many change for several, every old and new name in its help tag), a preset that changes nothing is disabled, and ⌘Z undoes it in one step. Two presets ship with the app:
      - **Movies (Title Year):** regex `^(.+)\.((?:19|20)\d{2})(?:\..*)?$` → `$1 $2`, then `.` → space. `The.Gentlemen.2019.UHD.BluRay.2160p….mkv` becomes `The Gentlemen 2019.mkv`. It uses the last year in the name, so `Blade.Runner.2049.2017…` becomes `Blade Runner 2049 2017`.
      - **TV Shows (Show-Name_S01E01):** regex `^(.+?)\.(S\d{2,}E\d{2,}(?:-?E\d{2,})*)(?:\..*)?$` → `$1_$2`, then `.` → `-`. `South.Park.S29E01.1080p.WEB.h264-GRACE.mkv` becomes `South-Park_S29E01.mkv`. Season packs without an episode are left alone.
    - Swaps (a ↔ b) go through a temporary name. It runs in the strip, and one ⌘Z puts every name back. It works on drives, NAS shares and servers.
  - **Copy To ▸ / Move To ▸** (right-click) archive reviewed items without dragging.
    - Destinations: favorite folders (NAS first), then mounted NAS shares, then Other Folder….
    - Copy is a verified copy. Move removes each file here only once its copy is verified by SHA-256, as a cross-device move always does.
  - **Existing files ask first, as in Finder.** When a drop, paste, Copy To / Move To or Send to Blit would land on a file that already exists (same-name folders merge), Blit asks once: **Replace**, **Keep Both** (" 2" name), **Skip** (leave the existing file), or **Stop**.
    - Across devices, Replace overwrites only after the new copy is verified.
    - On the same drive, the replaced file goes to the Trash (deleted where there's none).
    - The answer overrides the Settings rule for that transfer.
  - **Problems appear in the strip, not in alerts.** A failed new folder, rename, paste, drop, duplicate, trash, Quick Look, undo or resume shows as a ✕ line in the condensed strip: what was tried, then the reason. The full text is in its tooltip and the HUD's WARNING panel, and VoiceOver announces it. It stays until dismissed.
    - A failed operation always reaches the strip, even one that fails before its progress would have shown.
    - A problem the operation already shows there isn't reported a second time.
    - Only decisions stay modal: permanent delete, trusting a host key, entering a password.

### Transfer engine

- **R3.1** Download and copy recursively, preserving folder structure and modification times. Empty folders are recreated; local symlinks are recreated as links (not followed), and a move removes them from the source once they exist at the destination. Symlinks on servers are skipped and each one is named in the log. After a move, source folders are removed deepest first once empty.
- **R3.2** **Parallel files:** N files in flight at once, N configurable per server. **Auto-tune:** the server editor's Measure… (existing servers) measures instead of guessing. It reads the largest file in the server's start folder (or one folder down, 2 GB or more) with 1, 2, 3 and 4 connections, ten seconds each after a two-second warm-up, every stream from its own tenth of the file so no pass gets another's cache, into /dev/null (nothing is kept), and offers the fewest connections within 5% of the fastest ("Use 3 Connections"). A count the server refuses is left out. The result stays with the server (the editor shows each count's MB/s and when, or that the count has been set by hand since), and the HUD's Link panel reads `CONN 3 · TUNED` while a download uses the measured count. Run only when the user asks: it's a minute of real downloading.
- **R3.3** **Split files:** files above a size threshold are downloaded in byte-range chunks over several connections.
- **R3.4** **Deep request pipelining:** many SFTP read requests in flight per connection, and a large SSH channel window. **Shortened read replies are normal:** when a server returns fewer bytes than requested (SFTPGo caps replies at 32 KB), request the remainder and keep the pipeline full. Use `limits@openssh.com` to choose the read size where the server offers it (OpenSSH 8.5 and later). See [findings](#benchmark-findings).
- **R3.5** Write to `name.blitpart`, force it to disk, verify, then rename. A partial file is never visible under its final name. On local APFS or HFS+ volumes use `F_FULLFSYNC`. Over SMB, use `fsync`; `F_FULLFSYNC` isn't supported there, and the NAS-side checksum (R4.2) provides the guarantee.
- **R3.6** **Resume:** after a dropped connection, reconnect with backoff and resume from what's already on disk.
  - **Leftover part files:** a download's `.blitpart` stays resumable, and its `.state` sidecar records the source server and path. In the browser it shows as *Partial download · NN%*, with a half-cell pixel mark and a tooltip giving bytes done and the source. Right-click › **Resume Download** queues the rest into that folder. It's disabled, with the reason, if the server is gone, the part predates this, or a transfer into the folder is already queued. Trashing or deleting a part takes its sidecar along. The sidecar alone shows as *Blit resume data*.
  - Local copies can't resume (a retry copies from the start), so a failed or stopped copy removes its `.blitpart` at once instead of leaving multi-GB leftovers on the share.
- **R3.7** Use large buffers that bypass the system cache (`F_NOCACHE`). Preallocate the destination (`F_PREALLOCATE`) on local volumes only; it's often unsupported over SMB. *Copies do both; downloads preallocate but don't bypass the cache.* That isn't needed: at 50–90 MB/s the page cache isn't a bottleneck, and macOS frees it on its own.
- **R3.8** Use APFS clones (`clonefile`) for copies within the same volume.
- **R3.9** **Stability gate:** a remote file is eligible for download only once its size and modification time are unchanged across two checks, because files may still be written or assembled on the seedbox. If the size changed since listing, re-list; don't treat it as corruption.
- **R3.10** **Filename policy:** Linux allows any bytes in a filename, but APFS requires valid UTF-8 and treats different Unicode normalizations of a name as the same file, and SMB forbids some characters. Blit escapes names that can't be stored, detects names that would collide, and records the original name in the transfer log.
- **R3.11** **Timestamps:** SFTP v3 modification times are whole seconds. Comparisons (R2.4, R5.3) allow for that.

### Integrity

- **R4.0** **Verify files** (Settings): **SHA-256** (the default, recommended) or **Size only (faster)**.
  - Size only skips hashing on the server and NAS. Every byte must still arrive and sizes must match before a file gets its real name.
  - The choice is saved per queued job. **Moves always verify** by SHA-256, because their sources are removed only after a hash has matched.
  - Size-only-by-choice results are labelled plainly ("= size-checked (verify off)", Status "size only", log method `verify-off`) but aren't treated as problems. The red warning is kept for files the server couldn't hash, which is `size-only`.
- **R4.1** **Remote to local:** compare the local file's SHA-256 with `sha256sum` run on the server over an SSH exec channel. This is the only way to get a remote hash: neither SFTPGo nor OpenSSH supports the SFTP `check-file` extension. Start the hash the moment a file finishes downloading, while it's still in the server's cache. Store hashes on the server under `~/.cache/blit/`, outside the download folders, keyed by path, size, and modification time, so a file is never hashed twice. Filenames are untrusted: pass them NUL-delimited over stdin (`xargs -0`) and never paste them into a shell command. If the server has no shell access, fall back to comparing sizes and warn. Only a server that genuinely can't hash (exec refused, or no `sha256sum`: exit 126/127) gets that fallback; a hash that was interrupted, or failed for one file, keeps the part file and retries. The script checks that the read succeeded and that the file didn't change while it was hashed before caching; the cache key also includes ctime and inode, and a cached hash that disagrees is recomputed once before the file fails.
- **R4.2** **Local to NAS:** hash the source while copying, then compare with `sha256sum` run **on the NAS** over SSH (R1.6), reusing R4.1's code. Reading the copy back over SMB isn't reliable: `F_NOCACHE` doesn't clear pages cached during the write, and the SMB client can answer reads from its local cache. So read-back is only a fallback, and is flagged as weaker, when a NAS has no SSH access; an interrupted NAS hash never falls back to it. Verification can be switched off for trusted paths, but it's on by default.
- **R4.3** A mismatch re-downloads the affected file, and a file that fails verification again (or keeps changing on the server) stops retrying instead of looping. Files are never silently accepted. The final rename never replaces something that appeared at the destination during the transfer, and range state is recorded only after its bytes are flushed to disk. Hashing each chunk on the server was ruled out, because reading ranges adds disk seeks on the server.
- **R4.4** Keep a per-transfer record (file, size, hash, source, destination, time) as an exportable log. Window › Transfer Log (⌥⌘L) shows it newest first, searchable by name, path or SHA-256, filterable (All / Verified / Not hash-verified / Failed), with the full record, Show in Finder and Copy SHA-256 for the selected file; it updates as transfers finish. File › Export Transfer Log… writes CSV. **Monthly totals:** the window's Files | Months switch shows each month, newest first: what moved (files and bytes, not counting files already there or clones), how much of it was SHA-256 verified ("all verified", or "2,170 verified · 10 size only"), files already there, failures, and the speed of downloads and of copies. Speed counts only the seconds bytes were moving (waits, pauses and checksums don't), from a small log of finished jobs (`jobs.jsonl`, kept since 0.2.45, so earlier months show "—"). The menu bar panel shows this month's line: "October: 24.3 TB · 2,180 files · all verified · downloads 81 MB/s". Each record notes when the server answered the SHA-256 from its hash cache (CSV column `server_cache`; the log window says so). The HUD's Link panel counts cache hits for the job (HASH CACHE n/m). When a download runs a minute with every connection even but the total under 40 MB/s, the log says once that the rate looks server-disk bound (cold files read slower than cached ones), worded as a likelihood, so it isn't mistaken for a network problem.

### Queue and UX

- **R5.1** The queue survives app restarts and reboots.
- **R5.2** Pause, resume, reorder, and cancel, per item and globally. The HUD's Queue panel lists every transfer with its state; each row has Pause/Resume, Cancel (✕), ▲/▼ to reorder waiting jobs, and Retry for failed or cancelled ones, and clicking a row shows it in the HUD. Pause All / Resume All hold the whole queue (also in the menu bar panel and the strip's right-click menu). Pausing a running job closes its connections (downloads) or stops the copy at its next block; it resumes from its part files. Cancel keeps part files, so Retry picks up where it stopped; files already at the destination are skipped. Paused jobs and a paused queue survive a restart. A job waiting to retry shows **Retry Now** (strip, queue row, right-click, menu bar) to skip the backoff once the cause is fixed. After the countdown the strip says what it is really waiting for ("waiting for the network", "waiting for SSD to come back · reconnect it") instead of an expired timer. The queue runs in two lanes, one download and one local copy at a time, since they use different links (the internet and the home network); within a lane jobs run in order. A copy whose source is, or holds, the destination of a download queued ahead of it waits for that download, so a pack isn't copied to the NAS half-downloaded.
- **R5.3** When a file already exists, apply a rule per queue: skip, overwrite, keep both, or overwrite only if different (size and hash). *Implemented* as Settings › When a file already exists, captured per transfer when queued (saved with the queue; shown as EXISTS in the HUD): **Skip if the same size** (default; a different size fails the file), **Replace if different** (same size: SHA-256 of both copies, on the server or NAS where possible; identical is left and counts as verified, so a move may remove its source; different is transferred again), **Replace** (always, verified as usual), **Keep both** (the new file becomes "name 2.ext").
- **R5.4** Show live throughput per connection and overall, plus time remaining.
- **R5.5** Send a notification when a queue finishes or fails.
- **R5.6** Keep the Mac awake while transfers run. The menu bar panel says so ("Keeping the Mac awake · 2 queued · 1.9 TB left · ~2 d 4 h"), so it can be confirmed before walking away. Idle sleep is held off; the display can still sleep.
- **R5.7** A menu bar item shows what's running at a glance, at a fixed width so it never nudges its neighbours: the arrow (its tray filling with progress) and time left at a 15 s average ("12m", "1h05"), or percent done (Settings › General). With a download and a copy running at once it shows two small lines, one per lane. Speed and names are in the panel, which adds queue totals: jobs queued and paused, bytes left in jobs whose size is known, and an ETA worked out per lane (the slower lane decides).
- **R5.8** **Queue-wide disk space:** before starting each item, check the destination's free space against everything still queued for it. If it would run out, pause the queue; don't fail the file. *Implemented per item:* after listing, a transfer works out the new space it needs (files already there, part files, which reserve their full size, and same-volume clones count as nothing) and, if the destination is short (plus a 1 GB reserve; APFS purgeable space counts), waits with `WAITING FOR SPACE · <volume> NEEDS <n> MORE`, notifies once, and rechecks every 15 s, continuing by itself; Pause and Cancel still work. Running out mid-transfer ("No space left on device") waits the same way instead of retrying into a full disk. *Queue-wide checking is not planned:* a queued job's size is only known once its source is listed when it starts, and listing every queued job up front would load the seedbox. Each job waits for space instead of failing.
- **R5.9** **Empty the Trash to get space back.** Deleted files keep their space until the Trash is emptied. Blit › Empty Trash… (⇧⌘⌫) empties every Trash through Finder (macOS asks once to let Blit control Finder); right-click a drive › Empty Trash on “SSD”… empties that drive's own Trash only. While a transfer waits for space, the strip offers EMPTY TRASH · 64 GB when the destination drive's Trash holds some. Each empty asks first with the item count and size; it's the one permanent action in Blit. NAS shares keep their own recycle bin on the NAS, which Blit leaves alone.
- **R5.10** **Watch mode (server → this Mac only):** right-click a folder on a server, or empty space in one, › Watch for New Downloads…, then pick a folder on this Mac (the other pane's, a favorite, or any) and how often to look (1, 2, 5 or 15 minutes). Blit lists the folder that often and downloads each new item, as an ordinary verified copy (never a move, so the server keeps seeding), while it's still in the server's cache (2–3× faster than cold files, open question 10). What's there when watching begins, or when a watch is switched back on, counts as seen. **When qBittorrent runs on the server, its own records decide** (added 2026-10-07, after the user's stalled torrents showed the gap): Blit finds its BT_backup folder over SFTP (a seedbox's `~/.apps/qbittorrent`, or the usual Linux places, looked for daily), matches each new item to the torrent that saves it into the watched folder (by the .torrent's name, and its files' first folders for a torrent laid out without a subfolder), and fetches it only once the .fastresume says it completed (libtorrent's completed time, or every piece present); until then Settings › Watch shows it as still downloading, with how far along, however long its files have been quiet. No login to qBittorrent is needed; its Web API isn't used. qBittorrent's incomplete folder (its TempPath) is never fetched when it lies in the watched folder. Measured on the user's seedbox: of 34 items in the downloads folder, 13 finished and 16 stalled torrents were told apart correctly (the stalled ones had partial data on disk and would have passed the timing rules). **Anything else** is fetched only once it's finished by its files: no partial-download names in it (.part, .!qB, .!ut, .crdownload, .aria2…), and its total size and newest modification time unchanged since the last look and at least two minutes old (clients often make files their full size before the bytes arrive, so size alone isn't trusted); with another client, best pointed at the folder it moves finished downloads into. Something already at the destination by that name is skipped. Settings › Watch lists the watches with a switch, the interval, when each last looked, what's waiting and what it last fetched, or what's wrong (the server unreachable, the destination drive not mounted); a watched server shows an eye in the sidebar. Kept in Application Support. There is deliberately no watch from this Mac to a NAS: archiving stays the user's review step.

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

### Head to head: Blit, lftp, rclone (2026-09-29)

Measured with [`scripts/sftp-compare.sh`](scripts/sftp-compare.sh): one 2,380 MB file from the seedbox (148 ms away) through the SFTP endpoint, whole-file downloads with login included, after an untimed warm-up read so every method found the file in the server's cache. One run each, on a shared server, so differences of a few MB/s are within noise.

| Method | MB/s |
|---|---:|
| lftp 4.9, 8 connections, 32 KB × 64 in flight | 71.3 |
| rclone 1.75, defaults (4 streams) | 39.3 |
| rclone, 3 streams, 255 KB chunks × 64 | 26.7 |
| rclone, 8 streams, 255 KB chunks × 64 | 54.8 |
| **Blit, 3 connections** | **75.4** |
| Blit, 3 connections, SHA-256 checked against the server | 65.8 |
| Blit, 4 connections | 72.5 |

What it shows:

1. **Blit matches lftp's best with 3 connections instead of 8,** and lftp doesn't verify anything. Checked end to end against the server's SHA-256, Blit still gets 65.8 MB/s.
2. **Blit is 1.4× rclone's best and 2.8× rclone at the same 3 connections.** rclone got slower with larger chunks (26.7 MB/s at 255 KB), consistent with the endpoint's 32 KB cap on read replies (see [What the numbers mean](#what-the-numbers-mean)).
3. **4 connections were no faster than 3** here, matching the M1 result that 3–4 connections reach the server's ceiling.
4. The M1 spike's 89–93 MB/s (2026-09-24) came from a different day and file; the server is shared, so absolute speeds vary from day to day. The comparison between methods in one run is what counts.

### LAN

- The Mac's 2.5 GbE USB adapter negotiates **1000baseT**, because the core switch has only gigabit ports. Every wired path is limited to about 113 MB/s.
- **The Mac reached the NAS over Wi-Fi, not the wire (found and fixed in M2/M3).** Its Wi-Fi was on the NAS's subnet (192.168.20.x) while the wired port was on 192.168.10.x, so macOS routed all NAS traffic over Wi-Fi. Reading a file from the Media share ran at **58.7 MB/s over Wi-Fi**; after the Mac's switch port was moved to the 20.x network and the shares remounted, the same test ran at **105.6 MB/s over the wire**. Existing SMB connections stay on the interface they were made on until the share is remounted. Blit should detect and warn when a NAS is reached over Wi-Fi while a wired interface is up (see R1.7).
- **Shares stuck on Wi-Fi after a reconnect (found 2026-09-30).** A laptop copied to the NAS at 0–9 MB/s with a gigabit cable plugged in: its Files share had connected over Wi-Fi. On the desktop, Files and Media had reconnected over Wi-Fi after a network drop and stayed there for a day (the Mac had sent 95 GB over Wi-Fi and 46 GB over the cable since it started). Blit's check looked at the route a new connection would take, which was the cable, so it never warned. It now reads each share's live connection and moves a share stuck on Wi-Fi back to the cable (R1.7).
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
| **M5** | Hardening | Handling network changes, sleep and wake, drive ejection, transfer log export, signing and notarization. **Done so far:** TCP keepalive and a 60 s SFTP stall watchdog (dead links detected in about a minute); automatic retry with backoff (10 s → 5 min), waiting for the network and for missing drives or shares to return, resuming from `.blitpart` state; permanent failures fail fast; idle sleep disabled while transferring; Developer ID signing via `scripts/release.sh` (cloud-managed certificate). **Released:** 0.1 (build 1) notarized by Apple, stapled, Gatekeeper-accepted, installed to `/Applications` (2026-09-25). 0.2 (build 3), 2026-09-26: file management, Finder parity (undo, Get Info, Go to Folder, Quick Look), the QA/UX review's fixes, queue controls and two lanes, free-space waiting, the existing-files rule, SSH keys, the Status column, problems in the strip, Retry Now, Rename N Items with convention presets, Copy To / Move To. 0.2.1 (build 4): the selection count in the path bar. 0.2.2 (build 5): sidebar rows highlight while a drag is over them. 0.2.3 (build 6): quitting mid-transfer no longer logs the files it cuts off as failures; the installer waits for Blit to exit before relaunching. 0.2.4 (build 7): the expanded HUD keeps a fixed height, the Link panel shows the right window size, and drives, shares and servers can be added to Favorites from the sidebar. 0.2.5 (build 8): Verify files setting (SHA-256 or size only; moves always verify), automatic updates via Sparkle (the first build that can update itself), licensing built in but switched off until launch. 0.2.6 (build 9): Settings in tabs; the first release published as an update. 0.2.7 (build 10): NAS shares reconnect, no main-thread statfs on hung shares, clearer size-only labels. 0.2.8 (build 11): click to rename; the rename field scrolls long names. 0.2.9 (build 12): toolbar search (⌘F); existing files ask Replace / Keep Both / Skip / Stop. 0.2.10 (build 13): fixed-width menu bar item with time left, tray progress and both lanes; SHA-256 progress for copies; the arrow points up for copies onto a share. 0.2.11 (build 14): notifications rewritten (what happened and where, the item as subtitle, size, verification and speed; Show in Finder and Show Details). 0.2.12 (build 15): Empty Trash (Blit menu, per drive, and offered while a transfer waits for space). 0.2.13 (build 16): reliability fixes (Wi-Fi route advisory no longer fails verified copies, capped SHA-256 mismatch retries, keyboard follows the active pane, dead browse sessions reconnect, no main-thread waits on hung shares). 0.2.14 (build 17): a favorite on a server's start folder gets its own menu (Remove from Favorites, not Remove server). 0.2.15 (build 18): Move to Trash in its own section of the file menu, between Get Info and New Folder. 0.2.16 (build 19): Open and Open With for local files; Space previews video and audio Quick Look can't play in mpv. 0.2.17 (build 20): the mpv preview removed (Space is Quick Look again). 0.2.18 (build 21): Quick Look plays formats Media Extensions add (QuickLook Video: MKV, WebM, AVI), as in Finder. 0.2.19 (build 22): drops onto a folder in the file list work (the folder under the pointer lights up and takes the drop; multi-item drops no longer hang). 0.2.20 (build 23): the drop highlight clears after a drop; sidebar favorites take files into their folder and only folders become favorites; the full HUD collapses after a clean, verified queue. 0.2.21 (build 24): dragging files out to Finder, Books or the Desktop hands over the file itself (not a "Blit Locations" data file); two panes by default with Copy / Move to Other Pane (F5 / F6), Swap Panes (⌘U) and remembered folders; View › Columns. 0.2.22 (build 25): the UX pass: panes read as a pair (cards, a send-to chip, volume badges, free space), one line per file with dates that fit, columns that fit each pane, a full HUD about 40% shorter, a 720 × 480 minimum window. 0.2.23 (build 26): tabs of pairs (R2.18): each tab keeps its own two panes, ⌘T / ⌘W / ⌃Tab / ⌘1…9, drag to reorder, rename, restored on relaunch, and a HUD tag on tabs a transfer touches. 0.2.24 (build 27): tabs at most 220 pt wide, at the left, so they no longer read as pane headers. 0.2.25 (build 28): right-clicking (or ⌃-clicking) empty space in a list shows the folder menu reliably. 0.2.26 (build 29): Finder's drag rule: a drag from a file's icon or name moves it, from the rest of the row selects rows. 0.2.27 (build 30): during a transfer, only its own files show a status tag, not everything already in the destination folder. 0.2.28 (build 31): a server file's drag carries only Blit's payload (Finder refuses it instead of writing a "Blit Locations" file); the tab bar compares folders by path, never on disk. 0.2.29 (build 32): a quick flick between panes no longer freezes the window (the drop highlight no longer rebuilds the list mid-drag), and a drag takes the row pressed. 0.2.30 (build 33): the drop outline never stays on after a drop (a late "drag moved" is ignored). 0.2.31 (build 34): iCloud Drive and File Provider folders (Proton Drive…) under Drives (R2.19); sidebar drops never leave a line or highlight; a move never clones. 0.2.32 (build 35): Open With shows each app's icon. 0.2.33 (build 36): Acknowledgements (About Blit › Acknowledgements): the third-party notices Blit ships, generated from the resolved packages. 0.2.34 (build 37): copying to a busy NAS no longer freezes the window (file rows compare paths as text, never asking the disk). 0.2.35 (build 38): a NAS share stuck on Wi-Fi (connected, or reconnected after a drop, while only Wi-Fi was up) is reconnected over the cable before a transfer uses it, when that's safe; the LINK row shows each share's live interface (R1.7). 0.2.36 (build 39): tabs always fit the bar (an overflowing bar had pushed the sidebar and panes off the window's edges), and dragging a tab takes it to any slot, the far left included. 0.2.37 (build 40): Rename N Items shows spaces at either end of Find and Replace with (each drawn as ␣), and the preview says when nothing matches. 0.2.38 (build 41): Pause and Cancel take hold during verification (a NAS read-back never checked for a stop) and are on the strip and HUD for every transfer, showing PAUSING… / CANCELLING… until the copy stops; folders light up under a drag while a transfer runs (the open HUD defeated the row lookup); the HUD follows the tab. 0.2.39 (build 42): the strip's WARNING tag opens a list of what went wrong (it did nothing for file operations), and a failed operation's strip line gives the reason. 0.2.40 (build 43): Full Disk Access explained once (R2.20): a first-launch sheet with Open System Settings, a row in Settings › General, and a pointer in the warnings of an operation macOS turned away. 0.2.41 (build 44): the file list is AppKit's (M6): tab switches take about 50 ms (0.2 s before, and 1 s at 10,000 files), a folder selected in one pane takes a drop from the other, and a file inside an expanded folder lights the folder a drop goes into; tabs switch as the button goes down; a tab's tag shows only the transfer started from that tab, while it runs. 0.2.42 (build 45): folders open from their disclosure triangle again (in 0.2.41 a click there selected the row instead), and a list keeps to its pane's width after a resize. 0.2.43 (build 46): New Folder with Selection (right-click with several items selected, or File › New Folder with Selection, ⌃⌘N), as in Finder, with one step to undo. 0.2.44 (build 47): a name being edited keeps its field while its folder reloads (on a NAS, a transfer finishing into the folder could re-sort the rows and end the rename before any typing); the list catches up once editing ends. 0.2.45 (build 48): fourteen additions: Rename With Preset in the right-click menu; spring-loaded folders; a dot on what's new since your last visit (R2.21); Compare Panes, ⌃⌘C (R2.22); the Video column (R2.6); free space shown while dragging (R2.10); Space on a folder shows a summary (R2.17); monthly totals in the Transfer Log and menu bar (R4.4); a pixel flourish when a big queue finishes verified; suggested destinations, ⇧F5/⇧F6 (R2.23); importing servers from Transmit and ForkLift (R1.8); a Welcome for new installs (R2.24); watch mode for new seedbox downloads (R5.10); and measuring the best connection count per server (R3.2). | ✅ Done |
| **M6** | Native file list | The file list rebuilt on AppKit's NSTableView in place of SwiftUI's Table, whose tab switches cost about 0.2 s (SwiftUI rebuilt every visible cell) and whose gaps needed workarounds: a global monitor for click to rename, an empty-space menu that found the list by position, guesses at where a drag started, a rewritten drag pasteboard, polled scroll positions. One list per pane shows whichever tab is shown, swapping its rows in place, and its cells draw themselves. **Measured** (optimized build): a tab switch takes 50 ms at 300 files and 56 ms at 10,000 (SwiftUI's Table: 0.2 s and 1 s), a resize at 10,000 files 41 ms (1 s), and the app uses 172 MB there (230 MB). Every list test ran on both lists before the SwiftUI one was removed, including real clicks, keys and drags (tabs, two panes, drops, selecting rows, the sidebar, dragging out to Finder). Fixed on the way: a folder selected in one pane refused a drag from the other. | ✅ Done |

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
10. ~~**Fetch new downloads automatically?**~~ **Built (R5.10):** watch mode fetches new finished downloads from a server folder to this Mac while they're still in the seedbox's cache.
12. ~~**Distribution?**~~ **Decided (2026-09-26): sold directly from the website, not the Mac App Store.** Price $15–20, one-time, with a 7-day trial. Closed source for now; when v2.0 ships, v1.0 may be open-sourced (the license is still to be chosen).
    - Reasons: Blit isn't sandboxed and relies on things the sandbox makes hard (`~/.ssh` keys and `known_hosts`, any mounted volume, Finder Services), same-day notarized releases, and better margins.
    - Still to build: merchant-of-record checkout (it handles sales tax and VAT), license keys with the trial, automatic updates (Sparkle), a first-run flow (done: R2.24), a privacy policy, a EULA and a support address. Also a trademark check on the name, and possibly a lower minimum macOS to widen the audience.
    - When the trial ends, starting new transfers is locked. Transfers already queued or running still finish, and browsing, the log and files stay available.
    - **Automatic updates (Sparkle 2.10):**
      - Release builds check `https://blit.banast.as/appcast.xml` daily and install updates signed with the EdDSA key. The public key is in `Support/Info.plist`; the private key is in the release Mac's login Keychain, so back it up with Sparkle's `generate_keys -x`.
      - Blit › Check for Updates… checks now; Settings › Updates turns the daily check off. Debug builds don't run the updater.
      - `PUBLISH=1 scripts/release.sh` signs the zip, puts it in `site/downloads/`, writes the appcast and pushes; Cloudflare Pages serves it.
      - The site's Download buttons fetch `downloads/Blit.zip` once the site is `LIVE`.
      - **Verified end to end (2026-09-26):** the installed 0.2.5 found 0.2.6 in the feed via Check for Updates, showed the release note, downloaded it, checked the signature and relaunched as 0.2.6 (notarized, Gatekeeper-accepted).
    - **Switched off until launch:** `LicenseConfig.enforced = false` in 0.2.5. There's no trial clock, no Keychain writes, no License UI, and transfers are never locked. It's turned on for 0.3.0. Isolated test copies always enforce, so the license tests still run.
    - **Built (app side):**
      - The trial runs 7 days from first launch; its start is kept in the Keychain, so a reinstall doesn't restart it.
      - Settings › License shows the trial or license status, takes a key (Activate), frees this Mac (Deactivate This Mac), and links to Buy. The Blit menu has Buy Blit… and Enter License….
      - Keys are activated per Mac with Lemon Squeezy's public license API (`/v1/licenses/activate`, `validate`, `deactivate`), with no Blit server. Each key is re-checked weekly. A Mac that can't reach the API stays licensed for 30 days past the weekly check, then asks to reconnect (the key is kept). Only an answer from the store revokes a key.
      - Only keys for Blit's store (484060) and product are accepted. The product is currently the test-mode one (1390732); the live product's ID goes in when the store goes live. Test-mode keys unlock debug builds only.
      - Verified end to end with a test-mode purchase: checkout overlay → receipt with the key → activate ("Licensed to …") → weekly check → deactivate (activation freed).
    - Marketing stays on big-file work (photo and video, archiving, NAS backups).
11. ~~**Chained transfers (seedbox → SSD → NAS in one go)?**~~ **Decided: deprioritized.** The user is the review step between SSD and NAS: everything downloaded gets reviewed on the SSD, renamed to the naming conventions where needed, and only then archived to whichever NAS location fits (or not at all). Automating SSD → NAS would skip that step. Work on the middle of the workflow should make review faster, not bypass it.

## Repository layout

```
blit/
├── README.md             this document (the PRD)
├── scripts/
│   ├── sftp-probe.sh     quick per-method SFTP speed probe (20 s each)
│   ├── sftp-bench.sh     longer parallel-file / chunked-file benchmark with checksums
│   ├── make-icon.swift   renders the pixel-art app icon (Blit/AppIcon.icon)
│   ├── acknowledgements.py  writes Blit/Resources/Acknowledgements.txt (third-party notices) from the resolved packages
│   └── release.sh        Developer ID build, notarization, stapling, optional install (runs acknowledgements.py first)
├── spike/                M1 throwaway: SwiftNIO SSH + minimal pipelined SFTP client
│   ├── Package.swift
│   ├── Sources/blit-spike/main.swift
│   ├── run-m1.sh         the M1 test matrix
│   └── run-m1b.sh        M1 follow-ups (SFTPGo, 255 KB reads, disk-write cost)
├── Blit.xcodeproj/       the Mac app (macOS 27, SwiftUI); Blit/ is a folder-synced group
├── Blit/                 app sources: BlitApp, Model/, Views/, Intents/, Resources/Fonts/, AppIcon.icon
├── Support/Info.plist    merged into the generated Info.plist (drag type, Services)
├── site/                 the single-page website (blit.banast.as): static HTML, HUD fonts, no build step
└── BlitKit/              the transfer engine (Swift package; the app links it locally)
    ├── Package.swift
    ├── Sources/BlitSFTP/   SFTP v3 protocol: messages, attributes, framer, read planner
    ├── Sources/BlitRemote/ SSH connections, host keys, SFTP client, parallel verified downloads
    ├── Sources/BlitLocal/  verified local/SMB copies, NAS-side checks, network-path check
    ├── Sources/BlitMedia/  video headers for the Video column: Matroska and HEVC parameter sets, MP4 via AVFoundation
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

```bash
# Head to head: Blit's engine against rclone and lftp, whole-file downloads of one file (0.5–3 GB)
PORT=3232 scripts/sftp-compare.sh user@host "path/to/folder/"
```

`sftp-compare.sh` also needs `rclone` (`brew install rclone`) and builds the `blit` tool first.

`SHELL_PORT` / `SSH_PORT` set the SSH shell endpoint used for the server's disk-read test and checksums, when it differs from the SFTP port. Connect once with `ssh -p PORT user@host` first, so the host key is trusted before running the scripts.

**Known limitation:** `sftp-probe.sh` starts timing before login, so higher connection counts pay more login time within the 20-second window. That understates their speed; fixing it to time from first byte is part of M1.

## License

TBD.

### Third-party fonts

Bundled in `Blit/Resources/Fonts/`, each with its license:

- **Silkscreen** by The Silkscreen Project Authors, SIL Open Font License 1.1 (`Silkscreen-OFL.txt`).
- **VT323** by The VT323 Project Authors, SIL Open Font License 1.1 (`VT323-OFL.txt`).
