# site/

Blit's single-page website, meant for **blit.banast.as**. It's static: one `index.html` with inline CSS and JS, the pixel favicon, and the two HUD fonts. There's no build step and nothing loads from other servers.

- **Design:** the transfer HUD's rules. The palette is black and grey (`HUDColor`), with muted red `#b35c5c` only for failures. Type is Silkscreen for labels and VT323 for terminal text. Pixel glyphs, the app icon and marching ants are drawn from the same 1-bit grids the app uses. The live strip and expanded HUD are a simulation with neutral file names, and they respect Reduce Motion.
- **Numbers:** every benchmark comes from the PRD (`README.md`, "Benchmark findings"), measured against a server 148 ms away. Percentages compare Blit's best result with the baseline named next to it.
- **Selling:** $19 one-time through Lemon Squeezy (store `banastas.lemonsqueezy.com`, named banast.as, Blit's and Rune's; `blit.lemonsqueezy.com` until 2026-10-08), 7-day trial, 30-day refunds. The product is live (product 1423615, variant 2223583; checkout `https://banastas.lemonsqueezy.com/checkout/buy/44cc9246-4b89-4cc6-87ac-a009cea40b46`; the test-mode product, 1390732, keeps its keys working in debug builds of the app). Both Buy buttons (the hero's and the Price section's) open the checkout over the page: the page draws the overlay itself, as Rune's does (a frame on the embed link, `?embed=1&desc=0`, with a backdrop), and falls back to the plain checkout page if it doesn't load in 15 s; nothing loads from Lemon Squeezy until Buy is clicked. They're inactive for visitors ("Checkout opens soon") until launch: set `LIVE = true` in index.html, which also turns on Download, once a release with licensing on is published. Before then `?checkout=test` on the site turns Buy on to try it; it's the live product, so a purchase there is real.
- **Legal:** `legal.html` has the license terms, privacy policy (it describes what the app actually sends: license checks to api.lemonsqueezy.com, nothing else) and refund policy. Seller: banast.as; contact: me@banast.as. Update its date when it changes.
- **Fonts:** Silkscreen and VT323 are under the SIL Open Font License; the license texts are in `fonts/`.
- **Brand images:** `brand/blit-product-1600x1200.png` (the Lemon Squeezy product image), `brand/blit-card-1200x630.png` (the link preview, `og:image`; `launch/media` keeps a copy) and `brand/blit-github-1280x640.png` (the repository's social preview, set in GitHub › Settings › General) are drawn by `scripts/brand/blit-brand.html`: the icon, name, tagline and subline over the HUD with a simulated download. `scripts/make-brand.sh` renders them with WebKit (`scripts/brand/render.swift`). To change one, edit the page, run the script and commit the PNGs; a new product image also has to be uploaded in the Lemon Squeezy product's Media section.

Preview locally:

```bash
python3 -m http.server 8765 --directory site
```

Hosting: serve this folder as the site root (GitHub Pages from `site/`, Cloudflare Pages or Netlify with `site` as the output directory), then point `blit.banast.as` at the host with a CNAME record.

## Downloads and updates

`scripts/release.sh` with `PUBLISH=1` puts the notarized build here: `downloads/Blit-<version>.zip` (the one Sparkle updates point to) and `downloads/Blit.zip` (the Download buttons), and writes `appcast.xml`, the update feed the app checks daily. Each release is signed with the Sparkle EdDSA key in the release Mac's Keychain; the public key is in `Support/Info.plist`. Only the current release is kept here.
