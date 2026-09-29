# X thread draft

Eight posts. Each fits in 280 characters (X counts any link as 23). Media notes are in brackets; attach them, don't post them. Numbers are from one run on 2026-09-29: rerun with `ROUNDS=3` before posting and update them here and in the Show HN draft.

---

**1/**

I move ~30 TB a month from a server in Europe to my NAS.

The Mac apps I used kept getting flaky on new macOS, so I built my own: Blit, a native Mac app that moves big files fast and checks every single byte.

🧵

[Media: 10–15 s screen recording of the HUD during a real download]

---

**2/**

The job: SFTP server 148 ms away → external SSD (where I review) → Synology NAS.

At that volume the transfer engine is the product. Speed first, no silent corruption, and it has to recover from dropped connections on its own.

---

**3/**

Same 2.38 GB file, same server:

• Blit, 3 connections: 75 MB/s
• lftp, 8 connections: 71
• rclone, best setting: 55
• rclone, defaults: 39

Blit gets there with 3 connections instead of 8.

[Media: simple bar chart of the four numbers]

---

**4/**

Why SFTP is slow over long distances:

• OpenSSH's fixed 2 MiB window ≈ 10.7 MB/s per connection at 148 ms
• macOS caps a connection's receive buffer at 4 MB by default
• some servers cap replies at 32 KB, and many clients stumble on that

---

**5/**

Every download is checked against a SHA-256 the server computes itself.

Every copy to the NAS is checked by hashing on the NAS, not by reading it back over the network, where the Mac's cache can answer instead.

Fully verified, it still does 66 MB/s.

---

**6/**

It's also a proper file browser: two panes (F5 copy, F6 move), a tab for each pair of folders, a pixel-terminal HUD, time left in the menu bar, and a queue that survives quits, sleep and dropped Wi-Fi.

[Media: screenshot of two panes with tabs]

---

**7/**

Native Swift and SwiftUI on SwiftNIO SSH. macOS 27, Apple Silicon.

$19 once, 7-day free trial, no account.

https://blit.banast.as

---

**8/**

I built it for my own workflow, so I'd love to hear about yours: where do your big files come from and where do they end up?

---

## Before posting

- [ ] Checkout live and 0.3.0 out (same as the Show HN checklist).
- [ ] Numbers updated from the `ROUNDS=3` runs.
- [ ] Media made: the HUD recording (post 1), the bar chart (post 3), the two-pane screenshot (post 6). Use test folders, not real file names.
- [ ] Pin the thread for launch week; reply to every question in the first few hours.
- [ ] If the Show HN post goes up the same day, post the thread after it and link the HN discussion in a reply, not in the thread itself.
