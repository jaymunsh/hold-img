# HoldImg — Agent Handbook

Technical orientation for agents working in this repo. Read this before
touching code — several conventions here are non-obvious and have caused
real crashes when missed.

## What this is

HoldImg is a GrabIt/Snipaste-style macOS utility: capture a screen region
or window, and it floats above other windows as a borderless always-on-top
panel you can move, zoom, resize, annotate, copy, and export.

- Pure AppKit + a vendored copy of `KeyboardShortcuts` (no other deps).
- `LSUIElement = true` — the app is menu-bar only. No Dock icon or ⌘Tab
  entry (unless the user enables "Show Dock icon" in Settings).
- macOS 15+, Swift 6 tools, target compiles under Swift 5 language mode
  for the vendored package.
- UI strings are **Korean source keys**, translated via `Localizable.strings`.
  Korean and English are the shipped languages.

## Build / run / install

```bash
make build          # → ./Scripts/build-app.sh release → build/HoldImg.app
make debug          # debug config
make run            # build + open
cp -R build/HoldImg.app /Applications/   # install
```

`build-app.sh` runs `swift build`, assembles the `.app` bundle by hand
(binary + `Resources/Info.plist` + rsync of `Resources/`), then signs it.

**Signing matters:** the script prefers a stable dev identity
`"HoldImg Local Dev"` from `~/.local/share/holdimg-dev/holdimg.keychain-db`
(unlocked via `HOLDIMG_KEYCHAIN_PASSWORD` env or
`~/.local/share/holdimg-dev/keychain-password`, never committed). Ad-hoc
signatures are cdhash-based, so **rebuilding under ad-hoc resets the
Screen Recording TCC grant every build** — keep the dev keychain intact.
`CGPreflightScreenCaptureAccess()` is unreliable for self-signed builds;
`ScreenCaptureService.ensurePermission()` double-checks with a real
`SCShareableContent` query before prompting the user.

There is no test target — verification is manual (build, install, exercise
the feature). Version lives in `Resources/Info.plist`
(`CFBundleShortVersionString`, plus `CFBundleVersion` bump).

## Source map

```
Sources/HoldImg/
  HoldImgApp.swift            @main — keeps a strong ref to AppDelegate
  AppDelegate.swift           applyDockPolicy, StatusItemController, HotkeyManager
  Capture/
    CaptureCoordinator.swift  capture session state machine, overlay lifecycle,
                              multi-display stitching, lastCaptureRect
    CaptureOverlayWindow.swift fullscreen per-display overlay window + view
                              (region drag, window pick, loupe, HEX copy, ratio keys)
    ScreenCaptureService.swift ScreenCaptureKit: permission, shareableContent,
                              parallel per-display capture, window capture
  Floating/
    FloatingWindowManager.swift panel registry, hide-all, close-all,
                              undo-close stack (10)
    FloatingPanel.swift       NSPanel subclass — window behavior, hover toolbar,
                              detached pen-bar / size-badge child windows,
                              keyboard shortcuts, rotate/flip transforms
    FloatingImageView.swift   the giant one — rendering, resize/zoom/move/snap,
                              annotations (draw + bake), text editor, file-drag
                              export, context menu, size badge
    PanelToolbar.swift        capsule toolbar view, rebuild-per-mode buttons,
                              tag→action dispatch
  Clipboard/ClipboardService.swift  async PNG/TIFF copy, pasteboard read,
                              NSSavePanel export, NSImage data helpers
  History/CaptureHistoryStore.swift on-disk PNG history, prune/clear, Trash option
  Hotkeys/HotkeyManager.swift global ⌃⌥ shortcuts via vendored KeyboardShortcuts
  Settings/SettingsStore.swift  UserDefaults-backed @Published settings,
                              launch-at-login, dock policy, language
  UI/
    StatusItemController.swift  menu bar item + menu, history submenu w/ thumbnails
    SettingsWindow.swift        SwiftUI Form in an NSWindow (lazy singleton)
    ShortcutsWindow.swift       cheat-sheet window
  Util/
    L10n.swift                tr() — Korean key → .strings lookup
    Geometry.swift            ScreenGeometry (AppKit↔CG coordinate math),
                              PixelSampler (RGBA readback), NSColor.hexString
    OCRService.swift          Vision VNRecognizeTextRequest (ko-KR + en-US)
Vendor/KeyboardShortcuts/     upstream package, vendored — don't edit casually
```

