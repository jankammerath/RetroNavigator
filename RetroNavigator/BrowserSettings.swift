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

struct SettingsView: View {
    @AppStorage(BrowserSettings.homePageKey) private var homePage = BrowserSettings.defaultHomePage
    @AppStorage(BrowserSettings.waybackEnabledKey) private var isWaybackEnabled = false
    @AppStorage(BrowserSettings.waybackDateKey) private var waybackDate = BrowserSettings.defaultWaybackDate

    var body: some View {
        Form {
            Section("Home Page") {
                TextField("Location:", text: $homePage)
                Button("Restore Default") {
                    homePage = BrowserSettings.defaultHomePage
                }
            }

            Section("Wayback Machine") {
                Toggle("Browse the web as it was on a past date", isOn: $isWaybackEnabled)
                DatePicker(
                    "Date:",
                    selection: dateBinding,
                    in: BrowserSettings.earliestWaybackDate...Date.now,
                    displayedComponents: .date
                )
                .disabled(!isWaybackEnabled)
                Text("Pages are loaded from archive.org's Wayback Machine through a built-in proxy, without the archive's banner. Secure (https) addresses are visited over http, as they were archived.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// The date is stored as a `Double` so `@AppStorage` can persist it.
    private var dateBinding: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSinceReferenceDate: waybackDate) },
            set: { waybackDate = $0.timeIntervalSinceReferenceDate }
        )
    }
}

#Preview {
    SettingsView()
}
