//
//  ViewController.swift
//  GlassTerm
//
//  Created by Miguel de Icaza on 3/11/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Cocoa
import ObjectiveC.runtime
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// LocalProcessTerminalView subclass that adds:
/// - File/folder drag-and-drop from Finder (types shell-escaped paths)
/// - Shift+Enter support (sends CSI u sequence for apps like Claude Code)
class DragDropTerminalView: LocalProcessTerminalView {
    private var pendingFilteredInput: [UInt8] = []

    private static let installDrawRectSwizzle: Void = {
        let originalSelector = #selector(NSView.draw(_:))
        let swizzledSelector = #selector(glassTerm_draw(_:))

        guard
            let originalMethod = class_getInstanceMethod(DragDropTerminalView.self, originalSelector),
            let swizzledMethod = class_getInstanceMethod(DragDropTerminalView.self, swizzledSelector)
        else { return }

        let didAddMethod = class_addMethod(
            DragDropTerminalView.self,
            originalSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod {
            class_replaceMethod(
                DragDropTerminalView.self,
                swizzledSelector,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }()

    override init(frame: CGRect) {
        _ = Self.installDrawRectSwizzle
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        _ = Self.installDrawRectSwizzle
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Drag and Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }

        let paths = urls.map { shellEscapedPath($0.path) }
        let text = paths.joined(separator: " ")
        send(txt: text)
        return true
    }

    /// Shell-escapes a file path by wrapping it in single quotes,
    /// escaping any existing single quotes within the path.
    private func shellEscapedPath(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Transparent backing store clear

    /// Clear the dirty region before SwiftTerm draws into the layer-backed view.
    ///
    /// Problem: SwiftTerm's drawTerminalContents fills cell backgrounds with the resolved
    /// NSColor.  For cells whose background resolves to transparent (nativeBackgroundColor
    /// = .clear, or .clear.inverseColor() for default-inverted cells) the fill is a no-op
    /// in source-over compositing — old opaque pixels from previous frames accumulate in
    /// the CALayer backing store and show through as ghost text behind new content.
    ///
    /// SwiftTerm declares `draw(_:)` as `public`, not `open`, so a normal Swift override is
    /// unavailable. We install a subclass-local ObjC swizzle for `draw(_:)` and also keep the
    /// CALayer delegate hook below, because AppKit can route drawing through either path on macOS.
    /// Both paths clear only the dirty region, preserving partial redraw performance.
    ///
    /// Note: `draw(_ layer:in:)` is NOT `override` because NSView's CALayerDelegate conformance
    /// is ObjC-only. ObjC dynamic dispatch will find our implementation and call it in place of
    /// NSView's default. We replicate AppKit's setup (push a NSGraphicsContext wrapping ctx) so
    /// SwiftTerm's draw(_:) sees a valid NSGraphicsContext.current.
    func draw(_ layer: CALayer, in ctx: CGContext) {
        ctx.clear(ctx.boundingBoxOfClipPath)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: isFlipped)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        draw(ctx.boundingBoxOfClipPath)
        NSGraphicsContext.restoreGraphicsState()
    }

    @objc private func glassTerm_draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)

        typealias DrawIMP = @convention(c) (AnyObject, Selector, NSRect) -> Void
        guard let originalMethod = class_getInstanceMethod(DragDropTerminalView.self, #selector(glassTerm_draw(_:))) else {
            return
        }

        let originalDraw = unsafeBitCast(method_getImplementation(originalMethod), to: DrawIMP.self)
        originalDraw(self, #selector(glassTerm_draw(_:)), dirtyRect)
    }

    override open func dataReceived(slice: ArraySlice<UInt8>) {
        pendingFilteredInput.append(contentsOf: slice)

        var output: [UInt8] = []
        var index = 0

        while index < pendingFilteredInput.count {
            let remaining = pendingFilteredInput.count - index

            if pendingFilteredInput[index] == 0x1b {
                if remaining == 1 {
                    break
                }

                if pendingFilteredInput[index + 1] == 0x5b {
                    if remaining < 3 {
                        break
                    }

                    var end = index + 2
                    while end < pendingFilteredInput.count, !(0x40...0x7e).contains(pendingFilteredInput[end]) {
                        end += 1
                    }

                    if end == pendingFilteredInput.count {
                        break
                    }

                    let sequence = Array(pendingFilteredInput[index...end])

                    // Claude Code enables CSI-u keyboard reporting with sequences like ESC [ > 1 u
                    // and ESC [ < u. SwiftTerm currently routes any CSI ... u to "restore cursor",
                    // even when the sequence uses a private prefix, which snaps the cursor back to
                    // the saved default position and causes subsequent redraws to overwrite earlier
                    // shell output. Drop unsupported private CSI ... u sequences until SwiftTerm
                    // handles these extensions correctly.
                    if sequence.count >= 4, (0x3c...0x3f).contains(sequence[2]), sequence.last == 0x75 {
                        index = end + 1
                        continue
                    }

                    output.append(contentsOf: sequence)
                    index = end + 1
                    continue
                }
            }

            output.append(pendingFilteredInput[index])
            index += 1
        }

        if index > 0 {
            pendingFilteredInput.removeFirst(index)
        }

        if !output.isEmpty {
            feed(byteArray: output[...])
        }
    }

    // MARK: - Reverse Video Cursor Fix

    /// Sibling view placed behind the terminal that draws opaque fills for inverse-video cells.
    /// See InverseVideoOverlayView for the full explanation.
    weak var inverseVideoOverlay: InverseVideoOverlayView?

    /// Propagate invalidation to the overlay so it repaints in sync with the terminal.
    /// setNeedsDisplay(_:) is `open` in SwiftTerm so this override is legal.
    ///
    /// We always mark the *entire* terminal as needing display, not just SwiftTerm's row range.
    /// With a transparent background on macOS Tahoe, partial invalidation still leaves old cells
    /// in the layer backing store when a TUI app switches buffers or redraws shorter content.
    /// A full terminal redraw is the reliable way to ensure erased cells actually disappear.
    ///
    /// We always mark the *entire* overlay as needing display, not just the dirty rect.
    /// Reason: the overlay draws opaque fills for inverse-video cells. When a cell leaves
    /// inverse state, SwiftTerm only invalidates the affected rect. If the overlay only
    /// redraws that rect, old fills in nearby rows may persist across the clear(dirtyRect)
    /// call. A full overlay redraw is cheap (one pass over visible cells) and guarantees
    /// no stale fills survive.
    override open func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(bounds)
        inverseVideoOverlay?.needsDisplay = true
    }
}

