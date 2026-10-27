//
//  BrowserSettings.swift
//  RetroNavigator
//
//  User preferences: the home page and the Wayback Machine time travel mode.
//

import SwiftUI

/// Keys, defaults and helpers for the browser's preferences in `UserDefaults`.
enum BrowserSettings {
    nonisolated static let homePageKey = "homePageURL"
    nonisolated static let waybackEnabledKey = "waybackEnabled"
    nonisolated static let waybackDateKey = "waybackDate"

    nonisolated static let defaultHomePage = "https://en.wikipedia.org/wiki/Netscape_Navigator"

    /// 12 April 1999, the default date of HttpTimeTravelProxy.
    nonisolated static let defaultWaybackDate = utcDate(year: 1999, month: 4, day: 12).timeIntervalSinceReferenceDate

    /// The Wayback Machine's earliest captures date from May 1996.
    nonisolated static let earliestWaybackDate = utcDate(year: 1996, month: 5, day: 10)

    nonisolated static var isWaybackEnabled: Bool {
        UserDefaults.standard.bool(forKey: waybackEnabledKey)
    }

    /// The selected date as a Wayback Machine timestamp, e.g. "19990412".
    nonisolated static var waybackTimestamp: String {
        let stored = UserDefaults.standard.object(forKey: waybackDateKey) as? Double ?? defaultWaybackDate
        let date = Date(timeIntervalSinceReferenceDate: stored)
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 1999, parts.month ?? 4, parts.day ?? 12)
    }

    /// Turns typed text into a URL, adding `http://` if no scheme was given.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "http://" + trimmed)
    }

    private nonisolated static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private nonisolated static func utcDate(year: Int, month: Int, day: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }
}

// MARK: - Settings window

/// Edits a draft of the preferences; nothing is saved until Apply.
struct SettingsView: View {
    @AppStorage(BrowserSettings.homePageKey) private var homePage = BrowserSettings.defaultHomePage
    @AppStorage(BrowserSettings.waybackEnabledKey) private var isWaybackEnabled = false
    @AppStorage(BrowserSettings.waybackDateKey) private var waybackDate = BrowserSettings.defaultWaybackDate

    @State private var draftHomePage = ""
    @State private var draftIsWaybackEnabled = false
    @State private var draftWaybackDate = Date.now

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Home Page") {
                    TextField("Location:", text: $draftHomePage)
                    Button("Restore Default") {
                        draftHomePage = BrowserSettings.defaultHomePage
                    }
                }

                Section("Wayback Machine") {
                    Toggle("Browse the web as it was on a past date", isOn: $draftIsWaybackEnabled)
                    DatePicker(
                        "Date:",
                        selection: $draftWaybackDate,
                        in: BrowserSettings.earliestWaybackDate...Date.now,
                        displayedComponents: .date
                    )
                    .disabled(!draftIsWaybackEnabled)
                    Text("Pages are loaded from archive.org's Wayback Machine through a built-in proxy, without the archive's banner. Secure (https) addresses are visited over http, as they were archived.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel", action: closeWindow)
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        // Start from the saved values each time the window opens.
        .onAppear(perform: loadDraft)
    }

    private func loadDraft() {
        draftHomePage = homePage
        draftIsWaybackEnabled = isWaybackEnabled
        draftWaybackDate = Date(timeIntervalSinceReferenceDate: waybackDate)
    }

    /// Saves the draft; the browser picks up the changes from `UserDefaults`.
    private func apply() {
        homePage = draftHomePage
        isWaybackEnabled = draftIsWaybackEnabled
        // The date is stored as a `Double` so `@AppStorage` can persist it.
        waybackDate = draftWaybackDate.timeIntervalSinceReferenceDate
        closeWindow()
    }

    private func closeWindow() {
        NSApplication.shared.keyWindow?.close()
    }
}

#Preview {
    SettingsView()
}
