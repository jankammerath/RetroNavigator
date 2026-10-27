//
//  GopherSchemeHandler.swift
//  RetroNavigator
//
//  gopher:// support (RFC 1436 and RFC 4266 URLs). WebKit hands gopher URLs
//  to this handler, which fetches them over TCP and renders menus as HTML in
//  the spirit of Netscape Navigator's built-in Gopher support.
//

import Foundation
import Network
import WebKit

nonisolated struct GopherSchemeHandler: URLSchemeHandler {
    func reply(for request: URLRequest) -> some AsyncSequence<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let url = request.url else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }
                let (mimeType, data) = await Self.load(url)
                let response = URLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
                )
                continuation.yield(.response(response))
                continuation.yield(.data(data))
                continuation.finish()
            }
            // WebKit cancels the sequence when the load is no longer needed.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fetches a gopher URL and returns the content to display.
    private static func load(_ url: URL) async -> (mimeType: String, data: Data) {
        guard let item = GopherLocation(url: url) else {
            return GopherRenderer.errorPage(title: "Bad Gopher URL", message: url.absoluteString)
        }

        // A search server without a query yet: show the search form.
        if item.type == "7" && item.query == nil {
            return GopherRenderer.searchPage(for: item)
        }

        do {
            var request = item.selector
            if let query = item.query {
                request += "\t" + query
            }
            let data = try await GopherClient.fetch(host: item.host, port: item.port, request: request + "\r\n")
            return GopherRenderer.render(data, as: item)
        } catch {
            return GopherRenderer.errorPage(
                title: "Gopher Error",
                message: "Could not retrieve \(url.absoluteString):<br>\(GopherRenderer.escape(error.localizedDescription))"
            )
        }
    }
}

// MARK: - URL

/// A parsed gopher URL: `gopher://host[:port]/<type><selector>[%09<search>]`.
nonisolated struct GopherLocation {
    let host: String
    let port: UInt16
    let type: Character
    let selector: String
    /// Search terms for type 7 items, from `%09` in the URL or from the
    /// search form (`?q=`).
    let query: String?

    init?(url: URL) {
        guard url.scheme?.lowercased() == "gopher", let host = url.host(), !host.isEmpty else { return nil }
        self.host = host
        port = UInt16(url.port ?? 70)

        var path = url.path(percentEncoded: false)
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        // An empty path is the server's root menu.
        type = path.first ?? "1"
        var selector = String(path.dropFirst())
        var query: String?
        if let tab = selector.firstIndex(of: "\t") {
            query = String(selector[selector.index(after: tab)...])
            selector = String(selector[..<tab])
        }
        if let formQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value {
            query = formQuery
        }
        self.selector = selector
        self.query = query
    }

    /// Builds the URL of a menu item.
    static func url(host: String, port: String, type: Character, selector: String) -> String {
        let portSuffix = (port == "70" || port.isEmpty) ? "" : ":\(port)"
        let encoded = selector.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selector
        return "gopher://\(host)\(portSuffix)/\(type)\(encoded)"
    }
}

// MARK: - Network

