# winghostty site

This directory is the GitHub Pages payload for `winghostty.com`.

The landing page intentionally follows the original `Winghostty Marketing Site.zip`
runtime shape:

- `index.html` - archive-derived page shell
- `bundle.js` - precompiled browser entrypoint used by the landing page
- `build.md` - notes from the original archive about the bundle workflow
- `components/` - archive JSX references kept for design/source parity
- `assets/` - SVG brand assets carried over from the archive
- `404.html`, `styles.css`, `app.js` - standalone static extras already present in this repo
- `_redirects` - legacy Cloudflare redirect file; not used by GitHub Pages

## Source of truth

Marketing copy in this directory must be checked against:

- [README.md](/C:/Users/amant/Documents/GitHub/winghostty/README.md)
- [docs/status.md](/C:/Users/amant/Documents/GitHub/winghostty/docs/status.md)
- [docs/getting-started.md](/C:/Users/amant/Documents/GitHub/winghostty/docs/getting-started.md)

If those files and the site disagree, tighten the wording until the claim is defensible.

## Guardrails

Run the copy check before shipping site edits:

```powershell
pwsh -File scripts/check-site-copy.ps1
```

The check fails on known bad claims and regressions, including:

- package-manager install commands that are not officially published yet
- DirectX or D3D wording for the shipping Windows renderer
- wrong config-path variants under `%APPDATA%`
- silent-update or signed-release wording
- parity overclaims

React UMD, Google Fonts, and the GitHub Releases version fetch are currently
intentional because the landing page was restored to the archive's original
runtime shape per user direction.

## GitHub Pages

Project settings for v1:

- Publishing source branch: `gh-pages`
- Publishing source path: `/`
- Custom domain: `winghostty.com`

Required DNS shape:

- Apex `A` records for `winghostty.com`:
  - `185.199.108.153`
  - `185.199.109.153`
  - `185.199.110.153`
  - `185.199.111.153`
- Optional apex `AAAA` records for IPv6:
  - `2606:50c0:8000::153`
  - `2606:50c0:8001::153`
  - `2606:50c0:8002::153`
  - `2606:50c0:8003::153`
- `www.winghostty.com` `CNAME` -> `amanthanvi.github.io`

Notes:

- `site/CNAME` and `site/.nojekyll` are included so the exported `gh-pages` branch stays Pages-safe.
- GitHub Pages will redirect `www.winghostty.com` to `winghostty.com` once both domains are configured correctly.
