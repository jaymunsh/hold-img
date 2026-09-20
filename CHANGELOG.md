# Changelog

All notable changes to HoldImg are documented here. The same history is
available on [GitHub Releases](https://github.com/jaymunsh/hold-img/releases)
and linked from the bottom of the in-app Settings window.

## [1.1.0] — 2026-09-21

### Annotations

- **Move tool (hand icon)** — grab any placed annotation (pen/highlighter
  strokes, arrows, rectangles, mosaics, text) and drag it to a new spot;
  cursor switches to open/closed hand
- **Multi-line text** — `⇧Return` inserts a line break, `Return` commits,
  `Esc` cancels; no auto-wrap, the box grows horizontally
- **Per-annotation font size** — `⌘+`/`⌘-` while the editor is open, or to
  set the default for the next text
- **Highlighter backtracking** — dragging back over a stroke before
  releasing erases the tail instead of stacking darker overlaps;
  highlight is now lighter (alpha 0.35 → 0.25)
- **Detached annotation toolbar** — when the tool strip is wider than the
  panel it floats just above the image instead of covering it; the resize
  size-badge detaches the same way

### History & settings

- New setting: send purged history files to the Trash instead of
  permanently deleting them (off by default)
- Menu bar → "Open History Folder" reveals
  `~/Library/Application Support/HoldImg/History/` in Finder

### Fixes

- Arrow drags no longer leave stray "dust" — the repaint region now
  covers the arrowhead tips, and committing a shape forces a full repaint
- Fixed a crash when selecting the new move tool — toolbar tags ≥ 200 are
  routed as tools, and color selection is bounds-checked
- Hover toolbar no longer flickers between overlapping panels or across
  the gap to the detached strip (topmost-under-cursor check, delayed hide)

### Performance

- Move drags reuse the grabbed shape's cached bounds instead of re-walking
  every stroke point per mouse event

### Docs

- Korean and English manuals regenerated — all screenshots now come from
  the bundled local demo page (`docs/lorem-demo.html`), with separate
  Korean/English overlay captures

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

[1.1.0]: https://github.com/jaymunsh/hold-img/releases/tag/v1.1.0
[1.0.0]: https://github.com/jaymunsh/hold-img/releases/tag/v1.0.0