// MARK: - Inverse Video Overlay

/// A transparent view placed behind the terminal that paints opaque fills for cells using
/// reverse video (SGR 7) whose foreground was the default color.
///
/// Background: `nativeBackgroundColor = .clear` is required to let the Liquid Glass show through,
/// but SwiftTerm's `inverseColor()` preserves alpha — so `.clear.inverseColor()` returns
/// transparent white. Any SGR 7 cell whose fg was `.defaultColor` ends up with an invisible
/// background fill, making cursors drawn by TUI apps (Claude Code, vim, ncurses menus…)
/// disappear entirely.
///
/// This view is inserted into the terminal container BEFORE the terminal view, so it sits behind
/// it in z-order. The terminal's transparent cell areas let the overlay's fills show through.
/// `DragDropTerminalView.setNeedsDisplay(_:)` propagates invalidation here so both repaint
/// in lock-step.
class InverseVideoOverlayView: NSView {
    weak var terminalView: DragDropTerminalView?

    override func draw(_ dirtyRect: NSRect) {
        // Clear dirty rect first: stale white fills from previously-inverse cells would otherwise
        // persist in the layer backing store after those cells leave inverse-video state.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)

        guard let tv = terminalView else { return }
        let term = tv.getTerminal()
        let rows = term.rows
        let cols = term.cols

        // Mirror SwiftTerm's computeFontDimensions() using the public font property
        let ctFont = tv.font as CTFont
        let cellW = tv.font.advancement(forGlyph: tv.font.glyph(withName: "W")).width
        let cellH = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))

        // After inversion, the cell background color = the original foreground color.
        // For .defaultColor fg this resolves to nativeForegroundColor (white/black).
        tv.nativeForegroundColor.setFill()

        for screenRow in 0..<rows {
            guard let line = term.getLine(row: screenRow) else { continue }
            let cellY = frame.height - cellH * CGFloat(screenRow + 1)

            guard dirtyRect.maxY >= cellY && dirtyRect.minY <= cellY + cellH else { continue }

            for col in 0..<cols {
                let cell = line[col]
                // Only patch cells where inversion maps .defaultColor fg → transparent fill.
                // Cells using explicit ANSI colors are already opaque; no fix needed there.
                guard cell.attribute.style.contains(.inverse),
                      cell.attribute.fg == .defaultColor else { continue }

                // Use the cell's column width (2 for wide/CJK chars, 1 for normal, 0 for
                // continuation placeholders which should not be filled independently).
                let colSpan = Int(cell.width)
                guard colSpan > 0 else { continue }
                NSBezierPath.fill(NSRect(x: cellW * CGFloat(col), y: cellY, width: cellW * CGFloat(colSpan), height: cellH))
            }
        }
    }
}

class ViewController: NSViewController, LocalProcessTerminalViewDelegate, NSUserInterfaceValidations {
    @IBOutlet var loggingMenuItem: NSMenuItem?

    var changingSize = false
    var logging: Bool = false
    var zoomGesture: NSMagnificationGestureRecognizer?
    var postedTitle: String = ""
    var postedDirectory: String? = nil

    /// Custom user-set title that overrides terminal-set titles (non-persistent)
    var customTitle: String? = nil

    /// Per-window glass tint override (non-persistent, nil means use global default)
    var windowTint: GlassTint? = nil

    /// UserDefaults key for "Always Dark Mode" preference
    private static let alwaysDarkModeKey = "AlwaysDarkMode"

    /// Notification posted when Always Dark Mode preference changes
    static let alwaysDarkModeChangedNotification = Notification.Name("AlwaysDarkModeChanged")

