# Blit on Product Hunt

Everything the submission form asks for, ready to paste, as Rune's (Rune's `launch/product-hunt.md`).
Written plainly: what Blit does, said literally. The images are in `launch/product-hunt/`, made by
`scripts/make-brand.sh`: the first from `scripts/brand/blit-brand.html#ph`, the rest from
`scripts/brand/blit-ph.html`. Speeds are given as percentages, measured against other methods on the
same connection (the site's section 02): a speed in MB/s depends on the reader's connection. The gain
is largest from a distant server on a fast connection, and the copy says so. If the benchmarks are
rerun, change the numbers on the site, in the speed image and in the comment below.

## The form

**Name** (40 characters at most)

> Blit

**Tagline** (60 at most; no full stop). Pick one:

> Big files, moved fast, proven intact (36)

> A Mac app that moves big files fast and checks every one (56)

> Big files from your servers to your Mac, checked by SHA-256 (59)

The first is Blit's own line, on the site and every image; the second says what it is; the third
says how it's checked.

**Description** (260 at most; this is the length shown in previews)

> Blit is a native Mac app for moving big files between SFTP servers, external drives and NAS shares. It checks every file by SHA-256 at its destination, is up to 769% faster than stock sftp from distant servers, and fetches new downloads as they finish.

(252 characters.)

**Links:** https://blit.banast.as

**Topics** (up to 3): Mac · Productivity · Developer Tools (as Rune).

**Pricing:** Paid, with a free trial: $19 once, for 3 Macs; 7 days free on each Mac.

**Thumbnail** (240×240): `launch/product-hunt/thumbnail-240x240.png`, the app icon.

**Gallery** (1270×760, in this order; the first is also the preview when the page is shared):
1. `1-blit-1270x760.png`: the icon, name and tagline, and the transfer HUD mid-download (74.2 MB/s, 17 of 26 files verified).
2. `2-verified-1270x760.png`: SHA-256 on the server while downloading, with a mismatch caught and retried, and `sha256sum` on the NAS while copying.
3. `3-speed-1270x760.png`: one big file from a server 148 ms away, against stock sftp on the same connection: Blit 769% faster, the fastest single-connection Mac client measured 130% faster.
4. `4-new-downloads-1270x760.png`: a watched server folder with qBittorrent's status beside each item, and a download's notification with its still, Quick Look and Rename. The names are freely shared downloads (Linux ISOs, Blender's open movies).

**Makers:** you. **Hunter:** you, or someone else willing to post it.

**Shoutouts** (products used to build and run Blit; all have Product Hunt pages, checked 2026-10-08):
1. **Lemon Squeezy:** checkout, sales tax and the license keys; Blit checks keys with its license API, so there's no server of ours.
2. **Sparkle** (the "Open source software update framework for the Mac" listing, not the others of that name): Blit's signed updates.
3. **Cloudflare Pages:** hosts blit.banast.as, the downloads and the update feed.
4. **Xcode:** Blit is built in it, in Swift.
5. **Claude Code** (optional; your call to say it): Blit, its tests and its site were written with it.

Not on Product Hunt: QuickLook Video (MKV in Quick Look) and Synology. Transmit and ForkLift aren't
shoutouts either way: shoutouts are for what you built with, and they're the apps Blit is compared with.

## The maker's first comment

> My work depends on moving large files between servers in other countries and my own drives, and production waits until they arrive. I used Transmit and ForkLift for years, and they're good apps, but they move a big file over one connection, and over a long distance one connection can't use a fast line. Blit started with one question: could those files move faster?
>
> They can. From a server 148 ms away, Blit downloads a big file up to 278% faster than the fastest Mac app I measured, and up to 769% faster than stock sftp, and it checks every file it moves. The gain is largest when the server is far away and your connection is fast.
>
> - Each file is split across 3 connections, and transfers resume after a dropped connection, sleep or a quit.
> - Every file is checked by SHA-256 at its destination. The server computes its own hash, and copies to a NAS are checked by running `sha256sum` on the NAS, so the check reads the NAS's disk, not the Mac's cache. A file gets its real name only after the hashes match.
> - Choose a folder on your server, and Blit copies each new download once it's finished. If the server runs qBittorrent, Blit reads its records, so a download stuck at 43% is never fetched, and each item shows its status.
> - A two-pane browser with tabs (F5 copies, F6 moves), Rename N Items with presets, and a pixel-terminal display for transfers.
>
> There's no account and no analytics, and your files go only between your servers, your Mac and your NAS. It's $19 once for 3 Macs, with 7 days free on each.
>
> I'd like to hear from anyone who moves big files over long distances: what's missing, and which servers cause it problems.

The story is production work: large files between servers abroad and your own drives. It doesn't
describe what the files are or where they come from. No speed is given for Transmit or ForkLift by
name; the comparison is with "the fastest Mac app I measured",
as the site's "the fastest single-connection Mac client we measured". The site names no competitors.

## Before and on the day

- **Not the same day as Rune** (Rune's Product Hunt day is 9 October 2026). Two launches on one day
  split your attention and the comments. A weekday a week or more later suits Blit.
- **Schedule** the launch for 12:01 AM Pacific: the day's ranking runs midnight to midnight PT.
- **The site's launch-week line,** as Rune's: a plain link to Blit's Product Hunt page, shown from
  midnight Pacific on the day for a week. Add it once the page's address and the date are known.
- **Don't ask for upvotes:** Product Hunt's guidelines say not to. Tell people it's live and ask
  what they think.
- **Answer every comment** through the day; that's most of what a launch is.
- **The site and the store** are live: Blit 1.0, blit.banast.as, Download and Buy on.
- **dev.banast.as** lists Blit as Released (since 1.0, 2026-10-08).