## Runtime model

Everything user-facing is `@MainActor`. Concurrency notes:

- `ScreenCaptureService.captureAllDisplays` fans out per-display
  `SCScreenshotManager.captureImage` in a task group; non-Sendable
  `SCDisplay`/`NSScreen` cross the boundary in an `@unchecked Sendable`
  box — keep it that way, they're read-only system objects.
- PNG/TIFF encoding is deliberately off-main (`CaptureHistoryStore.add`,
  `ClipboardService.copy`) — ~100–300ms on Retina, would hitch the
  panel's appearance animation.
- `FloatingWindowManager` registers a `willCloseNotification` observer
  **per panel** and must remove it on close (`closeObservers`) — a leak
  here retained panels forever; this was a real fixed bug, don't regress it.

### Memory discipline (the app idles at ~11MB — keep it that way)

Retina captures are tens of MB decoded; anything that retains images
must be deliberate:

- **Menu thumbnails** come from `CGImageSourceCreateThumbnailAtIndex`
  (~112px), never `NSImage(contentsOf:)` — that decodes the full PNG and
  was the biggest leak (~85MB for 30 history entries). Cache is capped
  (`countLimit = 60`).
- **`FloatingPanel.sourceURL`** tracks the on-disk file behind the image
  (history PNG, opened file). `setImage` clears it — a rotated/flipped/
  baked panel no longer matches the file.
- **`closedStack` stores URLs, not bitmaps**, when a source file exists;
  `reopenLastClosed` reloads from disk and skips entries whose file was
  pruned. Only file-less panels (pasted images, transformed captures)
  retain their `NSImage`.
- **Hiding all panels drops each composite cache** — rebuilt lazily on
  unhide; hidden panels still keep their source image (that's the
  feature).
- `CaptureOverlayView`'s `PixelSampler` (~60MB RGBA copy) stays lazy —
  don't touch it eagerly.

### Capture session

1. Hotkey/menu → `CaptureCoordinator.shared.startRegion/WindowCapture()`.
2. `ensurePermission` → one `SCShareableContent` fetch (reused for both
   display frames and the window list — don't fetch twice).
3. One `CaptureOverlayWindow` per display over the frozen frame
   (level = screenSaver+1, borderless, `canJoinAllSpaces`). Selection is
   drawn from the frozen frame, dimmed outside.
4. Region select → `stitch(rect:frames:)` crops across displays at the
   **max** covered pixel scale → `FloatingWindowManager.show` → history
   `add` → optional auto-copy.
5. Overlay keys: `1–5` aspect presets mid-drag, `6` fixed-pixel-size input,
   `M` loupe (off by default), `C` copies HEX under cursor, `Esc` cancels.

### Floating panel

- `FloatingPanel` is borderless `nonactivatingPanel`, `hasShadow`,
  `stationary` + `fullScreenAuxiliary` so it survives Spaces/Exposé.
- Custom resize: edge/corner zones in `FloatingImageView` (native border
  resize was removed — it flickered and bypassed aspect lock). Default
  `aspectLocked = true`; `L`/🔒 toggles.
- Snap: `snappedOrigin(for:)` aligns edges/centers to screen + sibling
  panel frames within 8pt.
- `clickThrough` is just `ignoresMouseEvents`; `alwaysOnTop` is
  `.floating` vs `.normal` level.

## Annotation system (FloatingImageView — read this before editing)

### Coordinates

- All annotation geometry is **normalized**: points in [0,1] of the
  view's current size (`x`, `y` measured **from the bottom** — the view is
  NOT flipped; `y = 0` is the bottom edge). Text anchors store the
  baseline-ish top-left with the same convention.
