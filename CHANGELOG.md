# Changelog

All notable changes to HoldImg are documented here. The same history is
available on [GitHub Releases](https://github.com/jaymunsh/hold-img/releases)
and linked from the bottom of the in-app Settings window.

## [1.0.0] — 2026-09-20

First public release.

### Capture

- Region capture `⌃⌥C` at native Retina resolution, with mid-drag aspect
  ratios (`1`–`5`) and fixed pixel-size mode (`6`)
- Window capture `⌃⌥W` with hover highlight
- Recapture last region `⌃⌥R`; paste clipboard image `⌃⌥V`
- Optional loupe (`M`) and one-key HEX color copy (`C`)
- Multi-display capture in parallel with a single `SCShareableContent` fetch

### Floating panels

- Always-on-top borderless panels; drag to move with edge/center snapping
- Scroll to zoom at cursor; drag corners or edges to resize —
  aspect ratio locked by default (`L` or toolbar 🔒 to unlock)
- Rotate (`R`/`⇧R`), flip (`F`), arrow-key nudging, double-click collapse
- Right-click drag exports the image straight into Finder/Slack/Mail
- Always-on-top (`T`), click-through ghost mode (`G`), opacity (`⌥`+scroll)
- Hide/show all `⌃⌥H`; restore recently closed panels `⌃⌥Z` (up to 10)

### Annotations & OCR

- Pen, highlighter, arrow, rectangle, mosaic, and text tools (`P` mode),
  four colors, undo `⌘Z`, baked at native resolution on done (✓)
- OCR text extraction via Vision → clipboard

### History & settings

- Recent capture history with thumbnail cache; reopen from the menu bar
- Launch at login, auto-copy on capture, customizable global shortcuts
- Korean/English UI — Settings → Language (system default supported)
- Version + update-log link at the bottom of Settings → GitHub Releases

### Performance

- Lazy pixel sampler for loupe/color copy
- PNG/TIFF encoding moved off the main thread (history save + auto-copy)
- History thumbnail cache; reused mosaic scratch buffer
- Committed annotations composited into a cached layer instead of
  re-rendering every vector on each frame
- Fixed a notification-observer leak on panel close

[1.0.0]: https://github.com/jaymunsh/hold-img/releases/tag/v1.0.0
