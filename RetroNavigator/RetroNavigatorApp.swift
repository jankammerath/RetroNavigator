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
        // The windows are created by BrowserWindowManager and ClassicDialog
        // so they can be borderless, square-cornered windows that still
        // become key. The views draw the Mac OS 9 style chrome themselves.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    BrowserWindowManager.shared.openWindow()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
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
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BrowserWindowManager.shared.openWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Shows the preferences dialog, recreating it so it starts from the
    /// saved settings each time.
    func showSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        settingsWindow = ClassicDialog.present(title: "RetroNavigator Preferences") { _ in
            SettingsView()
        }
    }
}

/// Borderless windows normally refuse key/main status, which would keep the
/// custom chrome permanently inactive and block keyboard input.
final class ClassicNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
