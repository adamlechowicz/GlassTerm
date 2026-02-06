<img src="images/GlassTerm.png" alt="GlassTerm Icon" width="64"/> &nbsp; <img src="images/GlassTermDark.png" alt="GlassTerm Icon (Dark Mode)" width="64"/> &nbsp; <img src="images/GlassTermClear.png" alt="GlassTerm Icon (Clear Mode)" width="64"/>

# GlassTerm
## A subjectively better-looking replacement for macOS Terminal.app

![macOS](https://img.shields.io/badge/macOS-26.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-MIT-green)

![Screenshot of GlassTerm in Light Mode](images/screenshot_light.png)

![Screenshot of GlassTerm in Dark Mode](images/screenshot_dark.png)

GlassTerm is a terminal emulator for macOS that embraces the Liquid Glass UI of macOS Tahoe, built using the excellent [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) library.  

I built this mostly for myself, seeking a simple and lightweight but aesthetically pleasing terminal for my setup (*It's something nice to look at when debugging your actual code that isn't working!*) Configuration options are delibrately limited as a result. 

Global options such as font size, style, and default window color scheme are configurable via the menu bar.  Hovering over the title bar reveals an "edit" icon that can be used to set custom titles and window colors on a per-window or per-tab basis (useful for quickly distinguishing between multiple open windows).  New tabs can be created using the (⌘+T) keyboard shortcut.

## Features

- Transparent Liquid Glass background
- Optional color tinting (per-window or global)
- Tabbing
- System color schemes for light/dark mode
- Font customization (style, size)
- That's about it (so far)

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