nonisolated enum GopherClient {
    /// The largest response accepted, to keep runaway servers in check.
    private static let maximumSize = 32 * 1024 * 1024

    /// Sends a request line and reads the response until the server closes
    /// the connection, as the Gopher protocol specifies.
    static func fetch(host: String, port: UInt16, request: String) async throws -> Data {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 70,
            using: .tcp
        )
        let queue = DispatchQueue(label: "RetroNavigator.Gopher")
        defer { connection.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Only touched from `queue`.
                nonisolated(unsafe) var buffer = Data()
                nonisolated(unsafe) var hasResumed = false

                func finish(_ result: Result<Data, Error>) {
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(with: result)
                }

                func receive() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        if let data {
                            buffer.append(data)
                        }
                        if buffer.count > maximumSize {
                            finish(.success(buffer))
                        } else if let error {
                            // A reset after data arrived still counts as a reply.
                            buffer.isEmpty ? finish(.failure(error)) : finish(.success(buffer))
                        } else if isComplete {
                            finish(.success(buffer))
                        } else {
                            receive()
                        }
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                            if let error {
                                finish(.failure(error))
                            } else {
                                receive()
                            }
                        })
                    case .failed(let error), .waiting(let error):
                        finish(.failure(error))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)

                // Give up on servers that never answer.
                queue.asyncAfter(deadline: .now() + 30) {
                    finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

// MARK: - Rendering

nonisolated enum GopherRenderer {
    static func render(_ data: Data, as item: GopherLocation) -> (mimeType: String, data: Data) {
        switch item.type {
        case "1", "7":
            return html(menuPage(decode(data), item: item))
        case "0":
            return ("text/plain", Data(textContent(decode(data)).utf8))
        case "h":
            return ("text/html", data)
        default:
            return (mimeType(for: item), data)
        }
    }

    // MARK: Menus

    private static func menuPage(_ text: String, item: GopherLocation) -> String {
        var rows: [String] = []
        for line in lines(of: text) {
            if line == "." { break }
            guard let type = line.first else { continue }
            let fields = line.dropFirst().components(separatedBy: "\t")
            let display = escape(fields.first ?? "")
            let selector = fields.count > 1 ? fields[1] : ""
            let host = fields.count > 2 ? fields[2] : item.host
            let port = fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespaces) : "70"

            switch type {
            case "i":
                rows.append(#"<div class="info">\#(display)</div>"#)
            case "3":
                rows.append(#"<div class="item"><img src="\#(Icon.error)">\#(display)</div>"#)
            case "h" where selector.hasPrefix("URL:"):
                // A link to another protocol, e.g. the web.
                let href = escape(String(selector.dropFirst(4)))
                rows.append(#"<div class="item"><img src="\#(Icon.web)"><a href="\#(href)">\#(display)</a></div>"#)
            case "8", "T":
                let href = escape("telnet://\(host):\(port)")
                rows.append(#"<div class="item"><img src="\#(Icon.telnet)"><a href="\#(href)">\#(display)</a></div>"#)
            case "2":
                // CSO phone-book servers aren't supported.
                rows.append(#"<div class="item"><img src="\#(Icon.binary)">\#(display)</div>"#)
            default:
                let href = escape(GopherLocation.url(host: host, port: port, type: type, selector: selector))
                rows.append(#"<div class="item"><img src="\#(icon(for: type))"><a href="\#(href)">\#(display)</a></div>"#)
            }
        }
        let location = escape("\(item.host)\(item.selector.isEmpty ? "/" : item.selector)")
        return page(title: "Gopher Menu: \(location)", heading: "Gopher Menu", body: rows.joined(separator: "\n"))
    }

    static func searchPage(for item: GopherLocation) -> (mimeType: String, data: Data) {
        let action = escape(GopherLocation.url(host: item.host, port: String(item.port), type: "7", selector: item.selector))
        let body = """
        <p>This is a searchable Gopher index. Enter search keywords:</p>
        <form method="get" action="\(action)">
        <input type="text" name="q" size="40" autofocus> <input type="submit" value="Search">
        </form>
        """
        return html(page(title: "Gopher Search: \(escape(item.host))", heading: "Gopher Search", body: body))
    }

    static func errorPage(title: String, message: String) -> (mimeType: String, data: Data) {
        html(page(title: escape(title), heading: escape(title), body: "<p>\(message)</p>"))
    }

    private static func page(title: String, heading: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
        body { background: #fff; color: #000; margin: 12px 16px; font: 13px Monaco, Menlo, monospace; }
        h1 { font: bold 22px Times, "Times New Roman", serif; margin: 0 0 6px; }
        hr { border: 0; border-top: 1px solid #999; border-bottom: 1px solid #fff; margin: 0 0 10px; }
        .item, .info { white-space: pre; line-height: 18px; }
        .info { padding-left: 22px; }
        .item img { width: 16px; height: 16px; vertical-align: -3px; margin-right: 6px; }
        a { color: #00e; } a:visited { color: #551a8b; }
        p, form { font: 14px Times, "Times New Roman", serif; }
        </style></head>
        <body><h1>\(heading)</h1><hr>
        \(body)
        </body></html>
        """
    }

    // MARK: Text

    /// A text document without the protocol's terminating "." line and with
    /// dot-stuffed lines restored.
    private static func textContent(_ text: String) -> String {
        var result: [String] = []
        for line in lines(of: text) {
            if line == "." { break }
            result.append(line.hasPrefix("..") ? String(line.dropFirst()) : line)
        }
        return result.joined(separator: "\n")
    }

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// Gopher predates Unicode; fall back to Latin-1 for older servers.
    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func html(_ string: String) -> (mimeType: String, data: Data) {
        ("text/html", Data(string.utf8))
    }

    // MARK: Binary items

    private static func mimeType(for item: GopherLocation) -> String {
        let ext = (item.selector as NSString).pathExtension.lowercased()
        switch (item.type, ext) {
        case ("g", _): return "image/gif"
        case ("p", _), (_, "png"): return "image/png"
        case (_, "jpg"), (_, "jpeg"): return "image/jpeg"
        case (_, "gif"): return "image/gif"
        case ("I", _): return "image/jpeg"
        case ("d", _), (_, "pdf"): return "application/pdf"
        case ("s", _), (_, "wav"): return ext == "mp3" ? "audio/mpeg" : "audio/wav"
        case (_, "txt"): return "text/plain"
        case (_, "html"), (_, "htm"): return "text/html"
        default: return "application/octet-stream"
        }
    }

    private static func icon(for type: Character) -> String {
        switch type {
        case "1": return Icon.folder
        case "0": return Icon.text
        case "7": return Icon.search
        case "g", "I", "p": return Icon.image
        case "s": return Icon.sound
        case "h": return Icon.web
        default: return Icon.binary
        }
    }

    /// Small Navigator-style item icons as inline SVG.
    private enum Icon {
        static let folder = svg(##"<path d="M1 4h5l1 1h8v9H1z" fill="#fc6" stroke="#000"/><path d="M1 6h14" stroke="#c93"/>"##)
        static let text = svg(##"<path d="M3 1h7l3 3v11H3z" fill="#fff" stroke="#000"/><path d="M5 6h6M5 8h6M5 10h6M5 12h4" stroke="#666"/>"##)
        static let search = svg(##"<circle cx="6.5" cy="6.5" r="4" fill="#cdf" stroke="#000" stroke-width="1.5"/><path d="M9.5 9.5l5 5" stroke="#000" stroke-width="2"/>"##)
        static let image = svg(##"<rect x="1.5" y="2.5" width="13" height="11" fill="#9cf" stroke="#000"/><path d="M2 13l4-5 3 3 2-2 3 4z" fill="#393"/><circle cx="11" cy="5.5" r="1.5" fill="#ff0"/>"##)
        static let sound = svg(##"<path d="M2 6h3l4-3v10l-4-3H2z" fill="#ccc" stroke="#000"/><path d="M11 5q2 3 0 6M13 3q3 5 0 10" fill="none" stroke="#000"/>"##)
        static let web = svg(##"<circle cx="8" cy="8" r="6.5" fill="#6af" stroke="#000"/><path d="M1.5 8h13M8 1.5q-4 6.5 0 13q4-6.5 0-13" fill="none" stroke="#036"/>"##)
        static let telnet = svg(##"<rect x="1.5" y="2.5" width="13" height="9" fill="#333" stroke="#000"/><path d="M4 6l2 1.5L4 9" stroke="#3f3" fill="none"/><path d="M5 14h6" stroke="#000" stroke-width="2"/>"##)
        static let binary = svg(##"<path d="M3 1h7l3 3v11H3z" fill="#ddd" stroke="#000"/><text x="4.5" y="12" font-size="5" font-family="monospace">01</text>"##)
        static let error = svg(##"<circle cx="8" cy="8" r="6.5" fill="#f33" stroke="#000"/><path d="M5 5l6 6M11 5l-6 6" stroke="#fff" stroke-width="2"/>"##)

        private static func svg(_ content: String) -> String {
            let source = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">\#(content)</svg>"#
            return "data:image/svg+xml;base64," + Data(source.utf8).base64EncodedString()
        }
    }
}