    /// Whether "Always Dark Mode" is enabled (persisted in UserDefaults)
    static var alwaysDarkMode: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysDarkModeKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: alwaysDarkModeKey)
            NotificationCenter.default.post(name: alwaysDarkModeChangedNotification, object: nil)
        }
    }

    /// The height of the titlebar area to use as top padding
    var titlebarHeight: CGFloat = 0

    /// The hosting view for the SwiftUI Liquid Glass background
    var glassHostingView: NSView?

    /// Container view for the terminal (provides padding while keeping terminal at origin 0,0)
    var terminalContainer: NSView?
    
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        if changingSize {
            return
        }
        guard let window = view.window else {
            return
        }
        // Don't adjust window frame while user is actively resizing
        if window.inLiveResize {
            return
        }
        changingSize = true
        let terminalOptimalSize = terminal.getOptimalFrameSize()
        let windowFrame = window.frame

        // Account for titlebar height and padding when calculating new window frame
        let totalWidth = terminalOptimalSize.width + terminalPaddingLeft + terminalPaddingRight
        let newHeight = terminalOptimalSize.height + titlebarHeight + terminalPaddingBottom

        // Keep the window's top edge anchored (macOS uses bottom-left origin)
        let newY = windowFrame.maxY - newHeight
        let newFrame = CGRect(x: windowFrame.minX, y: newY, width: totalWidth, height: newHeight)

        window.setFrame(newFrame, display: true, animate: true)
        changingSize = false
    }
    
    func updateWindowTitle ()
    {
        // If user has set a custom title, always use that
        if let custom = customTitle {
            view.window?.title = custom
            return
        }

        var newTitle: String
        if let dir = postedDirectory {
            if let uri = URL(string: dir) {
                if postedTitle == "" {
                    newTitle = uri.path
                } else {
                    newTitle = "\(postedTitle) - \(uri.path)"
                }
            } else {
                newTitle = postedTitle
            }
        } else {
            newTitle = postedTitle
        }
        view.window?.title = newTitle
    }
    
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        postedTitle = title
        updateWindowTitle ()
    }
    
    func hostCurrentDirectoryUpdate (source: TerminalView, directory: String?) {
        self.postedDirectory = directory
        updateWindowTitle()
    }
    
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        view.window?.close()
    }
    var terminal: DragDropTerminalView!

    static weak var lastTerminal: LocalProcessTerminalView!
    
    func getBufferAsData () -> Data
    {
        return terminal.getTerminal().getBufferAsData ()
    }
    
    func updateLogging ()
    {
//        let path = logging ? "/Users/miguel/Downloads/Logs" : nil
//        terminal.setHostLogging (directory: path)
        NSUserDefaultsController.shared.defaults.set (logging, forKey: "LogHostOutput")
    }
    
    // Returns the shell associated with the current account
    func getShell () -> String
    {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else {
            return "/bin/bash"
        }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer {
            buffer.deallocate()
        }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = UnsafeMutablePointer<passwd>.allocate(capacity: 1)
        
        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 {
            return "/bin/bash"
        }
        return String (cString: pwd.pw_shell)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Make the main view layer-backed and transparent
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        // Set up the Liquid Glass background effect (requires macOS 26)
        if #available(macOS 26, *) {
            setupGlassBackground()
        }

        // Create container view for terminal (provides padding while keeping terminal at origin 0,0)
        let container = NSView(frame: containerFrameWithPadding())
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.autoresizingMask = [.width, .height]
        view.addSubview(container)
        terminalContainer = container

        // Create terminal filling the container (at origin 0,0)
        terminal = DragDropTerminalView(frame: container.bounds)
        terminal.autoresizingMask = [.width, .height]
        terminal.caretColor = .systemGreen
        terminal.getTerminal().setCursorStyle(.steadyBlock)

        // GlassTerm uses a transparent background (nativeBackgroundColor = .clear).
        // On macOS 11+, SwiftTerm enables disableFullRedrawOnAnyChanges to suppress
        // whole-surface redraws, but this causes stale pixels to linger: "erased" cells
        // draw transparent fills that don't overwrite the old pixel data in the CALayer
        // backing store.  Turning the flag off restores the full-surface redraw behavior,
        // ensuring the system clears the backing store before each draw cycle.
        terminal.disableFullRedrawOnAnyChanges = false

        // Configure terminal for transparent background with adaptive colors
        configureTerminalAppearance()

        zoomGesture = NSMagnificationGestureRecognizer(target: self, action: #selector(zoomGestureHandler))
        terminal.addGestureRecognizer(zoomGesture!)
        ViewController.lastTerminal = terminal
        terminal.processDelegate = self

        let shell = getShell()
        let shellIdiom = "-" + NSString(string: shell).lastPathComponent

        FileManager.default.changeCurrentDirectoryPath (FileManager.default.homeDirectoryForCurrentUser.path)
        terminal.startProcess (executable: shell, execName: shellIdiom)

        // Add overlay BEFORE terminal so it sits behind it in z-order.
        // The overlay draws opaque fills for inverse-video cells; the terminal's
        // transparent cell backgrounds let those fills show through.
        let overlay = InverseVideoOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        terminal.inverseVideoOverlay = overlay
        overlay.terminalView = terminal

        container.addSubview(terminal)

        // Monitor Shift+Enter to send CSI u encoding (\e[13;2u)
        // so apps like Claude Code can distinguish it from plain Enter
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  event.keyCode == 36,
                  event.modifierFlags.contains(.shift),
                  event.window == self.view.window else {
                return event
            }
            self.terminal.send(txt: "\u{1b}[13;2u")
            return nil // consume the event
        }

        // Configure auto-hiding scroller
        configureScroller()

        // Load saved font preference
        loadSavedFont()

        logging = NSUserDefaultsController.shared.defaults.bool(forKey: "LogHostOutput")
        updateLogging ()

        // Register for appearance change notifications
        setupAppearanceObserver()

        #if DEBUG_MOUSE_FOCUS
        var t = NSTextField(frame: NSRect (x: 0, y: 100, width: 200, height: 30))
        t.backgroundColor = NSColor.white
        t.stringValue = "Hello - here to test focus switching"

        view.addSubview(t)
        #endif
    }

    /// Sets up the SwiftUI Liquid Glass background using .glassEffect()
    @available(macOS 26, *)
    private func setupGlassBackground() {
        updateGlassBackground()

        // Observe tint changes to update the glass background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(glassTintDidChange),
            name: .glassTintDidChange,
            object: nil
        )

        // Observe "Always Dark Mode" changes to update terminal appearance
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(alwaysDarkModeDidChange),
            name: ViewController.alwaysDarkModeChangedNotification,
            object: nil
        )
    }

    /// Updates the glass background with the current tint color
    @available(macOS 26, *)
    private func updateGlassBackground() {
        // Remove existing glass view if present
        glassHostingView?.removeFromSuperview()

        // Use per-window tint if set, otherwise fall back to global default
        let effectiveTint = windowTint ?? GlassTint.current
        let tintColor = effectiveTint.swiftUIColor
        let glassView = GlassBackgroundView(tintColor: tintColor, forceDarkMode: Self.alwaysDarkMode)
        let hostingView = NSHostingView(rootView: glassView)
        hostingView.frame = view.bounds
        hostingView.autoresizingMask = [.width, .height]

        // Force dark appearance on the hosting view if "Always Dark Mode" is enabled
        // This ensures the glass effect renders with dark mode styling
        if Self.alwaysDarkMode {
            hostingView.appearance = NSAppearance(named: .darkAqua)
        }

        view.addSubview(hostingView, positioned: .below, relativeTo: nil)
        glassHostingView = hostingView
    }

    @objc private func glassTintDidChange() {
        if #available(macOS 26, *) {
            updateGlassBackground()
        }
    }

    @objc private func alwaysDarkModeDidChange() {
        configureTerminalAppearance()
        updateWindowAppearance()
        if #available(macOS 26, *) {
            updateGlassBackground()
        }
    }

    /// Updates the window appearance based on "Always Dark Mode" setting
    private func updateWindowAppearance() {
        guard let window = view.window else { return }
        if Self.alwaysDarkMode {
            window.appearance = NSAppearance(named: .darkAqua)
        } else {
            // Reset to nil to follow system appearance
            window.appearance = nil
        }
    }

    // Terminal content padding
    private let terminalPaddingLeft: CGFloat = 18
    private let terminalPaddingRight: CGFloat = 0
    private let terminalPaddingBottom: CGFloat = 8

    /// Returns the frame for the terminal container, accounting for titlebar inset and padding.
    /// The container provides padding while keeping the terminal at origin (0,0) within it.
    private func containerFrameWithPadding() -> CGRect {
        // Calculate titlebar height if we have a window
        if let window = view.window {
            // Get the content layout rect which excludes the titlebar
            let contentLayoutRect = window.contentLayoutRect
            let windowContentRect = window.contentView?.bounds ?? view.bounds

            // The difference between the full content view and the layout rect
            // gives us the titlebar height
            titlebarHeight = windowContentRect.height - contentLayoutRect.height

            // Add a small padding for visual breathing room
            let padding: CGFloat = 4
            titlebarHeight += padding

            // Add extra padding when tab bar is visible (more than 1 tab)
            if let tabbedWindows = window.tabbedWindows, tabbedWindows.count > 1 {
                // Tab bar adds approximately 7 points of height
                let tabBarPadding: CGFloat = 7
                titlebarHeight += tabBarPadding
            }
        } else {
            // Default titlebar height estimate (standard titlebar + padding)
            titlebarHeight = 32
        }

        // Container frame: inset from edges, reduced height for titlebar
        return CGRect(
            x: terminalPaddingLeft,
            y: terminalPaddingBottom,
            width: view.bounds.width - terminalPaddingLeft - terminalPaddingRight,
            height: view.bounds.height - titlebarHeight - terminalPaddingBottom
        )
    }

    /// Sets up an observer for system appearance changes (light/dark mode)
    private func setupAppearanceObserver() {
        // Observe the view's effective appearance via KVO
        view.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" {
            configureTerminalAppearance()
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    /// Configures the terminal colors based on the current system appearance.
    /// Light mode: black text on clear background with darker ANSI colors
    /// Dark mode: white text on clear background with standard ANSI colors
    private func configureTerminalAppearance() {
        guard terminal != nil else { return }

        let isDarkMode = Self.alwaysDarkMode || view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Set completely transparent background so the Liquid Glass shows through
        terminal.nativeBackgroundColor = NSColor.clear
        terminal.layer?.backgroundColor = NSColor.clear.cgColor

        if isDarkMode {
            terminal.nativeForegroundColor = NSColor.white
            terminal.caretColor = NSColor.white
            terminal.caretTextColor = NSColor.black
            terminal.installColors(Self.darkModeColors)
        } else {
            terminal.nativeForegroundColor = NSColor.black
            terminal.caretColor = NSColor.black
            terminal.caretTextColor = NSColor.white
            terminal.installColors(Self.lightModeColors)
        }

        terminal.needsDisplay = true
    }

    /// Helper to create SwiftTerm.Color from 8-bit RGB values
    private static func color8(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        // Convert 8-bit (0-255) to 16-bit (0-65535) by multiplying by 257
        return SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    /// Standard ANSI colors for dark mode (good contrast on dark backgrounds)
    private static let darkModeColors: [SwiftTerm.Color] = [
        color8(0, 0, 0),         // 0: Black
        color8(194, 54, 33),     // 1: Red
        color8(37, 188, 36),     // 2: Green
        color8(173, 173, 39),    // 3: Yellow
        color8(73, 46, 225),     // 4: Blue
        color8(211, 56, 211),    // 5: Magenta
        color8(51, 187, 200),    // 6: Cyan
        color8(203, 204, 205),   // 7: White
        color8(129, 131, 131),   // 8: Bright Black
        color8(252, 57, 31),     // 9: Bright Red
        color8(49, 231, 34),     // 10: Bright Green
        color8(234, 236, 35),    // 11: Bright Yellow
        color8(88, 51, 255),     // 12: Bright Blue
        color8(249, 53, 248),    // 13: Bright Magenta
        color8(20, 240, 240),    // 14: Bright Cyan
        color8(233, 235, 235),   // 15: Bright White
    ]

    /// Darker ANSI colors for light mode (better contrast on light/glass backgrounds)
    private static let lightModeColors: [SwiftTerm.Color] = [
        color8(0, 0, 0),         // 0: Black
        color8(153, 0, 0),       // 1: Red (darker)
        color8(0, 130, 0),       // 2: Green (darker)
        color8(136, 120, 0),     // 3: Yellow (much darker/olive)
        color8(0, 0, 180),       // 4: Blue (darker)
        color8(153, 0, 153),     // 5: Magenta (darker)
        color8(0, 140, 140),     // 6: Cyan (darker)
        color8(85, 85, 85),      // 7: White (dark gray)
        color8(102, 102, 102),   // 8: Bright Black (gray)
        color8(200, 0, 0),       // 9: Bright Red
        color8(0, 170, 0),       // 10: Bright Green
        color8(160, 140, 0),     // 11: Bright Yellow (olive/gold)
        color8(0, 0, 220),       // 12: Bright Blue
        color8(200, 0, 200),     // 13: Bright Magenta
        color8(0, 170, 170),     // 14: Bright Cyan (darker)
        color8(60, 60, 60),      // 15: Bright White (dark gray)
    ]

    // MARK: - Scroller Configuration

    private weak var terminalScroller: NSScroller?
    private var scrollerHideTimer: Timer?
    private var isScrollerVisible = false
    private var keyEventMonitor: Any?
    private var scrollEventMonitor: Any?
    private var isResizing = false

    // Custom scroll indicator properties
    private var scrollIndicator: NSView?
    private let scrollIndicatorWidth: CGFloat = 6
    private let scrollIndicatorInset: CGFloat = 2

    /// Finds and configures the terminal's scroller for auto-hide behavior
    private func configureScroller() {
        // Find the NSScroller in the terminal's subviews
        guard let scroller = findScroller(in: terminal) else { return }
        terminalScroller = scroller

        // Hide the native scroller - we use our own custom indicator
        scroller.isHidden = true

        // Create our custom minimal scroll indicator for a cleaner look
        setupCustomScrollIndicator()

        // Monitor scroll wheel events to show/hide our custom indicator
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Only respond to scroll events on our terminal
            if let self = self,
               let terminal = self.terminal,
               !self.isResizing,
               event.window == self.view.window {
                // Check if the event is within the terminal view
                let locationInTerminal = terminal.convert(event.locationInWindow, from: nil)
                if terminal.bounds.contains(locationInTerminal) {
                    self.showScroller()
                }
            }
            return event
        }

        // Observe window resize to hide scroller during resize
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillStartLiveResize),
            name: NSWindow.willStartLiveResizeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEndLiveResize),
            name: NSWindow.didEndLiveResizeNotification,
            object: nil
        )
    }

    private func setupCustomScrollIndicator() {
        let indicator = NSView()
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.6).cgColor
        indicator.layer?.cornerRadius = scrollIndicatorWidth / 2
        indicator.alphaValue = 0
        // Add as sibling to terminal container to avoid interfering with mouse tracking
        // Position above terminal in z-order
        view.addSubview(indicator, positioned: .above, relativeTo: terminalContainer)
        scrollIndicator = indicator
        updateScrollIndicatorFrame()
    }

    private func updateScrollIndicatorFrame() {
        guard let indicator = scrollIndicator,
              let scroller = terminalScroller,
              let container = terminalContainer else { return }

        let scrollPosition = scroller.doubleValue
        let knobProportion = scroller.knobProportion

        // Calculate position relative to container frame (which holds the terminal)
        let containerFrame = container.frame
        let trackHeight = containerFrame.height - (scrollIndicatorInset * 2)
        let knobHeight = max(trackHeight * CGFloat(knobProportion), 30) // Minimum height of 30
        let availableTravel = trackHeight - knobHeight
        let knobY = containerFrame.origin.y + scrollIndicatorInset + availableTravel * (1 - CGFloat(scrollPosition))

        indicator.frame = NSRect(
            x: containerFrame.maxX - scrollIndicatorWidth - scrollIndicatorInset,
            y: knobY,
            width: scrollIndicatorWidth,
            height: knobHeight
        )
    }

    /// Recursively finds an NSScroller in a view hierarchy
    private func findScroller(in view: NSView) -> NSScroller? {
        for subview in view.subviews {
            if let scroller = subview as? NSScroller {
                return scroller
            }
            if let found = findScroller(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Shows the scroller with animation
    private func showScroller() {
        guard let indicator = scrollIndicator, !isResizing else { return }

        // Cancel any pending hide timer
        scrollerHideTimer?.invalidate()

        // Update position before showing
        updateScrollIndicatorFrame()

        // Show the indicator if not already visible
        if !isScrollerVisible {
            isScrollerVisible = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                indicator.animator().alphaValue = 1
            }
        }

        // Schedule hide after 1.5 seconds of inactivity
        scrollerHideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.hideScroller()
        }
    }

    /// Hides the scroller with animation
    private func hideScroller() {
        guard let indicator = scrollIndicator, isScrollerVisible else { return }

        isScrollerVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            indicator.animator().alphaValue = 0
        }
    }

    private func hideScrollerImmediately() {
        scrollerHideTimer?.invalidate()
        scrollIndicator?.alphaValue = 0
        isScrollerVisible = false
    }

    @objc private func windowWillStartLiveResize() {
        guard view.window != nil else { return }
        isResizing = true
        hideScrollerImmediately()
    }

    @objc private func windowDidEndLiveResize() {
        guard view.window != nil else { return }
        isResizing = false
        updateScrollIndicatorFrame()
    }

    // MARK: - Title Edit Button (Hover-based)

    private var titleTrackingArea: NSTrackingArea?
    private var isTitleEditButtonVisible = false

    private func setupTitleEditButton() {
        guard view.window != nil else { return }

        // Setup tracking for mouse hover on the titlebar area
        setupTitlebarTracking()
    }

    /// Finds the toolbar edit button
    private func findToolbarEditButton() -> NSButton? {
        guard let window = view.window,
              let toolbar = window.toolbar else { return nil }

        for item in toolbar.items {
            if item.itemIdentifier == .editTitle {
                return item.view as? NSButton
            }
        }
        return nil
    }

    /// Updates the visibility of the toolbar edit button
    private func updateToolbarButtonVisibility() {
        guard let button = findToolbarEditButton() else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.alphaValue = isTitleEditButtonVisible ? 1 : 0
        CATransaction.commit()
    }

    private func setupTitlebarTracking() {
        guard view.window != nil else { return }

        let trackingArea = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["titleTracking": true]
        )
        view.addTrackingArea(trackingArea)
        titleTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        if let userInfo = event.trackingArea?.userInfo as? [String: Any],
           userInfo["titleTracking"] as? Bool == true {
            updateTitleEditButtonVisibility(for: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let userInfo = event.trackingArea?.userInfo as? [String: Any],
           userInfo["titleTracking"] as? Bool == true {
            hideTitleEditButton()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if let userInfo = event.trackingArea?.userInfo as? [String: Any],
           userInfo["titleTracking"] as? Bool == true {
            updateTitleEditButtonVisibility(for: event)
        }
    }

    private func updateTitleEditButtonVisibility(for event: NSEvent) {
        guard let window = view.window else { return }

        let locationInWindow = event.locationInWindow
        let windowHeight = window.frame.height
        let contentHeight = window.contentLayoutRect.height

        // Check if mouse is in the titlebar area
        let titlebarHeight = windowHeight - contentHeight
        let isInTitlebar = locationInWindow.y > (windowHeight - titlebarHeight - 10)

        if isInTitlebar {
            showTitleEditButton()
        } else {
            hideTitleEditButton()
        }
    }

    private func showTitleEditButton() {
        guard let button = findToolbarEditButton(), !isTitleEditButtonVisible else { return }
        isTitleEditButtonVisible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            button.animator().alphaValue = 1
        }
    }

    private func hideTitleEditButton() {
        guard let button = findToolbarEditButton(), isTitleEditButtonVisible else { return }
        isTitleEditButtonVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            button.animator().alphaValue = 0
        }
    }

    /// Called from toolbar button via responder chain
    @objc func editTitleFromToolbar(_ sender: Any?) {
        guard let window = view.window else { return }

        let popover = NSPopover()
        popover.behavior = .transient

        let editVC = TitleEditViewController()
        editVC.currentTitle = customTitle ?? window.title
        editVC.currentTint = windowTint ?? GlassTint.current
        editVC.onTitleChanged = { [weak self] newTitle in
            self?.customTitle = newTitle.isEmpty ? nil : newTitle
            self?.updateWindowTitle()
        }
        editVC.onTintChanged = { [weak self] newTint in
            self?.windowTint = newTint
            if #available(macOS 26, *) {
                self?.updateGlassBackground()
            }
        }

        popover.contentViewController = editVC

        // Show relative to the toolbar button
        if let button = findToolbarEditButton() {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        // Update container frame for proper titlebar inset
        terminalContainer?.frame = containerFrameWithPadding()
        terminal.frame = terminalContainer?.bounds ?? view.bounds

        // Reapply appearance-based settings when the view appears
        configureTerminalAppearance()
        updateWindowAppearance()

        // Setup title edit button
        setupTitleEditButton()

        // Observe tab group changes to update layout when tab bar appears/disappears
        setupTabObserver()
    }

    /// Tracks the last known tab count to detect changes
    private var lastTabCount: Int = 1

    /// Sets up observation for tab bar visibility changes
    private func setupTabObserver() {
        guard let window = view.window else { return }

        // Observe when this window becomes key (which includes tab switches)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )

        // Also observe frame changes which can indicate tab bar appearing
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification,
            object: window
        )

        // Observe when ANY window closes (to detect tab closures in our tab group)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(someWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil  // Observe all windows
        )
    }

    @objc private func someWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              let myWindow = view.window,
              closingWindow != myWindow else {
            return
        }

        // Check if the closing window is in our tab group
        if let tabbedWindows = myWindow.tabbedWindows, tabbedWindows.contains(closingWindow) {
            // A tab in our group is closing - update layout after a short delay
            // to allow the tab bar to update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateLayoutForTabBar()
            }
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        // When window becomes key (including tab switches), update layout
        // Use a slight delay to ensure tab bar is fully rendered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.updateLayoutForTabBar()
        }
    }

    @objc private func windowDidResize(_ notification: Notification) {
        updateLayoutForTabBar()
    }

    /// Updates the layout to account for tab bar visibility
    private func updateLayoutForTabBar() {
        guard let window = view.window else { return }

        // Check current tab count
        let currentTabCount = window.tabbedWindows?.count ?? 1

        // If tab count changed, force layout update
        if currentTabCount != lastTabCount {
            lastTabCount = currentTabCount
            changingSize = true
            terminalContainer?.frame = containerFrameWithPadding()
            terminal.frame = terminalContainer?.bounds ?? view.bounds
            changingSize = false
            terminal.needsLayout = true

        }
    }

    deinit {
        // Remove observers safely
        NotificationCenter.default.removeObserver(self)
        if isViewLoaded {
            view.removeObserver(self, forKeyPath: "effectiveAppearance")
        }
        // Remove event monitors
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        scrollerHideTimer?.invalidate()
    }
    
    @objc
    func zoomGestureHandler (_ sender: NSMagnificationGestureRecognizer) {
        if sender.magnification > 0 {
            biggerFont (sender)
        } else {
            smallerFont(sender)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        changingSize = true

        // Update glass background to cover full view
        glassHostingView?.frame = view.bounds

        // Update container frame for proper titlebar inset and padding
        terminalContainer?.frame = containerFrameWithPadding()
        terminal.frame = terminalContainer?.bounds ?? view.bounds

        // Update scroll indicator position
        updateScrollIndicatorFrame()

        changingSize = false
        terminal.needsLayout = true

        // Ensure terminal layer background stays transparent after layout
        terminal.layer?.backgroundColor = NSColor.clear.cgColor
    }


    @objc @IBAction
    func set80x25 (_ source: AnyObject)
    {
        terminal.resize(cols: 80, rows: 25)
    }

    var lowerCol = 80
    var lowerRow = 25
    var higherCol = 160
    var higherRow = 60
    
    func queueNextSize ()
    {
        // If they requested a stop
        if resizificating == 0 {
            return
        }
        var next = terminal.getTerminal().getDims ()
        if resizificating > 0 {
            if next.cols < higherCol {
                next.cols += 1
            }
            if next.rows < higherRow {
                next.rows += 1
            }
        } else {
            if next.cols > lowerCol {
                next.cols -= 1
            }
            if next.rows > lowerRow {
                next.rows -= 1
            }
        }
        terminal.resize (cols: next.cols, rows: next.rows)
        var direction = resizificating
        
        if next.rows == higherRow && next.cols == higherCol {
            direction = -1
        }
        if next.rows == lowerRow && next.cols == lowerCol {
            direction = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.resizificating = direction
            self.queueNextSize()
        }
    }
    
    var resizificating = 0
    
    @objc @IBAction
    func resizificator (_ source: AnyObject)
    {
        if resizificating != 1 {
            resizificating = 1
            queueNextSize ()
        } else {
            resizificating = 0
        }
    }

    @objc @IBAction
    func resizificatorDown (_ source: AnyObject)
    {
        if resizificating != -1 {
            resizificating = -1
            queueNextSize ()
        } else {
            resizificating = 0
        }
    }

    @objc @IBAction
    func allowMouseReporting (_ source: AnyObject)
    {
        terminal.allowMouseReporting.toggle ()
    }

    @objc @IBAction
    func toggleAlwaysDarkMode(_ source: AnyObject) {
        Self.alwaysDarkMode.toggle()
    }

    @objc @IBAction
    func exportBuffer (_ source: AnyObject)
    {
        saveData { self.terminal.getTerminal().getBufferAsData () }
    }

    @objc @IBAction
    func exportSelection (_ source: AnyObject)
    {
        saveData {
            if let str = self.terminal.getSelection () {
                return str.data (using: .utf8) ?? Data ()
            }
            return Data ()
        }
    }

    func saveData (_ getData: @escaping () -> Data)
    {
        let savePanel = NSSavePanel ()
        savePanel.canCreateDirectories = true
        if #available(macOS 12.0, *) {
            savePanel.allowedContentTypes = [UTType.text, UTType.plainText]
        } else {
            savePanel.allowedFileTypes = ["txt"]
        }
        savePanel.title = "Export Buffer Contents As Text"
        savePanel.nameFieldStringValue = "TerminalCapture"
        
        savePanel.begin { (result) in
            if result.rawValue == NSApplication.ModalResponse.OK.rawValue {
                let data = getData ()
                if let url = savePanel.url {
                    do {
                        try data.write(to: url)
                    } catch let error as NSError {
                        let alert = NSAlert (error: error)
                        alert.runModal()
                    }
                }
            }
        }
    }
    
    @objc @IBAction
    func softReset (_ source: AnyObject)
    {
        terminal.getTerminal().softReset ()
        terminal.setNeedsDisplay(terminal.frame)
    }
    
    @objc @IBAction
    func hardReset (_ source: AnyObject)
    {
        terminal.getTerminal().resetToInitialState ()
        terminal.setNeedsDisplay(terminal.frame)
    }
    
    @objc @IBAction
    func toggleOptionAsMetaKey (_ source: AnyObject)
    {
        terminal.optionAsMetaKey.toggle ()
    }
    
    @objc @IBAction
    func biggerFont (_ source: AnyObject)
    {
        let size = terminal.font.pointSize
        guard size < 72 else {
            return
        }

        // Use the current font family but increase size
        if let currentFont = terminal.font as NSFont?,
           let newFont = NSFont(name: currentFont.fontName, size: size + 1) {
            changeFontPreservingDimensions(to: newFont)
        } else {
            changeFontPreservingDimensions(to: NSFont.monospacedSystemFont(ofSize: size + 1, weight: .regular))
        }
        saveFont()
    }

    @objc @IBAction
    func smallerFont (_ source: AnyObject)
    {
        let size = terminal.font.pointSize
        guard size > 5 else {
            return
        }

        // Use the current font family but decrease size
        if let currentFont = terminal.font as NSFont?,
           let newFont = NSFont(name: currentFont.fontName, size: size - 1) {
            changeFontPreservingDimensions(to: newFont)
        } else {
            changeFontPreservingDimensions(to: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular))
        }
        saveFont()
    }

    @objc @IBAction
    func defaultFontSize  (_ source: AnyObject)
    {
        changeFontPreservingDimensions(to: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
        saveFont()
    }

    /// Changes the terminal font while keeping the same number of columns and rows.
    /// The window is resized to accommodate the new font size.
    private func changeFontPreservingDimensions(to newFont: NSFont) {
        guard let window = view.window else {
            terminal.font = newFont
            return
        }

        // Save current terminal dimensions (cols x rows)
        let dims = terminal.getTerminal().getDims()
        let savedCols = dims.cols
        let savedRows = dims.rows

        // Prevent sizeChanged from interfering
        changingSize = true

        // Apply the new font - the terminal will briefly have the same cols/rows
        terminal.font = newFont

        // Get the optimal frame size for the current dimensions with the new font
        // This gives us the exact size needed to display savedCols x savedRows
        let terminalOptimalSize = terminal.getOptimalFrameSize()

        // Calculate the new window frame
        let totalWidth = terminalOptimalSize.width + terminalPaddingLeft + terminalPaddingRight
        let newHeight = terminalOptimalSize.height + titlebarHeight + terminalPaddingBottom

        let windowFrame = window.frame
        // Keep the window's top-left corner anchored
        let newY = windowFrame.maxY - newHeight
        let newFrame = CGRect(x: windowFrame.minX, y: newY, width: totalWidth, height: newHeight)

        // Resize window and update layout
        window.setFrame(newFrame, display: true, animate: true)

        // Update container and terminal frames to match
        terminalContainer?.frame = containerFrameWithPadding()
        terminal.frame = terminalContainer?.bounds ?? view.bounds

        // Ensure terminal maintains the same dimensions
        terminal.resize(cols: savedCols, rows: savedRows)

        changingSize = false
    }

    // MARK: - Font Panel

    /// Shows the system font panel for selecting a font
    @objc @IBAction
    func showFontPanel(_ sender: AnyObject) {
        // Set the current font in the font panel
        let fontManager = NSFontManager.shared
        fontManager.setSelectedFont(terminal.font, isMultiple: false)

        // Show the font panel
        fontManager.orderFrontFontPanel(sender)

        // Make sure we receive font change notifications
        view.window?.makeFirstResponder(self)
    }

    /// Called when the user selects a font in the font panel
    @objc func changeFont(_ sender: Any?) {
        guard let fontManager = sender as? NSFontManager else { return }

        // Convert the current font to the new selected font
        let newFont = fontManager.convert(terminal.font)

        // Apply the new font to the terminal
        terminal.font = newFont

        // Save the font preference
        saveFont()
    }

    /// Saves the current font to UserDefaults
    private func saveFont() {
        let fontName = terminal.font.fontName
        let fontSize = terminal.font.pointSize
        UserDefaults.standard.set(fontName, forKey: "TerminalFontName")
        UserDefaults.standard.set(fontSize, forKey: "TerminalFontSize")
    }

    /// Loads the saved font from UserDefaults
    private func loadSavedFont() {
        guard let fontName = UserDefaults.standard.string(forKey: "TerminalFontName") else {
            return
        }
        let fontSize = UserDefaults.standard.double(forKey: "TerminalFontSize")
        if fontSize > 0, let font = NSFont(name: fontName, size: CGFloat(fontSize)) {
            terminal.font = font
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool
    {
        if item.action == #selector(debugToggleHostLogging(_:)) {
            if let m = item as? NSMenuItem {
                m.state = logging ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(resizificator(_:)) {
            if let m = item as? NSMenuItem {
                m.state = resizificating == 1 ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(resizificatorDown(_:)) {
            if let m = item as? NSMenuItem {
                m.state = resizificating == -1 ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(allowMouseReporting(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.allowMouseReporting ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(toggleOptionAsMetaKey(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.optionAsMetaKey ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(toggleAlwaysDarkMode(_:)) {
            if let m = item as? NSMenuItem {
                m.state = Self.alwaysDarkMode ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }

        // Only enable "Export selection" if we have a selection
        if item.action == #selector(exportSelection(_:)) {
            return terminal.selectionActive
        }

        // Handle glass tint menu item checkmarks
        if item.action == #selector(setGlassTint(_:)) {
            if let m = item as? NSMenuItem,
               let tintRawValue = m.identifier?.rawValue,
               let tint = GlassTint(rawValue: tintRawValue) {
                m.state = (GlassTint.current == tint) ? .on : .off
            }
        }

        return true
    }

    // MARK: - Glass Tint

    @objc @IBAction
    func setGlassTint(_ sender: NSMenuItem) {
        guard let tintRawValue = sender.identifier?.rawValue,
              let tint = GlassTint(rawValue: tintRawValue) else {
            return
        }
        GlassTint.current = tint
    }
    
    @objc @IBAction
    func debugToggleHostLogging (_ source: AnyObject)
    {
        logging = !logging
        updateLogging()
    }

}

// MARK: - SwiftUI Liquid Glass Background

/// Window corner radius constant (shared with Document.swift)
let windowCornerRadius: CGFloat = 24

/// Available glass tint options
enum GlassTint: String, CaseIterable {
    case clear = "clear"
    case red = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green = "green"
    case teal = "teal"
    case blue = "blue"
    case indigo = "indigo"
    case purple = "purple"
    case pink = "pink"

    var displayName: String {
        switch self {
        case .clear: return "Clear (Default)"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .indigo: return "Indigo"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    @available(macOS 26, *)
    var swiftUIColor: SwiftUI.Color? {
        switch self {
        case .clear: return nil
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        }
    }

    static var current: GlassTint {
        get {
            let rawValue = UserDefaults.standard.string(forKey: "GlassTint") ?? "clear"
            return GlassTint(rawValue: rawValue) ?? .clear
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "GlassTint")
            NotificationCenter.default.post(name: .glassTintDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let glassTintDidChange = Notification.Name("GlassTintDidChange")
}

/// Tint opacity for the glass effect in light mode (0.0 to 1.0)
let glassTintOpacityLight: Double = 0.25

/// Tint opacity for the glass effect in dark mode (0.0 to 1.0)
/// Slightly higher since plusLighter/screen can be more subtle on dark backgrounds
let glassTintOpacityDark: Double = 0.35

/// A SwiftUI view that provides the Liquid Glass background effect
@available(macOS 26, *)
struct GlassBackgroundView: View {
    var tintColor: SwiftUI.Color?
    var forceDarkMode: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    /// Effective color scheme, respecting force dark mode setting
    private var effectiveColorScheme: ColorScheme {
        forceDarkMode ? .dark : colorScheme
    }

    var body: some View {
        ZStack {
            // Base glass effect (no tint)
            SwiftUI.Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: windowCornerRadius))

            // Colored overlay with blend mode to tint the glass
            // Uses different blend modes for light vs dark mode
            if let tint = tintColor {
                RoundedRectangle(cornerRadius: windowCornerRadius)
                    .fill(tint.opacity(tintOpacity))
                    .blendMode(blendMode)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(forceDarkMode ? .dark : nil)
    }

    /// Returns appropriate opacity based on color scheme
    private var tintOpacity: Double {
        effectiveColorScheme == .dark ? glassTintOpacityDark : glassTintOpacityLight
    }

    /// Returns appropriate blend mode based on color scheme
    /// - Light mode: multiply (darkens, adds color)
    /// - Dark mode: plusLighter (adds luminance with color, creates a glow effect)
    private var blendMode: BlendMode {
        effectiveColorScheme == .dark ? .plusLighter : .multiply
    }
}

// MARK: - Title Edit View Controller

/// A view controller with a text field for editing the window title and tint color picker
class TitleEditViewController: NSViewController, NSTextFieldDelegate {
    var currentTitle: String = ""
    var currentTint: GlassTint = .clear
    var onTitleChanged: ((String) -> Void)?
    var onTintChanged: ((GlassTint) -> Void)?

    private var textField: NSTextField!
    private var tintButtons: [GlassTint: NSButton] = [:]
    private let circleSize: CGFloat = 24
    private let circleSpacing: CGFloat = 6

    override func loadView() {
        // Calculate width based on number of tint options
        let tintCount = GlassTint.allCases.count
        let tintRowWidth = CGFloat(tintCount) * circleSize + CGFloat(tintCount - 1) * circleSpacing
        let containerWidth = max(250, tintRowWidth + 24)

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 110))

        // Title Label
        let titleLabel = NSTextField(labelWithString: "Window Title:")
        titleLabel.frame = NSRect(x: 12, y: 82, width: containerWidth - 24, height: 17)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        containerView.addSubview(titleLabel)

        // Text field
        textField = NSTextField(frame: NSRect(x: 12, y: 58, width: containerWidth - 24, height: 22))
        textField.stringValue = currentTitle
        textField.placeholderString = "Enter custom title..."
        textField.delegate = self
        textField.target = self
        textField.action = #selector(textFieldAction)
        containerView.addSubview(textField)

        // Tint Label
        let tintLabel = NSTextField(labelWithString: "Window Tint:")
        tintLabel.frame = NSRect(x: 12, y: 32, width: containerWidth - 24, height: 17)
        tintLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        containerView.addSubview(tintLabel)

        // Tint color circles row
        let startX = (containerWidth - tintRowWidth) / 2
        for (index, tint) in GlassTint.allCases.enumerated() {
            let x = startX + CGFloat(index) * (circleSize + circleSpacing)
            let button = createTintButton(for: tint, at: NSPoint(x: x, y: 6))
            containerView.addSubview(button)
            tintButtons[tint] = button
        }

        // Update selection state
        updateTintSelection()

        self.view = containerView
    }

    private func createTintButton(for tint: GlassTint, at origin: NSPoint) -> NSButton {
        let button = NSButton(frame: NSRect(origin: origin, size: CGSize(width: circleSize, height: circleSize)))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.title = ""
        button.wantsLayer = true
        button.tag = GlassTint.allCases.firstIndex(of: tint) ?? 0
        button.target = self
        button.action = #selector(tintButtonClicked)
        button.toolTip = tint.displayName

        // Opacity to match the glass tint style (average of light/dark mode values)
        let tintOpacity: CGFloat = 0.5

        // Create the circle layer
        if let layer = button.layer {
            layer.cornerRadius = circleSize / 2
            layer.masksToBounds = true

            if tint == .clear {
                // Rainbow gradient for "Clear" option
                let gradientLayer = CAGradientLayer()
                gradientLayer.type = .conic
                gradientLayer.colors = [
                    NSColor.red.withAlphaComponent(tintOpacity).cgColor,
                    NSColor.orange.withAlphaComponent(tintOpacity).cgColor,
                    NSColor.yellow.withAlphaComponent(tintOpacity).cgColor,
                    NSColor.green.withAlphaComponent(tintOpacity).cgColor,
                    NSColor.cyan.withAlphaComponent(tintOpacity).cgColor,
                    NSColor.blue.withAlphaComponent(tintOpacity).cgColor,
                    NSColor.purple.withAlphaComponent(tintOpacity).cgColor,
                    NSColor.red.withAlphaComponent(tintOpacity).cgColor
                ]
                gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
                gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
                gradientLayer.frame = button.bounds
                gradientLayer.cornerRadius = circleSize / 2
                layer.addSublayer(gradientLayer)
            } else {
                // Semi-transparent color for other options
                layer.backgroundColor = tint.nsColor.withAlphaComponent(tintOpacity).cgColor
            }

            // Border for selection indicator (initially hidden)
            layer.borderWidth = 2
            layer.borderColor = NSColor.clear.cgColor
        }

        return button
    }

    @objc private func tintButtonClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index < GlassTint.allCases.count else { return }
        let tint = GlassTint.allCases[index]
        currentTint = tint
        updateTintSelection()
        onTintChanged?(tint)
    }

    private func updateTintSelection() {
        for (tint, button) in tintButtons {
            if let layer = button.layer {
                if tint == currentTint {
                    // Show selection ring
                    layer.borderColor = NSColor.controlAccentColor.cgColor
                } else {
                    layer.borderColor = NSColor.clear.cgColor
                }
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Select all text and focus the field
        textField.selectText(nil)
        view.window?.makeFirstResponder(textField)
    }

    @objc private func textFieldAction(_ sender: NSTextField) {
        commitTitle()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTitle()
    }

    private func commitTitle() {
        onTitleChanged?(textField.stringValue)
        dismiss(nil)
    }
}

// MARK: - GlassTint NSColor Extension

extension GlassTint {
    /// Returns the NSColor representation for use in AppKit
    var nsColor: NSColor {
        switch self {
        case .clear: return .clear
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .pink: return .systemPink
        }
    }
}
