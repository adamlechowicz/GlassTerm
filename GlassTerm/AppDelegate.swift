//
//  AppDelegate.swift
//  GlassTerm
//
//  Created by Miguel de Icaza on 3/11/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Cocoa

/// Custom document controller that hides the tab bar "+" button
class GlassTermDocumentController: NSDocumentController {
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSResponder.newWindowForTab(_:)) {
            return false
        }
        return super.responds(to: aSelector)
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet var loggingMenuItem: NSMenuItem?

    // Custom document controller to hide tab bar "+" button
    let documentController = GlassTermDocumentController()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Configure menu icons for the new macOS Tahoe design
        configureShellMenuIcons()
        configureEditMenuIcons()
        configureViewMenuIcons()
        configureWindowMenuIcons()
        configureOpacityMenuItem()
    }

    // MARK: - Menu Icon Configuration

    /// Configures icons for all Shell menu items
    private func configureShellMenuIcons() {
        guard let mainMenu = NSApp.mainMenu,
              let shellMenu = mainMenu.item(withTitle: "Shell")?.submenu else {
            return
        }

        // Configure icons for each Shell menu item
        let menuIconMappings: [(title: String, symbolName: String)] = [
            ("New Window", "macwindow.badge.plus"),
            ("New Tab", "plus.square.on.square"),
            ("Close", "xmark"),
            ("Export Text As...", "square.and.arrow.up"),
            ("Export Selected Text As...", "text.badge.checkmark"),
            ("Hard Reset", "arrowtriangle.left")
        ]

        for mapping in menuIconMappings {
            if let menuItem = shellMenu.item(withTitle: mapping.title),
               let icon = NSImage(systemSymbolName: mapping.symbolName, accessibilityDescription: mapping.title) {
                icon.isTemplate = true
                menuItem.image = icon
            }
        }
    }

    /// Configures icons for Edit menu items
    private func configureEditMenuIcons() {
        guard let mainMenu = NSApp.mainMenu,
              let editMenu = mainMenu.item(withTitle: "Edit")?.submenu else {
            return
        }

        // Configure icon for Option as Meta Key
        if let menuItem = editMenu.item(withTitle: "Use Option as Meta Key"),
           let icon = NSImage(systemSymbolName: "option", accessibilityDescription: "Option Key") {
            icon.isTemplate = true
            menuItem.image = icon
        }
    }

    /// Configures icons for all View menu items
    private func configureViewMenuIcons() {
        guard let mainMenu = NSApp.mainMenu,
              let viewMenu = mainMenu.item(withTitle: "View")?.submenu else {
            return
        }

        // Configure icons for each View menu item
        let menuIconMappings: [(title: String, symbolName: String)] = [
            ("Reset to Default Font", "textformat.size"),
            ("Bigger", "plus.magnifyingglass"),
            ("Smaller", "minus.magnifyingglass"),
            ("Show Fonts…", "textformat"),
            ("Allow Mouse Reporting", "computermouse"),
            ("Color Tint", "app.background.dotted"),
            ("Always Dark Mode", "moon.fill")
        ]

        for mapping in menuIconMappings {
            if let menuItem = viewMenu.item(withTitle: mapping.title),
               let icon = NSImage(systemSymbolName: mapping.symbolName, accessibilityDescription: mapping.title) {
                icon.isTemplate = true
                menuItem.image = icon
            }
        }

        // Configure colored circle icons for Glass Tint submenu
        configureGlassTintSubmenuIcons(in: viewMenu)
    }

    /// Configures icons for Window menu items
    private func configureWindowMenuIcons() {
        guard let mainMenu = NSApp.mainMenu,
              let windowMenu = mainMenu.item(withTitle: "Window")?.submenu else {
            return
        }

        // Configure icons for each Window menu item
        let menuIconMappings: [(title: String, symbolName: String)] = [
            ("Minimize", "minus.rectangle"),
            ("Zoom", "arrow.up.left.and.arrow.down.right"),
            ("Show Next Tab", "arrow.right.square"),
            ("Show Previous Tab", "arrow.left.square"),
            ("Move Tab to New Window", "rectangle.portrait.and.arrow.right"),
            ("Merge All Windows", "rectangle.stack"),
            ("Bring All to Front", "rectangle.3.group")
        ]

        for mapping in menuIconMappings {
            if let menuItem = windowMenu.item(withTitle: mapping.title),
               let icon = NSImage(systemSymbolName: mapping.symbolName, accessibilityDescription: mapping.title) {
                icon.isTemplate = true
                menuItem.image = icon
            }
        }
    }

    /// Configures colored circle icons for the Glass Tint submenu items
    private func configureGlassTintSubmenuIcons(in viewMenu: NSMenu) {
        guard let glassTintItem = viewMenu.item(withTitle: "Color Tint"),
              let submenu = glassTintItem.submenu else {
            return
        }

        for item in submenu.items {
            guard let identifier = item.identifier?.rawValue,
                  let tint = GlassTint(rawValue: identifier) else {
                continue
            }

            let circleImage = createTintCircleImage(for: tint, size: 12)
            item.image = circleImage
        }
    }

    /// Creates a circular color swatch image for a tint option
    private func createTintCircleImage(for tint: GlassTint, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let path = NSBezierPath(ovalIn: rect)

        // Opacity to match the glass tint style
        let tintOpacity: CGFloat = 0.6

        if tint == .clear {
            // Rainbow gradient for "Clear" option
            // Draw segments of colors around the circle
            let colors: [NSColor] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple]
            let segmentAngle = 360.0 / CGFloat(colors.count)
            let center = NSPoint(x: size / 2, y: size / 2)
            let radius = size / 2

            for (index, color) in colors.enumerated() {
                let startAngle = CGFloat(index) * segmentAngle
                let endAngle = startAngle + segmentAngle

                let segmentPath = NSBezierPath()
                segmentPath.move(to: center)
                segmentPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                segmentPath.close()

                color.withAlphaComponent(tintOpacity).setFill()
                segmentPath.fill()
            }
        } else {
            // Solid color circle
            tint.nsColor.withAlphaComponent(tintOpacity).setFill()
            path.fill()
        }

        image.unlockFocus()
        return image
    }

    // MARK: - Glass Opacity

    /// Popover currently presenting the opacity slider (retained while visible)
    private var opacityPopover: NSPopover?

    /// Adds the "Glass Opacity…" item to the View menu; it opens a popover hosting the slider.
    private func configureOpacityMenuItem() {
        guard let mainMenu = NSApp.mainMenu,
              let viewMenu = mainMenu.item(withTitle: "View")?.submenu else {
            return
        }

        let item = NSMenuItem(title: "Glass Opacity…", action: #selector(showOpacityPopover(_:)), keyEquivalent: "")
        item.target = self
        if let icon = NSImage(systemSymbolName: "circle.righthalf.filled", accessibilityDescription: "Glass Opacity") {
            icon.isTemplate = true
            item.image = icon
        }

        // Place it just after the Color Tint item, grouped with the other glass-appearance controls.
        if let colorTintItem = viewMenu.item(withTitle: "Color Tint") {
            viewMenu.insertItem(item, at: viewMenu.index(of: colorTintItem) + 1)
        } else {
            viewMenu.addItem(item)
        }
    }

    /// Opens a transient popover hosting the opacity slider, anchored to the active window.
    /// Hosting the slider in a popover (instead of embedding it directly in the menu) keeps
    /// continuous interaction out of the menu's event-tracking system, which is unreliable for
    /// live controls.
    @objc func showOpacityPopover(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else {
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = OpacityPopoverViewController()
        opacityPopover = popover

        // Anchor near the top-center of the active window; the popover drops down from there.
        let anchor = NSRect(x: contentView.bounds.midX, y: contentView.bounds.maxY - 1, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    // MARK: - Tab Management

    /// Creates a new tab in the current window
    @objc func newTab(_ sender: Any?) {
        guard let currentWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            // No window exists, create a new one instead
            try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
            return
        }

        do {
            // Create a new document
            let newDocument = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false) as! NSDocument
            newDocument.makeWindowControllers()

            // Get the new window from the document
            guard let newWindow = newDocument.windowControllers.first?.window else {
                // Fallback: just display normally
                newDocument.showWindows()
                return
            }

            // Add the new window as a tab to the current window
            currentWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)

        } catch {
            // Silently fail - document creation errors are rare
        }
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dockMenu = NSMenu()

        let newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(newWindowFromDock(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        dockMenu.addItem(newWindowItem)

        return dockMenu
    }

    @objc func newWindowFromDock(_ sender: Any?) {
        // Create a new document (which opens a new window)
        guard let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) else {
            return
        }

        // Bring the app and new window to the front
        NSApp.activate(ignoringOtherApps: true)
        if let window = document.windowControllers.first?.window {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Opacity Popover

/// A small view controller hosting the window-opacity slider, shown in a popover from the View menu.
/// Because it lives in a popover (a normal window-backed view) rather than an `NSMenuItem`'s custom
/// view, the slider can safely run continuously for live feedback.
final class OpacityPopoverViewController: NSViewController {
    override func loadView() {
        let width: CGFloat = 240
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 66))

        // Title
        let titleLabel = NSTextField(labelWithString: "Glass Opacity")
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.frame = NSRect(x: 16, y: 40, width: width - 32, height: 18)
        container.addSubview(titleLabel)

        // Slider (0 = Glass, 1 = Translucent) — continuous is safe inside a popover
        let slider = NSSlider(
            value: GlassOpacity.current,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(sliderChanged(_:))
        )
        slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 20, width: width - 32, height: 20)
        container.addSubview(slider)

        // End labels describing the slider range
        let glassLabel = makeCaptionLabel("Glass", alignment: .left)
        glassLabel.frame = NSRect(x: 16, y: 4, width: 90, height: 14)
        container.addSubview(glassLabel)

        let translucentLabel = makeCaptionLabel("Translucent", alignment: .right)
        translucentLabel.frame = NSRect(x: width - 106, y: 4, width: 90, height: 14)
        container.addSubview(translucentLabel)

        self.view = container
    }

    /// Updates the global setting (persists + posts .windowOpacityDidChange) as the slider moves.
    @objc private func sliderChanged(_ sender: NSSlider) {
        GlassOpacity.current = sender.doubleValue
    }

    /// Creates a small secondary-color caption label for the slider ends
    private func makeCaptionLabel(_ text: String, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        return label
    }
}

