//
//  BrowserWindows.swift
//  RetroNavigator
//
//  Creates and tracks the browser windows and classic dialog windows. All
//  windows are borderless `ClassicNSWindow`s whose SwiftUI content draws the
//  Mac OS 9 chrome.
//

import SwiftUI
import AppKit

@MainActor
final class BrowserWindowManager {
    static let shared = BrowserWindowManager()

    private var windows: [NSWindow] = []

    /// Opens a new browser window showing `url`, or the home page.
    func openWindow(url: URL? = nil) {
        let window = ClassicNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RetroNavigator"
        let hostingView = NSHostingView(rootView: ContentView(initialURL: url))
        // Only enforce the minimum size; don't let the web view's ideal size
        // resize the window.
        hostingView.sizingOptions = [.minSize]
        window.contentView = hostingView
        window.hasShadow = true
        window.isReleasedWhenClosed = false

        // Cascade new windows from the frontmost one, like classic Mac OS.
        if let previous = windows.last(where: \.isVisible) {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 22, y: previous.frame.maxY - 22))
        } else {
            window.center()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let closed = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.windows.removeAll { $0 === closed }
            }
        }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Presents SwiftUI content in a classic movable modal dialog window.
@MainActor
enum ClassicDialog {
    /// Shows `content` in a new borderless dialog window sized to fit it.
    /// The content receives a closure that closes the window.
    @discardableResult
    static func present<Content: View>(
        title: String,
        @ViewBuilder content: (_ close: @escaping () -> Void) -> Content
    ) -> NSWindow {
        let window = ClassicNSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: content { [weak window] in window?.close() })
        window.title = title
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
