# Histq website

Static site (HTML + CSS + a little vanilla JS, no build step) for https://histq.coprimal.dev.

## Preview

```sh
python3 -m http.server -d website 8080
```

Open http://localhost:8080.

## Structure

- `index.html`: landing page. `docs.html`: documentation. `privacy.html`: privacy statement.
- `tokens.css`: design tokens (OKLCH colors, Geist fonts, spacing). `styles.css`: layout and components.
- `site.js`: theme toggle, docs scroll-spy, header version, screenshot lightbox.
- The app version in each page header (`.version-badge`) is read at runtime from the latest GitHub release of `Coprimal/Histq` by `site.js`; the static `v0.1.0` in each page is only a fallback, so no hand edit is needed on release.
- `logo.png`, `poster.png`: images. `CNAME`: custom domain. `.nojekyll`: disables Jekyll. `llms.txt`: summary for LLM crawlers.

## Deploy

`.github/workflows/pages.yml` uploads this folder to GitHub Pages on every push to `main` that touches `website/`.

One-time setup:

1. Settings > Pages > Source = "GitHub Actions".
2. DNS: add a `CNAME` record `histq` pointing to `Coprimal.github.io`.
3. Settings > Pages: set the custom domain to `histq.coprimal.dev` and enable "Enforce HTTPS".

