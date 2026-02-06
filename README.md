<img src="GlassTerm.png" alt="GlassTerm Icon" width="64"/>

# GlassTerm
## A subjectively better-looking replacement for macOS Terminal.app

![macOS](https://img.shields.io/badge/macOS-26.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-MIT-green)

![Screenshot of GlassTerm in Light Mode](screenshot_light.png)

![Screenshot of GlassTerm in Dark Mode](screenshot_dark.png)

GlassTerm is a terminal emulator for macOS that embraces the Liquid Glass UI of macOS Tahoe, built using the excellent [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) library.  I built this mostly for myself, seeking a simple and lightweight but aesthetically pleasing terminal for my setup.  Configuration options are delibrately limited as a result. 

## Features

- Transparent Liquid Glass background
- Optional color tinting (per-window or global)
- Tabbing
- System color schemes for light/dark mode
- Font customization (style, size)
- That's about it (so far)!

## Requirements

- macOS 26.0 (Tahoe) or later

## Installation

Download from [Releases](https://github.com/adamlechowicz/GlassTerm/releases), or build from source:

```bash
git clone https://github.com/adamlechowicz/GlassTerm.git
cd GlassTerm
open TerminalApp/GlassTerm.xcodeproj
```

Then build and run in Xcode.

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| New Window | ⌘+N |
| New Tab | ⌘+T |
| Close | ⌘+W |
| Bigger Font | ⌘++ |
| Smaller Font | ⌘+- |
| Reset Font | ⌘+0 |

## Credits

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza does all the heavy lifting

## License

MIT