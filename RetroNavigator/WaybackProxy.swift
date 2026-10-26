//
//  WaybackProxy.swift
//  RetroNavigator
//
//  A built-in HTTP proxy that serves the web from archive.org's Wayback
//  Machine, ported from HttpTimeTravelProxy:
//  https://github.com/jankammerath/HttpTimeTravelProxy
//
//  WebKit is pointed at it through `WKWebsiteDataStore.proxyConfigurations`
//  while time travel is enabled. Archived content is requested with the `id_`
//  modifier, so pages arrive exactly as archived, without the Wayback banner
//  or rewritten links.
//

import Foundation
import Network
import WebKit

nonisolated final class WaybackProxy: @unchecked Sendable {
    static let shared = WaybackProxy()

    private let queue = DispatchQueue(label: "RetroNavigator.WaybackProxy")
    private let session: URLSession
    private var listener: NWListener?
    private var port: UInt16?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// A proxy configuration for WebKit pointing at this proxy, starting it
    /// on a free localhost port the first time.
    func proxyConfiguration() async throws -> ProxyConfiguration {
        let port = try await start()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        return ProxyConfiguration(httpCONNECTProxy: endpoint)
    }

    private func start() async throws -> UInt16 {
        if let port {
            return port
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Only touched from the listener's serial queue.
            nonisolated(unsafe) var hasResumed = false
            listener.stateUpdateHandler = { state in
                guard !hasResumed else { return }
                switch state {
                case .ready:
                    hasResumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    hasResumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        self.port = port
        return port
    }

    // MARK: Connection handling

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            await handle(connection)
            connection.cancel()
        }
    }

    private func handle(_ connection: NWConnection) async {
        guard var request = await readRequest(from: connection) else { return }

        // WebKit tunnels requests through the proxy with CONNECT. Plain HTTP
        // inside the tunnel can be served; TLS can't be decrypted.
        if request.method == "CONNECT" {
            guard !request.target.hasSuffix(":443") else {
                await send(.badGateway("Secure (https) connections are not available while browsing the Wayback Machine."), to: connection)
                return
            }
            await send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), to: connection)
            guard let tunnelled = await readRequest(from: connection) else { return }
            request = tunnelled
        }

        // Like the original proxy, only GET is supported: the archive holds
        // no dynamic content.
        guard request.method == "GET", let url = request.url else {
            await send(.badRequest, to: connection)
            return
        }
        await send(await fetchFromArchive(url), to: connection)
    }

    private func readRequest(from connection: NWConnection) async -> ProxyRequest? {
        var buffer = Data()
        let headerEnd = Data("\r\n\r\n".utf8)
        while buffer.range(of: headerEnd) == nil {
            guard buffer.count < 64 * 1024, let chunk = await receive(from: connection) else {
                return nil
            }
            buffer.append(chunk)
        }
        return ProxyRequest(head: String(decoding: buffer, as: UTF8.self))
    }

    private func receive(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                continuation.resume(returning: data?.isEmpty == false ? data : nil)
            }
        }
    }

    private func send(_ response: ProxyResponse, to connection: NWConnection) async {
        await send(response.serialized(), to: connection)
    }

    private func send(_ data: Data, to connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    // MARK: Wayback Machine

    private func fetchFromArchive(_ url: String) async -> ProxyResponse {
        // Unlike the original proxy, this skips the availability API: asking
        // for the date directly makes the Wayback Machine redirect to the
        // closest snapshot, which is followed below. That saves one round
        // trip for every page, image and stylesheet.
        let target = "https://web.archive.org/web/\(BrowserSettings.waybackTimestamp)id_/\(url)"
        return await request(target, originalURL: url, redirectsLeft: 8)
    }

    private func request(_ target: String, originalURL: String, redirectsLeft: Int) async -> ProxyResponse {
        guard let targetURL = URL(string: target) else {
            return .badRequest
        }
        do {
            let (data, response) = try await session.data(from: targetURL)
            guard let http = response as? HTTPURLResponse else {
                return .badGateway("The archive returned an invalid response.")
            }
            switch http.statusCode {
            case 200...299:
                // URLSession has already decompressed the body, so only the
                // content type is passed on.
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                return .ok(contentType: contentType, body: data)

            case 301, 302, 303, 307, 308:
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let resolved = URL(string: location, relativeTo: targetURL)?.absoluteString else {
                    return .badGateway("The archive returned a redirect without a location.")
                }
                let destination = Self.originalURL(from: resolved)
                if Self.isSameResource(Self.originalURL(from: target), destination), redirectsLeft > 0 {
                    // Internal Wayback redirect to the closest snapshot: follow it.
                    return await request(resolved, originalURL: originalURL, redirectsLeft: redirectsLeft - 1)
                }
                // A redirect the archived site itself made: pass it to the
                // browser with the original URL, kept on plain http.
                return .redirect(status: http.statusCode == 301 ? 301 : 302, location: Self.downgradedToHTTP(destination))

            case 404:
                return .notFound(originalURL)

            default:
                return .badGateway("The remote server returned HTTP \(http.statusCode).")
            }
        } catch {
            return .badGateway(error.localizedDescription)
        }
    }

    /// Extracts the original URL from `https://web.archive.org/web/<timestamp>/<url>`.
    static func originalURL(from waybackURL: String) -> String {
        guard let range = waybackURL.range(of: "web.archive.org/web/") else { return waybackURL }
        let rest = waybackURL[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return waybackURL }
        return String(rest[rest.index(after: slash)...])
    }

    /// Compares URLs ignoring the scheme, a leading "www." and a trailing
    /// slash, as the Wayback Machine switches between them when redirecting
    /// to the closest capture (e.g. www.apple.com → apple.com).
    private static func isSameResource(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ url: String) -> String {
            var result = url
            for prefix in ["https://", "http://", "www."] where result.hasPrefix(prefix) {
                result.removeFirst(prefix.count)
            }
            if result.hasSuffix("/") {
                result.removeLast()
            }
            return result.lowercased()
        }
        return normalized(lhs) == normalized(rhs)
    }

    private static func downgradedToHTTP(_ url: String) -> String {
        url.hasPrefix("https://") ? "http://" + url.dropFirst("https://".count) : url
    }
}

