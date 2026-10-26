//
//  RetroNavigatorApp.swift
//  RetroNavigator
//
//  Created by Jan Kammerath on 26.10.26.
//

import SwiftUI
import AppKit

@main
struct RetroNavigatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The main window is created by AppDelegate so it can be a borderless,
        // square-cornered window that still becomes key. ContentView draws
        // the Mac OS 9 style chrome itself.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = ClassicNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RetroNavigator"
        window.contentView = NSHostingView(rootView: ContentView())
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Borderless windows normally refuse key/main status, which would keep the
/// custom chrome permanently inactive and block keyboard input.
final class ClassicNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
