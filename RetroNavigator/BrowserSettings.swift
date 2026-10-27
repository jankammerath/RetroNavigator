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

    /// Wayback dates are whole days in UTC.
    nonisolated static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    nonisolated static func utcDate(year: Int, month: Int, day: Int) -> Date {
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
        // Shown as a Mac OS 9 movable modal dialog (see AppDelegate.showSettings).
        ClassicWindow(title: "RetroNavigator Preferences", isDialog: true) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        label("Home Page:")
                            .frame(width: 76, alignment: .trailing)
                        ClassicTextField(text: $draftHomePage)
                    }
                    Button("Restore Default") {
                        draftHomePage = BrowserSettings.defaultHomePage
                    }
                    .buttonStyle(ClassicPushButtonStyle())
                    .padding(.leading, 76 + 8)
                }

                ClassicGroupBox(title: "Wayback Machine") {
                    VStack(alignment: .leading, spacing: 10) {
                        ClassicCheckbox(title: "Browse the web as it was on a past date", isOn: $draftIsWaybackEnabled)
                        HStack(spacing: 6) {
                            label("Date:")
                            ClassicPopUp(options: monthOptions, selection: dateComponent(.month))
                                .frame(width: 110)
                            ClassicPopUp(options: dayOptions, selection: dateComponent(.day))
                                .frame(width: 56)
                            ClassicPopUp(options: yearOptions, selection: dateComponent(.year))
                                .frame(width: 72)
                        }
                        .disabled(!draftIsWaybackEnabled)
                        Text("Pages are loaded from archive.org's Wayback Machine through a built-in proxy, without the archive's banner.")
                            .font(.system(size: 10))
                            .foregroundStyle(Platinum.darkShadow)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 12) {
                    Spacer()
                    Button("Cancel", action: closeWindow)
                        .buttonStyle(ClassicPushButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Apply", action: apply)
                        .buttonStyle(ClassicPushButtonStyle(isDefault: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        // The Platinum look is light-only; keep text dark in Dark Mode.
        .environment(\.colorScheme, .light)
        // Start from the saved values each time the window opens.
        .onAppear(perform: loadDraft)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color.black)
    }

    // MARK: Date pop-ups

    private var monthOptions: [ClassicPopUp<Int>.Option] {
        let names = DateFormatter().standaloneMonthSymbols ?? []
        return names.enumerated().map { .init(value: $0.offset + 1, label: $0.element) }
    }

    private var dayOptions: [ClassicPopUp<Int>.Option] {
        let calendar = BrowserSettings.utcCalendar
        let days = calendar.range(of: .day, in: .month, for: draftWaybackDate) ?? 1..<32
        return days.map { .init(value: $0, label: String($0)) }
    }

    private var yearOptions: [ClassicPopUp<Int>.Option] {
        let calendar = BrowserSettings.utcCalendar
        let first = calendar.component(.year, from: BrowserSettings.earliestWaybackDate)
        let last = calendar.component(.year, from: .now)
        return (first...last).map { .init(value: $0, label: String($0)) }
    }

    /// A binding to one component of the draft date. The day is clamped to
    /// the new month's length and the date to the archive's range.
    private func dateComponent(_ component: Calendar.Component) -> Binding<Int> {
        let calendar = BrowserSettings.utcCalendar
        return Binding(
            get: { calendar.component(component, from: draftWaybackDate) },
            set: { newValue in
                var parts = calendar.dateComponents([.year, .month, .day], from: draftWaybackDate)
                parts.setValue(newValue, for: component)
                parts.day = 1
                guard let firstOfMonth = calendar.date(from: parts),
                      let days = calendar.range(of: .day, in: .month, for: firstOfMonth) else { return }
                let day = component == .day ? newValue : calendar.component(.day, from: draftWaybackDate)
                let date = BrowserSettings.utcDate(year: parts.year ?? 1999, month: parts.month ?? 1, day: min(day, days.upperBound - 1))
                draftWaybackDate = min(max(date, BrowserSettings.earliestWaybackDate), .now)
            }
        )
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