- `normalize`/`denormalize`/`denormalizeRect` convert; `clampNorm` bounds
  committed points.
- Stroke widths and text size are stored as fractions of image height
  (`widthNorm`, `fontNorm`) so annotations survive resize/zoom/rotation.

### Shape model

```swift
enum Shape { freehand([CGPoint]), highlight([CGPoint]),
             arrow(from:to:), rect(CGRect), mosaic(CGRect),
             text(String, CGPoint, fontNorm: CGFloat) }
```

`AnnotationTool: Int = pen, highlighter, arrow, rect, mosaic, text, move`
— **enum order == toolbar tool index** (tag 200+i). Adding a tool means:
enum case, `toolButtons` entry (PanelToolbar), `shapeFrom`, `drawAnnotation`,
`bakeAnnotations`, `shapeBounds`, `hitTestAnnotation`, `translated`,
mouse handlers. Exhaustive switches will fail to compile — that's the
safety net.

### Rendering pipeline

- Committed annotations + base image are **composited into
  `compositeCache`** (an `NSImage` sized to the view). `drawRect` blits
  the cache, then draws `activeStroke`/`activeShape` live on top.
- During a resize/zoom gesture (`isLiveResizing`), the stale composite is
  drawn scaled — the cache rebuilds once when the gesture settles
  (0.2s `resizeSettleTimer`). Don't rebuild per frame; that's the point.
- `invalidateComposite()` on every annotation commit/undo/clear/move-end.

### Dirty-rect discipline (had real bugs)

- Strokes repaint only the new segment (`appendStroke` computes the
  segment rect + line-width pad).
- `shapeBounds` must cover **everything drawn** — arrowheads extend
  ~5×line-width beyond the endpoints; omitting them left permanent
  residue ("dust") on screen. If a shape's ink exceeds its geometric
  bounds, put the padding in `shapeBounds`, not at call sites.
- Committing a shape in `mouseUp` sets `needsDisplay = true` (full
  repaint) — live-preview previews are erased by the composite rebuild.

### Tool behaviors with edge cases

- **Highlighter**: `widthNorm = 20/height`, alpha `0.25` shared by live
  draw and bake (`highlightAlpha`). Backtracking is supported: if the
  pointer returns within `0.6×linewidth` of an earlier point, the tail is
  truncated (`appendStroke`). ⇧ constrains to horizontal/vertical via
  `strokeAxisLock` (decided once, after 4pt of travel).
