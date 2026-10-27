//
//  Downloads.swift
//  RetroNavigator
//
//  File downloads with Netscape-style classic dialogs: a "Save File"
//  confirmation followed by a "Saving File" progress window. Files are saved
//  to the Downloads folder.
//

import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

/// What's known about a file before it's downloaded.
struct DownloadRequest {
    let url: URL
    var suggestedFilename: String?
    var mimeType: String?
    var expectedLength: Int64?

    var filename: String {
        let candidates = [suggestedFilename, url.lastPathComponent]
        let name = candidates.compactMap { $0 }.first { !$0.isEmpty && $0 != "/" } ?? "download"
        // Never let a server-supplied name escape the Downloads folder.
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

// MARK: - Manager

@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    /// Keeps running downloads alive while their window is open.
    private var items: [DownloadItem] = []

    /// Asks whether to save the file, then downloads it.
    func requestDownload(_ request: DownloadRequest) {
        ClassicDialog.present(title: "Save File") { close in
            DownloadConfirmView(
                request: request,
                onCancel: close,
                onSave: {
                    close()
                    self.start(request, destination: Self.uniqueDestination(for: request.filename))
                },
                onSaveAs: {
                    self.chooseDestination(for: request) { destination in
                        close()
                        self.start(request, destination: destination)
                    }
                }
            )
        }
    }

    /// Lets the user pick where to save the file. The save panel also grants
    /// the sandboxed app access to the chosen location.
    private func chooseDestination(for request: DownloadRequest, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Save File"
        panel.nameFieldStringValue = request.filename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.begin { response in
            // If the panel is cancelled, the Save File dialog stays open.
            if response == .OK, let url = panel.url {
                completion(url)
            }
        }
    }

    private func start(_ request: DownloadRequest, destination: URL) {
        let item = DownloadItem(request: request, destination: destination)
        items.append(item)
        ClassicDialog.present(title: "Saving File") { close in
            DownloadProgressView(item: item) {
                item.cancel()
                self.items.removeAll { $0 === item }
                close()
            }
        }
        item.start()
    }

    /// A file URL in the Downloads folder that doesn't exist yet, adding a
    /// number like "file 2.zip" if needed.
    private static func uniqueDestination(for filename: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(name)
            number += 1
        }
        return candidate
    }
}

// MARK: - Download

@MainActor
@Observable
final class DownloadItem {
    enum State: Equatable {
        case connecting, downloading, finished, failed(String), cancelled
    }

    let request: DownloadRequest
    let destination: URL
    private(set) var state: State = .connecting
    private(set) var receivedBytes: Int64 = 0
    private(set) var expectedBytes: Int64 = -1

    @ObservationIgnored private var startDate = Date.now
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var gopherTask: Task<Void, Never>?

    init(request: DownloadRequest, destination: URL) {
        self.request = request
        self.destination = destination
        expectedBytes = request.expectedLength ?? -1
    }

    /// Progress from 0 to 1, or `nil` if the size is unknown.
    var progress: Double? {
        if state == .finished { return 1 }
        guard expectedBytes > 0 else { return nil }
        return min(Double(receivedBytes) / Double(expectedBytes), 1)
    }

    /// Bytes per second since the download started.
    var bytesPerSecond: Double {
        let elapsed = Date.now.timeIntervalSince(startDate)
        return elapsed > 0 ? Double(receivedBytes) / elapsed : 0
    }

    var secondsLeft: Double? {
        guard expectedBytes > 0, bytesPerSecond > 0 else { return nil }
        return Double(expectedBytes - receivedBytes) / bytesPerSecond
    }

    func start() {
        startDate = .now
        if request.url.scheme?.lowercased() == "gopher" {
            startGopher()
        } else {
            Task { await startHTTP() }
        }
    }

    func cancel() {
        guard state == .connecting || state == .downloading else { return }
        state = .cancelled
        task?.cancel()
        gopherTask?.cancel()
        try? FileManager.default.removeItem(at: destination)
    }

    private func startHTTP() async {
        var urlRequest = URLRequest(url: request.url)
        if BrowserSettings.isWaybackEnabled,
           let archived = URL(string: "https://web.archive.org/web/\(BrowserSettings.waybackTimestamp)id_/\(request.url.absoluteString)") {
            // Time travelling: fetch the file from the archive, as the page did.
            urlRequest = URLRequest(url: archived)
        } else {
            // Send the browser's cookies, e.g. for downloads behind a login.
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                .filter { Self.cookie($0, matches: self.request.url) }
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
        }
        guard state == .connecting else { return }

        // The session releases its delegate (and these closures) when the
        // download completes, so capturing `self` doesn't leak.
        let delegate = DownloadDelegate(
            destination: destination,
            onProgress: { received, expected in
                Task { @MainActor in self.update(received: received, expected: expected) }
            },
            onFinish: { error in
                Task { @MainActor in self.finish(error: error) }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: urlRequest)
        self.task = task
        task.resume()
    }

    /// Gopher items are fetched with the browser's own Gopher client.
    private func startGopher() {
        gopherTask = Task {
            guard let location = GopherLocation(url: request.url) else {
                finish(error: "Invalid Gopher address.")
                return
            }
            do {
                let data = try await GopherClient.fetch(host: location.host, port: location.port, request: location.selector + "\r\n")
                try data.write(to: destination)
                receivedBytes = Int64(data.count)
                finish(error: nil)
            } catch {
                finish(error: error.localizedDescription)
            }
        }
    }

    private func update(received: Int64, expected: Int64) {
        guard state == .connecting || state == .downloading else { return }
        state = .downloading
        receivedBytes = received
        if expected > 0 {
            expectedBytes = expected
        }
    }

    private func finish(error: String?) {
        guard state == .connecting || state == .downloading else { return }
        if let error {
            state = .failed(error)
            try? FileManager.default.removeItem(at: destination)
        } else {
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? receivedBytes
            receivedBytes = size
            expectedBytes = size
            state = .finished
        }
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        let domainMatches = domain.hasPrefix(".")
            ? host == domain.dropFirst() || host.hasSuffix(domain)
            : host == domain
        return domainMatches && url.path.hasPrefix(cookie.path)
    }
}

/// Receives URLSession download callbacks on the session's queue.
private nonisolated final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onFinish: @Sendable (String?) -> Void
    /// Only touched from the session's serial delegate queue.
    private var failure: String?