// MARK: - Request and response

/// The parts of an HTTP/1.1 request head the proxy needs.
private nonisolated struct ProxyRequest {
    let method: String
    /// The request target: an absolute URL, a path, or `host:port` for CONNECT.
    let target: String
    let host: String?

    init?(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3 else { return nil }
        method = parts[0].uppercased()
        target = String(parts[1])
        host = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst("host:".count).trimmingCharacters(in: .whitespaces) }
    }

    /// The full URL: requests sent straight to a proxy carry an absolute URL,
    /// requests inside a CONNECT tunnel only a path plus the Host header.
    var url: String? {
        if target.lowercased().hasPrefix("http://") {
            return target
        }
        guard let host, target.hasPrefix("/") else { return nil }
        return "http://\(host)\(target)"
    }
}

private nonisolated struct ProxyResponse {
    let status: Int
    let reason: String
    var headers: [(String, String)] = []
    var body = Data()

    static func ok(contentType: String, body: Data) -> ProxyResponse {
        ProxyResponse(status: 200, reason: "OK", headers: [("Content-Type", contentType)], body: body)
    }

    static func redirect(status: Int, location: String) -> ProxyResponse {
        ProxyResponse(status: status, reason: status == 301 ? "Moved Permanently" : "Found", headers: [("Location", location)])
    }

    static func notFound(_ url: String) -> ProxyResponse {
        errorPage(status: 404, reason: "Not Found", message: "The Wayback Machine has no copy of this content:<br><b>\(url)</b>")
    }

    static func badGateway(_ text: String) -> ProxyResponse {
        errorPage(status: 502, reason: "Bad Gateway", message: "The proxy server encountered a problem when fetching the content:<br><b>\(text)</b>")
    }

    static let badRequest = errorPage(
        status: 400,
        reason: "Bad Request",
        message: "The proxy server cannot understand the request or does not support the request method."
    )

    private static func errorPage(status: Int, reason: String, message: String) -> ProxyResponse {
        let html = """
        <!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
        <html><head><title>\(status) \(reason)</title></head>
        <body><h1>\(reason)</h1>\(message)</body></html>
        """
        return ProxyResponse(status: status, reason: reason, headers: [("Content-Type", "text/html")], body: Data(html.utf8))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Server: RetroNavigator-WaybackProxy\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Stops URLSession from following redirects, so they can be inspected.
private nonisolated final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    // The completion-handler form is used because the async form currently
    // crashes the compiler in this nonisolated class.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Navigation

/// While time travelling, top-level https navigations are re-issued over
/// http: the proxy can't decrypt TLS, and old sites were archived over http.
final class WaybackNavigationDecider: WebPage.NavigationDeciding {
    weak var page: WebPage?

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard BrowserSettings.isWaybackEnabled,
              action.target?.isMainFrame != false,
              let url = action.request.url,
              url.scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .allow
        }
        components.scheme = "http"
        if let httpURL = components.url {
            Task { page?.load(httpURL) }
        }
        return .cancel
    }
}
