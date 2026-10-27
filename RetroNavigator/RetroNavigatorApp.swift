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
        // The windows are created by AppDelegate so they can be borderless,
        // square-cornered windows that still become key. The views draw the
        // Mac OS 9 style chrome themselves.
        Settings {
            EmptyView()
        }
        .commands {
            // Open the classic preferences dialog instead of the standard
            // Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?

    /// Shows the preferences dialog, recreating it so it starts from the
    /// saved settings each time.
    func showSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hostingView = NSHostingView(rootView: SettingsView())
        let window = ClassicNSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "RetroNavigator Preferences"
        window.contentView = hostingView
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = ClassicNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RetroNavigator"
        let hostingView = NSHostingView(rootView: ContentView())
        // Only enforce the minimum size; don't let the web view's ideal size
        // resize the window.
        hostingView.sizingOptions = [.minSize]
        window.contentView = hostingView
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
