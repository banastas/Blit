# site/

Blit's single-page website, meant for **blit.banast.as**. It's static: one `index.html` with inline CSS and JS, the pixel favicon, and the two HUD fonts. There's no build step and nothing loads from other servers.

- **Design:** the transfer HUD's rules. The palette is black and grey (`HUDColor`), with muted red `#b35c5c` only for failures. Type is Silkscreen for labels and VT323 for terminal text. Pixel glyphs, the app icon and marching ants are drawn from the same 1-bit grids the app uses. The live strip and expanded HUD are a simulation with neutral file names, and they respect Reduce Motion.
- **Numbers:** every benchmark comes from the PRD (`README.md`, "Benchmark findings"), measured against a server 148 ms away. Percentages compare Blit's best result with the baseline named next to it.
- **Distribution isn't decided,** so the page has no download link or price. When that's settled, update the Spec sheet's Distribution row, the hero chips and the footer status.
- **Fonts:** Silkscreen and VT323 are under the SIL Open Font License; the license texts are in `fonts/`.

Preview locally:

```bash
python3 -m http.server 8765 --directory site
```

Hosting: serve this folder as the site root (GitHub Pages from `site/`, Cloudflare Pages or Netlify with `site` as the output directory), then point `blit.banast.as` at the host with a CNAME record.
