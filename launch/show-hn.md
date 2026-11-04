# Show HN draft

Draft for Hacker News, revised 2026-11-04 for the open-source release (see *Before posting*). HN readers want specifics and distrust marketing, so this names the tools it was measured against (the website doesn't) and leads with what was learned, not with adjectives.

## Title

Pick one (80 characters at most; no "fastest" or "best", which HN dislikes):

1. `Show HN: Blit – a Mac app for moving big files over SFTP that checks every byte` (79)
2. `Show HN: Blit – verified SFTP-to-NAS transfers for the Mac` (58)
3. `Show HN: Blit – I rebuilt my 30 TB/month file workflow as a native Mac app` (74)
4. `Show HN: Blit – open-source Mac app for verified SFTP transfers at 75 MB/s` (75)

**URL:** https://github.com/banastas/Blit (HN prefers the source for open-source projects; the site is linked from the README)

## Text

> Hi HN. I move about 27–30 TB a month from a server in Europe (148 ms away) to an external SSD, look through it there, then move what I keep to a Synology NAS. The Mac file apps I used for this became unreliable on recent macOS releases, and scripting lftp gave me speed but no way to know every file arrived intact. So I built Blit, a native Mac app that does only this: SFTP servers, local drives, and NAS shares.
>
> What it does:
>
> - Downloads split each file across 3 connections and resume after a dropped connection, sleep, or a quit.
> - Every download is checked against a SHA-256 that the server computes itself (`sha256sum` over an SSH exec channel; SFTP servers don't offer hashes).
> - Every copy to the NAS is checked by running `sha256sum` on the NAS over SSH, not by reading it back over SMB, where the Mac's cache can answer instead of the disk.
> - A two-pane browser (F5 copy, F6 move, tabs for pairs of folders), a queue that survives restarts, and a pixel-terminal progress HUD.
>
> What I learned about SFTP speed over long distances:
>
> - OpenSSH's client uses a fixed 2 MiB channel window, which caps one connection at about 10.7 MB/s at 148 ms, whatever you pass to `-B` or `-R`.
> - macOS lets a connection's automatic receive buffer grow only to 4 MB (`net.inet.tcp.autorcvbufmax`). That's why one connection topped out around 24.5 MB/s. Setting `SO_RCVBUF` to 7 MB before connecting got one connection to 32–43 MB/s, with no system changes.
> - Some SFTP servers built on Go's `pkg/sftp` (SFTPGo, for one) cap read replies at 32 KB. The protocol allows short replies, but clients that don't expect them fall apart: lftp with 64 KB reads dropped to 0.36 MB/s.
> - Requests in flight matter as much as the window. 64 × 32 KB is only 2 MB in flight; 32 × 255 KB is 8 MB.
>
> Same 2.38 GB file, same server, warm cache, whole-file downloads including login: Blit on 3 connections [75.4] MB/s ([65.8] with the SHA-256 check), lftp on 8 connections [71.3], rclone at its best setting (8 streams) [54.8] and at its defaults [39.3]. SSD to NAS over wired gigabit: 106 MB/s, verified on the NAS.
>
> It's Swift 6 with SwiftUI and AppKit on SwiftNIO SSH, for macOS 27 on Apple Silicon only. It's free and MIT-licensed, with no account; the signed, notarized build at blit.banast.as is pay-what-you-want. There's also a `blit` command-line tool on the same engine, and the benchmark scripts are in the repo.
>
> I'd especially like to hear from people with other long-distance setups: does 3–4 connections hold up for you, and which servers break it?

The bracketed numbers are from one run on 2026-09-29. Replace them with the `ROUNDS=3` results before posting (see below).

## Before posting

- [x] Lemon Squeezy live, and 1.0 released with licensing on (2026-10-08).
- [ ] Repository public, and a release without the trial or license check published (the site's Download must not ask for a key).
- [ ] Lemon Squeezy product switched to pay-what-you-want.
- [ ] Benchmarks rerun with `ROUNDS=3 PORT=… scripts/sftp-compare.sh …` on two different days; update the numbers here, in the X thread, and on the site.
- [x] Benchmark scripts are checkable: `scripts/sftp-compare.sh` is in the public repo.
- [ ] The site loads fast and the download works without the checkout or an account.
- [ ] Post on a weekday morning US Eastern time. Stay around for the first 2–3 hours to answer comments.
- [ ] Don't ask anyone to upvote. HN detects and penalizes vote rings.

## Answers to have ready

- **Why not rsync / rclone / lftp in a script?** rsync over SSH is one stream, and the 2 MiB window limits it the same way. lftp is as fast but checks nothing. rclone was slower on this server, and its hash checks depend on which hash commands the server runs. Blit's reason to exist is speed *and* verification *and* recovery, with a UI for reviewing before the NAS step.
- **Why open source, and why pay?** It was $19 at launch; a tool that claims to verify every byte is easier to trust when you can read it. The code is MIT. Paying for the signed build is optional and funds maintenance.
- **Can I build it myself?** Yes: Xcode 27, `xcodebuild -scheme Blit`. The engine and CLI build with `swift build` in `BlitKit/`.
- **Why macOS 27 and Apple Silicon only?** One person testing; it uses current SwiftUI and system APIs, and the target users are on current Macs.
- **Does server-side hashing need shell access?** Yes: SSH exec on the server (or a separate shell port, which Blit supports). Without it, Blit falls back to size checks and labels them as such.
- **Is this for seedboxes?** It works with any SFTP server; a seedbox is one common case. Keep the answer about the transfer problem.
- **Why not the Mac App Store?** The sandbox and review don't fit an app that opens raw SSH connections and runs commands on your NAS. Distributed directly, notarized, with Sparkle updates.
- **How does it compare with Transmit / ForkLift / Cyberduck?** Those are broad, general tools (cloud storage, sync, editing). Blit does one narrow job and verifies it. Be generous about them.