- **Move tool** (`movingIndex`): on mouseDown `hitTestAnnotation` picks
  the topmost shape — strokes hit by `pointToSegment` ≤ lw/2+6, arrows
  also test both head segments, other shapes by bounds+6. The original is
  excluded from the composite (`moveExcludedIndex` → rebuild once) while
  a `translated` preview follows the drag; bounds for invalidation reuse
  `moveOriginBounds` + delta (don't re-walk points per event). On mouseUp
  the translated shape commits and the cache rebuilds once.
- **Text**: `AnnotationTextView` (NSTextView subclass) — no auto-wrap
  (`containerSize = greatestFiniteMagnitude`), `Return` commits,
  `⇧Return` newlines, `Esc` cancels, `⌘+`/`⌘-` resize live (callbacks
  `onCommit/onCancel/onResize`). Also handled at panel level when the
  editor is closed (`keyDown` 24/27 under `.command`, pen mode + text
  tool). `sizeTextEditor` fits the frame to `layoutManager.usedRect`.
  While the **text** tool is active, an existing `.text` can be
  drag-repositioned (`draggingTextIndex`) — separate from the move tool.
- **Mosaic**: pixelates a `mosaicScratch` bitmap of the captured source —
  reuse the scratch buffer, don't allocate per draw.

### PanelToolbar tag dispatch (crash once — don't regress)

`buttonTapped` maps tags: 1–9 fixed actions, **100+i = color** (index into
`penColors` — bounds-check!), **200+i = tool**. A tool added beyond the
hardcoded range once fell through to `.color(106)` → index-out-of-range
crash. Keep `tag >= 200 → tool` routing and the `selectPenColor` bounds
guard intact.

### Detached chrome windows

When the toolbar strip or size badge is wider than the panel, it moves
into a **detached borderless child NSPanel** (`penBarWindow` /
`sizeBadgeWindow`) rather than covering the image. Rules:

- `isTopmostUnderCursor` gates hover-toolbars so occluded panels don't
  flash; it must also treat a sibling's detached bars as occluding.
- `hideHoverToolbar` waits 0.25s and tests inflated rects so crossing the
  gap panel↔bar doesn't flicker.
- `frameDidChange` repositions both bars and re-attaches them once the
  panel is wide enough. `bar.level = level` keeps them synced with
  always-on-top.

## Data & persistence

- **History**: `~/Library/Application Support/HoldImg/History/*.png`,
  filename `yyyyMMdd-HHmmss-XXXXXX.png`. `prune()` keeps
  `historyLimit` newest (default 20); `trashOnHistoryPurge` routes
  deletes to the Trash. Thumbnails are cached by path in
  `StatusItemController` (files are write-once).
- **Settings**: `UserDefaults`, Korean-keyed UI strings, all through
  `SettingsStore` (`Key` enum). `language` ∈ system|ko|en; a change posts
  `languageDidChange` so AppKit chrome rebuilds (menu, window titles).
- **Hotkeys**: names + defaults in `HotkeyManager` (⌃⌥C/W/R/V/H/Z).
  Reassignable via `KeyboardShortcuts.Recorder` in Settings.

## Localization

`L10n.tr(key)` — key is the **Korean string**; English lives in
`Resources/en.lproj/Localizable.strings`, Korean is the fallback when no
table entry exists (no `ko.lproj` table needed for display, though
`InfoPlist.strings` exists for both). When adding UI strings: add the
Korean key inline and the English entry to `en.lproj/Localizable.strings`.
Match on `keyCode`, not `characters`, in key handlers — non-Latin input
sources remap characters to jamo.

## Docs & screenshots conventions

- User manuals: `docs/manual.html` (ko), `docs/manual-en.html` (en) —
  served by GitHub Pages from `docs/`.
- Screenshots are **language-split**: `*.png/-en.png`, `*.jpg/-en.jpg`.
  Korean manual uses non-suffixed files, English uses `-en`.
- Capture source is `docs/lorem-demo.html` — the bundled local placeholder
  page. Do not reintroduce third-party website screenshots.
- To shoot English-UI screenshots: `defaults write com.holdimg.app
  language en`, relaunch, capture, restore `system`.

## Release process (as done for v1.0.0/v1.1.0)

1. Bump `CFBundleShortVersionString` + `CFBundleVersion` in Info.plist.
2. Update `CHANGELOG.md`, both READMEs, both manuals.
3. `make build`, verify version, install to /Applications, sanity-test.
4. Commit → push → `git tag vX.Y.Z` → push tag →
   `gh release create vX.Y.Z build/HoldImg.app.zip --title "HoldImg vX.Y.Z"
   --notes-file <notes>` (zip via `ditto -c -k --keepParent`).
   Release notes contain backticks — use `--notes-file`, not a heredoc.
5. App is ad-hoc/dev-signed and not notarized — the release notes must
   keep the `xattr -d com.apple.quarantine` / right-click-Open caveat.

## Standing gotchas checklist

- Never put new UI on a non-main actor.
- Keep TCC-friendly signing (see Build section).
- `panels` array order == z-order; rely on it for topmost checks.
- Annotation normalized `y` grows **upward** from the bottom edge —
  flipped-context math is easy to get wrong; follow existing helpers.
- Every annotation commit path must invalidate the composite AND trigger
  `needsDisplay`.
- KeyDown handlers: match on `keyCode`, filter `modifierFlags` to
  [.shift,.control,.option,.command] before comparing (arrows carry
  `.function`).
