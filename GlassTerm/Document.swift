//
//  Document.swift
//  GlassTerm
//
//  Created by Miguel de Icaza on 3/11/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Cocoa

/// Toolbar item identifier for the edit title button
extension NSToolbarItem.Identifier {
    static let editTitle = NSToolbarItem.Identifier("EditTitleItem")
}

/// Custom window controller that hides the tab bar "+" button
class GlassTermWindowController: NSWindowController {
    /// Override to prevent AppKit from showing the "+" button in the tab bar.
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSResponder.newWindowForTab(_:)) {
            return false
        }
        return super.responds(to: aSelector)
    }
}

class Document: NSDocument, NSToolbarDelegate {

    override init() {
        super.init()
        // Add your subclass-specific initialization here.
    }

    // MARK: - Tab Bar "+" Button Control

    /// Override to prevent AppKit from showing the "+" button in the tab bar.
    /// By returning false for the newWindowForTab: selector, AppKit won't show the add button.
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSResponder.newWindowForTab(_:)) {
            return false
        }
        return super.responds(to: aSelector)
    }

    override func makeWindowControllers() {
        // Returns the Storyboard that contains your Document window.
        let storyboard = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: nil)
        let storyboardWC = storyboard.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier("Document Window Controller")) as! NSWindowController

        // Create our custom window controller with the storyboard's window
        let windowController = GlassTermWindowController(window: storyboardWC.window)
        windowController.contentViewController = storyboardWC.contentViewController

        // Configure window for Liquid Glass transparency
        if let window = windowController.window {
            // Make titlebar transparent and extend content underneath
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)

            // Allow window to be transparent
            window.isOpaque = false
            window.backgroundColor = .clear

            // Use unified title/toolbar for modern appearance
            window.titleVisibility = .visible

            // Add an empty toolbar to increase titlebar height (Tahoe style)
            let toolbar = NSToolbar(identifier: "MainToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unified

            // Move traffic light buttons inward slightly for larger corner radius
            // Use a smaller inset that works well with or without tabs
            let trafficLightInset: CGFloat = 6
            for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(buttonType) {
                    var frame = button.frame
                    frame.origin.x += trafficLightInset
                    button.setFrameOrigin(frame.origin)
                }
            }

            // Increase window corner radius (uses windowCornerRadius from ViewController.swift)
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.cornerRadius = windowCornerRadius
                contentView.layer?.masksToBounds = true
            }

            // Set minimum window size to prevent terminal from becoming too small
            window.minSize = NSSize(width: 400, height: 300)

            // Enable native macOS window tabbing
            // Use .automatic so Cmd+N creates new windows, Cmd+T creates tabs
            window.tabbingMode = .automatic
            window.tabbingIdentifier = "GlassTermWindow"

            // Allow tabbing but disable full screen (green button will zoom/maximize instead)
            // This avoids issues with Liquid Glass in full screen
            window.collectionBehavior = [.fullScreenNone]
        }

        self.addWindowController(windowController)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, .editTitle]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, .editTitle]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == .editTitle {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Edit Title"
            item.paletteLabel = "Edit Title"
            item.toolTip = "Edit window title"

            // Create button with pencil icon
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            button.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit title")?
                .withSymbolConfiguration(config)
            button.target = nil  // Use responder chain
            button.action = Selector(("editTitleFromToolbar:"))
            button.alphaValue = 0  // Initially hidden, controlled by ViewController

            item.view = button
            return item
        }
        return nil
    }

    override func data(ofType typeName: String) throws -> Data {
       // Insert code here to write your document to data of the specified type, throwing an error in case of failure.
       // Alternatively, you could remove this method and override fileWrapper(ofType:), write(to:ofType:), or write(to:ofType:for:originalContentsURL:) instead.
        guard let wc = windowControllers.first else {
            throw NSError(domain: NSOSStatusErrorDomain, code: controlErr, userInfo: nil)
        }
        guard let vc = wc.contentViewController as? ViewController else {
            throw NSError(domain: NSOSStatusErrorDomain, code: controlErr, userInfo: nil)
        }
        return vc.terminal.getTerminal().getBufferAsData ()
   }
}

