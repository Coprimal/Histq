# Histq website

Static site (HTML + CSS + a little vanilla JS, no build step) for https://histq.coprimal.dev.

## Preview

```sh
python3 -m http.server -d website 8080
```

Open http://localhost:8080.

## Structure

- `index.html`: landing page, compact: a hero with the real window (`shots/hero.webp`, from the site-shots `hero` scene) labelled from outside by callouts, a band of numbers, a bento grid of feature tiles (each tagged with a git ref pill in its lane colour; Layouts full width with its pane diagram), a "Tabs that keep your work in order" section (pinned, worktree groups, tab groups, archived, closed groups, tabs down the side, each with a crop of the real app in `shots/tab-*.webp`, then Workspaces) and a short download block. Its own `home/` folder: `tokens.css` (OKLCH colors, Clash Grotesk / Onest / JetBrains Mono, spacing), `base.css`, `styles.css` and `site.js` (callout leaders, tiles that swap their screenshot, profile switch, layout diagram and terminal toggle, screenshot lightbox).
- `shots/`: the product captures the landing page shows (WebP, from the site-shots pipeline).
- `docs.html`: documentation. `privacy.html`: privacy statement. Both share the landing's look: they load `home/styles.css` (tokens, fonts, nav, pills, footer) and copy its header and footer markup (sticky nav, green Download), then add `styles.css` at this folder's root (reading column, contents drawn as a lane of commit nodes) and `site.js` (docs scroll-spy, header version). Light only, like the landing.
- The app version in the docs and privacy headers (`.version-badge`) is read at runtime from the latest GitHub release of `Coprimal/Histq` by `site.js`; the static `v0.1.0` in each page is only a fallback, so no hand edit is needed on release.
- `logo.png`, `og.png`: images. `CNAME`: custom domain. `.nojekyll`: disables Jekyll. `llms.txt`: summary for LLM crawlers.
- `index.html`, `docs.html` and `privacy.html` are hand-built: do not re-render them with the thi-create-website `render.py` (that would overwrite them with the old template).

## Deploy

`.github/workflows/pages.yml` uploads this folder to GitHub Pages on every push to `main` that touches `website/`.

One-time setup:

1. Settings > Pages > Source = "GitHub Actions".
2. DNS: add a `CNAME` record `histq` pointing to `Coprimal.github.io`.
3. Settings > Pages: set the custom domain to `histq.coprimal.dev` and enable "Enforce HTTPS".

