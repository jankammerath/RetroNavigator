//
//  BrowserNavigationDecider.swift
//  RetroNavigator
//
//  Navigation policy for browser pages: new-window links, downloads and
//  trust for the Wayback proxy's certificate.
//

import Foundation
import WebKit

final class BrowserNavigationDecider: WebPage.NavigationDeciding {
    /// The page this decider belongs to, for showing converted WAP content.
    weak var page: WebPage?

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }

        // Links with a `download` attribute.
        if action.shouldPerformDownload {
            DownloadManager.shared.requestDownload(DownloadRequest(url: url))
            return .cancel
        }
        // No target frame means the link wants a new window (target="_blank").
        if action.target == nil {
            BrowserWindowManager.shared.openWindow(url: url)
            return .cancel
        }
        return .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        let urlResponse = response.response

        // WAP content (WML, WBMP, WMLScript) is converted to HTML and shown
        // under its own URL, keeping history and the Location field intact.
        if let url = urlResponse.url, WAPRenderer.kind(mimeType: urlResponse.mimeType, url: url) != nil {
            let page = self.page
            Task {
                let html = await WAPRenderer.render(url: url)
                page?.load(simulatedRequest: URLRequest(url: url), responseHTML: html)
            }
            return .cancel
        }

        let disposition = (urlResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isAttachment = disposition.lowercased().hasPrefix("attachment")

        // Files WebKit can't display, or that the server marks for saving,
        // are downloaded instead of opened inline.
        guard isAttachment || !response.canShowMimeType, let url = urlResponse.url else {
            return .allow
        }
        DownloadManager.shared.requestDownload(DownloadRequest(
            url: url,
            suggestedFilename: urlResponse.suggestedFilename,
            mimeType: urlResponse.mimeType,
            expectedLength: urlResponse.expectedContentLength > 0 ? urlResponse.expectedContentLength : nil
        ))
        return .cancel
    }

    /// While time travelling, every request goes through the proxy, and https
    /// is answered by its internal TLS endpoint. WebKit is told to trust that
    /// endpoint's certificate, matched exactly and only in Wayback mode.
    func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard BrowserSettings.isWaybackEnabled,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              ProxyCertificate.matches(trust) else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