    init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void, onFinish: @escaping @Sendable (String?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            failure = "The server returned HTTP \(http.statusCode)."
            return
        }
        // The temporary file is deleted when this method returns, so move it now.
        do {
            // The save panel already confirmed replacing an existing file.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error.localizedDescription
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onFinish(error?.localizedDescription ?? failure)
        session.finishTasksAndInvalidate()
    }
}

// MARK: - Dialogs

private let dialogFont = Font.system(size: 12)

/// "Save File" confirmation, shown before a download starts.
struct DownloadConfirmView: View {
    let request: DownloadRequest
    let onCancel: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void

    var body: some View {
        ClassicWindow(title: "Save File", isDialog: true) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: fileIcon(for: request.filename))
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("You have started to download a file:")
                        Text(request.filename)
                            .fontWeight(.bold)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(details)
                            .foregroundStyle(Platinum.darkShadow)
                        Text("It will be saved to your Downloads folder. Choose Save As… to save it elsewhere.")
                            .padding(.top, 4)
                    }
                    .font(dialogFont)
                    .foregroundStyle(Color.black)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button("Save As…", action: onSaveAs)
                        .buttonStyle(ClassicPushButtonStyle())
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(ClassicPushButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Save File", action: onSave)
                        .buttonStyle(ClassicPushButtonStyle(isDefault: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .light)
    }

    private var details: String {
        var parts: [String] = []
        if let mimeType = request.mimeType {
            parts.append("Type: \(mimeType)")
        }
        if let length = request.expectedLength, length > 0 {
            parts.append("Size: \(ByteCountFormatter.string(fromByteCount: length, countStyle: .file))")
        }
        parts.append("From: \(request.url.host() ?? request.url.absoluteString)")
        return parts.joined(separator: "\n")
    }
}

/// The "Saving File" progress window with a thermometer bar.
struct DownloadProgressView: View {
    let item: DownloadItem
    let onClose: () -> Void

    var body: some View {
        ClassicWindow(title: "Saving File", isDialog: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: fileIcon(for: item.request.filename))
                        .resizable()
                        .frame(width: 32, height: 32)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                        row("Saving:", item.request.filename)
                        row("Location:", item.request.url.absoluteString)
                        row("Saving to:", displayPath(of: item.destination))
                        row("Status:", status)
                        row("Time Left:", timeLeft)
                    }
                }

                ClassicProgressBar(progress: item.progress)
                    .frame(height: 12)

                HStack(spacing: 12) {
                    Spacer()
                    buttons
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private var buttons: some View {
        switch item.state {
        case .finished:
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.destination])
            }
            .buttonStyle(ClassicPushButtonStyle())
            Button("Done", action: onClose)
                .buttonStyle(ClassicPushButtonStyle(isDefault: true))
                .keyboardShortcut(.defaultAction)
        case .failed, .cancelled:
            Button("Close", action: onClose)
                .buttonStyle(ClassicPushButtonStyle(isDefault: true))
                .keyboardShortcut(.defaultAction)
        case .connecting, .downloading:
            Button("Cancel", action: onClose)
                .buttonStyle(ClassicPushButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(dialogFont)
        .foregroundStyle(Color.black)
    }

    private var status: String {
        let received = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
        switch item.state {
        case .connecting:
            return "Connecting…"
        case .downloading:
            let rate = ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file)
            if item.expectedBytes > 0 {
                let total = ByteCountFormatter.string(fromByteCount: item.expectedBytes, countStyle: .file)
                return "\(received) of \(total) (at \(rate)/sec)"
            }
            return "\(received) received (at \(rate)/sec)"
        case .finished:
            return "Done (\(received))"
        case .failed(let message):
            return "Failed: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }

    private var timeLeft: String {
        guard item.state == .downloading, let seconds = item.secondsLeft else {
            return item.state == .finished ? "00:00:00" : "—"
        }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// A short, readable location like "Downloads/file.zip" or "~/Documents/file.zip".
private func displayPath(of url: URL) -> String {
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
        .resolvingSymlinksInPath().path
    let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().path
    if folder == downloads {
        return "Downloads/\(url.lastPathComponent)"
    }
    // Inside the sandbox, NSHomeDirectory() is the app's container, so use
    // the user's real home folder to shorten the path.
    let path = url.resolvingSymlinksInPath().path
    if let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }), path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

/// The Finder icon for a file name's type.
private func fileIcon(for filename: String) -> NSImage {
    let ext = (filename as NSString).pathExtension
    return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
}
