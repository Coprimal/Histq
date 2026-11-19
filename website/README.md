# Histq website

Static site (HTML + CSS + a little vanilla JS, no build step) for https://histq.coprimal.dev.

## Preview

```sh
python3 -m http.server -d website 8080
```

Open http://localhost:8080.

## Structure

- `index.html`: landing page, drawn as a git log (the page's lanes run down the left edge and merge into main at each section). Its own `home/` folder: `tokens.css` (OKLCH colors, Clash Grotesk / Onest / JetBrains Mono, spacing), `base.css`, `styles.css` (the Hallmark stamp is its first lines) and `site.js` (hero ASCII-to-lanes morph, stage demo, profile switch, layout morph, AI deck, screenshot lightbox).
- `shots/`: the product captures the landing page shows (WebP, from the site-shots pipeline).
- `docs.html`: documentation. `privacy.html`: privacy statement. Both use `tokens.css`, `styles.css` and `site.js` at this folder's root (theme toggle, docs scroll-spy, header version).
- The app version in the docs and privacy headers (`.version-badge`) is read at runtime from the latest GitHub release of `Coprimal/Histq` by `site.js`; the static `v0.1.0` in each page is only a fallback, so no hand edit is needed on release.
- `logo.png`, `og.png`: images. `CNAME`: custom domain. `.nojekyll`: disables Jekyll. `llms.txt`: summary for LLM crawlers.
- `index.html` is hand-built: do not re-render it with the thi-create-website `render.py` (that would overwrite it with the old template).

## Deploy

`.github/workflows/pages.yml` uploads this folder to GitHub Pages on every push to `main` that touches `website/`.

One-time setup:

1. Settings > Pages > Source = "GitHub Actions".
2. DNS: add a `CNAME` record `histq` pointing to `Coprimal.github.io`.
3. Settings > Pages: set the custom domain to `histq.coprimal.dev` and enable "Enforce HTTPS".

