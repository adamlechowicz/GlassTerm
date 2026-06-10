# GlassTerm — Copilot instructions

GlassTerm is a lightweight macOS terminal emulator that wraps the [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) library (pinned to v1.10.1) inside a transparent macOS Tahoe "Liquid Glass" window with optional color tinting. It is an AppKit/Xcode app, not a Swift Package.

## Build & run

There is no SPM/`swift build` flow — SwiftTerm is added as an Xcode-managed SPM dependency, so build with Xcode or `xcodebuild`.

```bash
# Open in Xcode (target: GlassTerm)
open GlassTerm.xcodeproj

# Headless build from the CLI (verified, uses the shared GlassTerm.xcscheme)
xcodebuild -project GlassTerm.xcodeproj -scheme GlassTerm -destination 'platform=macOS' build
```

- There is **no test target and no automated tests** — do not invent `xcodebuild test` or unit-test commands. Verify changes by building and, when possible, running the app.
- Build-setting facts (authoritative over README badges): `SWIFT_VERSION = 5.0`, `MACOSX_DEPLOYMENT_TARGET = 13.5`. The deployment target is 13.5, but the Liquid Glass features require macOS 26 at runtime and are gated with `@available(macOS 26, *)`.
- The dependency is pinned in `GlassTerm.xcodeproj/.../swiftpm/Package.resolved` (SwiftTerm 1.10.1; `swift-argument-parser` is transitive). Don't hand-edit pinned versions; let Xcode resolve.

## Architecture (the big picture)

Document-based AppKit app (`NSDocument`) driven by `Main.storyboard`. Each window is a document; native tabbing uses `tabbingMode = .automatic`. All Swift source lives in `GlassTerm/`:

- **`ViewController.swift` (~1600 lines, the heart of the app)** holds the terminal lifecycle and all rendering. It also defines several cooperating `NSView`/SwiftUI types in the same file:
  - `DragDropTerminalView` — `LocalProcessTerminalView` subclass; spawns the user's login shell, adds Finder file/folder drag-and-drop (sends shell-escaped paths) and Shift+Enter (CSI u, for apps like Claude Code).
  - `InverseVideoOverlayView` — sibling view drawn behind the terminal to fix reverse-video cursor/cell rendering.
  - `GlassBackgroundView` — SwiftUI view applying `.glassEffect()`, hosted in an `NSHostingView` layered behind the terminal; color tint is applied via blend modes (multiply in light mode, plusLighter in dark mode).
  - `GlassTint` enum + `TitleEditViewController` (per-window title/tint popover).
- **`Document.swift`** — configures each window for glass (transparent titlebar, clear background, rounded corners) and owns the toolbar with the hover-reveal edit button (`NSToolbarItem.Identifier("EditTitleItem")`).
- **`AppDelegate.swift`** — app lifecycle, dock menu, `Cmd+T` tab creation, and SF Symbol icons for menu items. Uses a `GlassTermDocumentController` subclass to hide the tab bar "+" button.
- **`DebugViewController.swift`** — thin wrapper over SwiftTerm's `TerminalDebugView`.

## Project-specific conventions

- **Reconfiguration is notification-driven.** Tint, dark-mode, and system-appearance changes re-theme the terminal and rebuild the glass background via `NotificationCenter`. Notification names: `GlassTintDidChange` (`.glassTintDidChange`) and `AlwaysDarkModeChanged` (`ViewController.alwaysDarkModeChangedNotification`). When adding a preference that affects appearance, follow this post-a-notification / observe-and-reconfigure pattern rather than reaching across view controllers.
- **Tint has two scopes.** Global default is `GlassTint.current` (persisted in `UserDefaults`); each window may override with a non-persistent `windowTint`. Always resolve the effective tint as `windowTint ?? GlassTint.current`.
- **`UserDefaults` keys (use these exact strings):** `"GlassTint"`, `"AlwaysDarkMode"`, `"TerminalFontName"`, `"TerminalFontSize"`, `"LogHostOutput"`.
- **Gate every Liquid Glass / macOS 26 API behind `@available(macOS 26, *)`** so the app still builds against the 13.5 deployment target.
- **ANSI palettes are appearance-adaptive:** `darkModeColors` / `lightModeColors` arrays of `SwiftTerm.Color`; `AlwaysDarkMode` forces the dark palette and a dark appearance on both window and glass.
- **Font changes resize the window, not the text.** Preserve terminal dimensions (cols/rows) by resizing the window instead of reflowing.
- **Terminal padding** is provided by a container view keeping the terminal at origin (0,0): left 18, right 0, bottom 8, with a dynamic titlebar/top inset that accounts for tab-bar visibility.
- **Code style:** `///` doc comments on types/properties and `// MARK: -` section headers are used consistently — match them. Source files retain the original "Miguel de Icaza / SwiftTerm" header comments (this app began from SwiftTerm's MacTerminal example); that's expected, not a mistake.

## Notes

- `CLAUDE.md` is intentionally git-ignored; this file is the committed, shared source of guidance.
- The README's clone instructions reference `TerminalApp/GlassTerm.xcodeproj`, but the project actually lives at the repo root — use `open GlassTerm.xcodeproj`.
