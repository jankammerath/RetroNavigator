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
import Synchronization
import WebKit

nonisolated final class WaybackProxy: @unchecked Sendable {
    static let shared = WaybackProxy()

    private let queue = DispatchQueue(label: "RetroNavigator.WaybackProxy")
    private let session: URLSession
    private var listeners: [NWListener] = []
    private var port: UInt16?
    private var tlsPort: UInt16?

    /// Redirect bookkeeping shared by concurrently handled connections.
    private struct RedirectState {
        /// The configured timestamp the hints below belong to.
        var baseTimestamp = ""
        /// Capture timestamps to use for URLs an archived redirect pointed
        /// to, keyed by `resourceKey(_:)`.
        var timestampHints: [String: String] = [:]
        /// When each URL was last redirected, for loop detection.
        var recentRedirects: [String: [Date]] = [:]
    }

    private let redirectState = Mutex(RedirectState())

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

        // Internal TLS endpoint that https tunnels are relayed to. It presents
        // the bundled self-signed certificate, which WebKit accepts while
        // time travelling (see `WaybackNavigationDecider`).
        guard let identity = ProxyCertificate.identity,
              let secIdentity = sec_identity_create(identity) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        // The proxy is an app-lifetime singleton, so capturing it is fine.
        let tlsListener = try await startListener(using: NWParameters(tls: tlsOptions)) { connection in
            self.serve(connection) { await self.handleDecrypted($0) }
        }
        tlsPort = tlsListener.port

        // The proxy WebKit talks to.
        let listener = try await startListener(using: .tcp) { connection in
            self.serve(connection) { await self.handle($0) }
        }
        listeners = [listener.listener, tlsListener.listener]
        port = listener.port
        return listener.port
    }

    /// Starts a listener on a free localhost port and waits until it's ready.
    private func startListener(
        using parameters: NWParameters,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16) {
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = onConnection

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
        return (listener, port)
    }

    // MARK: Connection handling

    private func serve(_ connection: NWConnection, with handler: @escaping @Sendable (NWConnection) async -> Void) {
        connection.start(queue: queue)
        Task {
            await handler(connection)
            connection.cancel()
        }
    }

    private func handle(_ connection: NWConnection) async {
        guard var request = await readRequest(from: connection) else { return }

        // WebKit tunnels every request through the proxy with CONNECT.
        if request.method == "CONNECT" {
            await send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), to: connection)
            guard request.target.hasSuffix(":80") else {
                // https (often forced by HSTS): relay the encrypted stream to
                // the internal TLS endpoint, which serves it decrypted.
                await relayToTLSEndpoint(connection)
                return
            }
            guard let tunnelled = await readRequest(from: connection) else { return }
            request = tunnelled
        }
        await respond(to: request, scheme: "http", on: connection)
    }

    /// Serves a request that arrived through the internal TLS endpoint.
    private func handleDecrypted(_ connection: NWConnection) async {
        guard let request = await readRequest(from: connection) else { return }
        await respond(to: request, scheme: "https", on: connection)
    }

    private func respond(to request: ProxyRequest, scheme: String, on connection: NWConnection) async {
        // Like the original proxy, only GET is supported: the archive holds
        // no dynamic content.
        guard request.method == "GET", let url = request.url(scheme: scheme) else {
            await send(.badRequest, to: connection)
            return
        }
        await send(await fetchFromArchive(url), to: connection)
    }

    private func relayToTLSEndpoint(_ connection: NWConnection) async {
        guard let tlsPort, let port = NWEndpoint.Port(rawValue: tlsPort) else { return }
        let inner = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        inner.start(queue: queue)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pump(from: connection, to: inner) }
            group.addTask { await self.pump(from: inner, to: connection) }
            // When one side closes, close both so the other pump finishes too.
            await group.next()
            connection.cancel()
            inner.cancel()
        }
    }

    private func pump(from source: NWConnection, to destination: NWConnection) async {
        while let data = await receive(from: source) {
            await send(data, to: destination)
        }
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
        let target = "https://web.archive.org/web/\(timestamp(for: url))id_/\(url)"
        return await request(target, originalURL: url, redirectsLeft: 8)
    }

    /// The timestamp to request `url` at: the time of the capture that
    /// redirected to it, if any, otherwise the configured date.
    private func timestamp(for url: String) -> String {
        let configured = BrowserSettings.waybackTimestamp
        return redirectState.withLock { state in
            if state.baseTimestamp != configured {
                // The date was changed in the settings: start over.
                state = RedirectState(baseTimestamp: configured)
            }
            return state.timestampHints[Self.resourceKey(url)] ?? configured
        }
    }

    /// Records a redirect passed to the browser. Returns `false` if `source`
    /// keeps being redirected, i.e. the browser is stuck in a loop.
    private func recordRedirect(from source: String, to destination: String, captureTimestamp: String?) -> Bool {
        let now = Date.now
        return redirectState.withLock { state in
            let key = Self.resourceKey(source)
            let recent = (state.recentRedirects[key] ?? []).filter { now.timeIntervalSince($0) < 30 }
            state.recentRedirects[key] = recent + [now]
            // Captures far from the chosen date (e.g. a session URL only
            // archived ten years later) would drag the rest of the chain to
            // that time, so their timestamps aren't carried over.
            if let captureTimestamp,
               Self.monthsBetween(captureTimestamp, state.baseTimestamp) <= 12 {
                state.timestampHints[Self.resourceKey(destination)] = captureTimestamp
            }
            return recent.count < 3
        }
    }

    /// Approximate distance in months between two Wayback timestamps.
    private static func monthsBetween(_ lhs: String, _ rhs: String) -> Int {
        func months(_ timestamp: String) -> Int? {
            guard timestamp.count >= 6,
                  let year = Int(timestamp.prefix(4)),
                  let month = Int(timestamp.dropFirst(4).prefix(2)) else { return nil }
            return year * 12 + month
        }
        guard let a = months(lhs), let b = months(rhs) else { return .max }
        return abs(a - b)
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
                // browser with the original URL.
                //
                // The destination must then be fetched at the time of this
                // capture, as the Wayback Machine's own viewer does. Resolving
                // it against the configured date can pick captures from other
                // times whose redirects form a cycle (e.g. amazon.com in 2001).
                guard recordRedirect(from: originalURL, to: destination, captureTimestamp: Self.timestamp(from: resolved)) else {
                    return .redirectLoop(originalURL)
                }
                return .redirect(status: http.statusCode == 301 ? 301 : 302, location: destination)

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

    /// Extracts the capture timestamp (digits only) from
    /// `https://web.archive.org/web/20010901123456id_/<url>`.
    private static func timestamp(from waybackURL: String) -> String? {
        guard let range = waybackURL.range(of: "web.archive.org/web/") else { return nil }
        let digits = waybackURL[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// Compares URLs ignoring the scheme, a leading "www.", the default port
    /// and a trailing slash, as the Wayback Machine switches between them
    /// when redirecting to the closest capture (e.g. www.apple.com → apple.com).
    private static func isSameResource(_ lhs: String, _ rhs: String) -> Bool {
        resourceKey(lhs) == resourceKey(rhs)
    }

    private static func resourceKey(_ url: String) -> String {
        var result = url
        for prefix in ["https://", "http://", "www."] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        for port in [":80/", ":443/"] {
            if let range = result.range(of: port) {
                result.replaceSubrange(range, with: "/")
            }
        }
        if result.hasSuffix("/") {
            result.removeLast()
        }
        return result.lowercased()
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
    /// requests inside a tunnel only a path plus the Host header.
    func url(scheme: String) -> String? {
        let lowercased = target.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return target
        }
        guard var host, target.hasPrefix("/") else { return nil }
        if host.hasSuffix(":443") || host.hasSuffix(":80") {
            host = String(host[..<(host.lastIndex(of: ":") ?? host.endIndex)])
        }
        return "\(scheme)://\(host)\(target)"
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

    static func redirectLoop(_ url: String) -> ProxyResponse {
        errorPage(status: 508, reason: "Loop Detected", message: "The archived copies of this page keep redirecting to each other:<br><b>\(url)</b><br>Try a different date in the settings.")
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

// MARK: - Certificate

/// The self-signed certificate the proxy's internal TLS endpoint presents
/// for https requests (bundled as `WaybackProxy.p12`).
nonisolated enum ProxyCertificate {
    static let identity: SecIdentity? = {
        guard let url = Bundle.main.url(forResource: "WaybackProxy", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else { return nil }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "RetroNavigator"] as CFDictionary
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { return nil }
        return (identity as! SecIdentity)
    }()

    /// The DER-encoded certificate, used to recognise it exactly.
    static let certificateData: Data? = {
        guard let identity else { return nil }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }()

    /// Whether a server trust presents exactly the proxy's certificate.
    static func matches(_ trust: SecTrust) -> Bool {
        guard let certificateData,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return false
        }
        return SecCertificateCopyData(leaf) as Data == certificateData
    }
}
