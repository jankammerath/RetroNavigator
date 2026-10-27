//
//  WAPRenderer.swift
//  RetroNavigator
//
//  WAP support: WML decks are converted to HTML pages styled like a phone
//  screen, WBMP images are converted to PNG, and WMLScript runs in the page
//  (see Content/wml-runtime.js). WebKit can't display these formats, so the
//  navigation decider hands them to `WAPRenderer` instead.
//

import Foundation
import AppKit

nonisolated enum WAPRenderer {
    enum Kind {
        case wml, wbmp, wmlScript, compiledWML, compiledWMLScript
    }

    /// The WAP format of a response, or `nil` for anything else.
    static func kind(mimeType: String?, url: URL) -> Kind? {
        switch mimeType?.lowercased() ?? "" {
        case "text/vnd.wap.wml": return .wml
        case "image/vnd.wap.wbmp": return .wbmp
        case "text/vnd.wap.wmlscript": return .wmlScript
        case "application/vnd.wap.wmlc": return .compiledWML
        case "application/vnd.wap.wmlscriptc": return .compiledWMLScript
        default: break
        }
        // Servers often sent WAP files with generic types.
        switch url.pathExtension.lowercased() {
        case "wml": return .wml
        case "wbmp": return .wbmp
        case "wmls": return .wmlScript
        case "wmlc": return .compiledWML
        case "wmlsc": return .compiledWMLScript
        default: return nil
        }
    }

    /// Fetches `url` and returns an HTML page that displays it.
    static func render(url: URL) async -> String {
        do {
            let (data, response) = try await WAPFetcher.fetch(url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return WAPPage.message(title: "WAP Error", text: "The server returned HTTP \(http.statusCode) for \(url.absoluteString).")
            }
            switch kind(mimeType: response.mimeType, url: url) ?? .wml {
            case .wml:
                let document = try WMLParser.parse(data)
                let images = await inlineImages(WMLConverter.imageSources(in: document), baseURL: url)
                return WMLConverter.html(from: document, url: url, images: images)
            case .wbmp:
                guard let png = WBMPDecoder.pngData(from: data) else {
                    return WAPPage.message(title: "WBMP", text: "This WBMP image couldn't be decoded.")
                }
                return WAPPage.image(dataURI: "data:image/png;base64," + png.base64EncodedString(), title: url.lastPathComponent)
            case .wmlScript:
                let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                return WAPPage.source(source, title: url.lastPathComponent)
            case .compiledWML, .compiledWMLScript:
                return WAPPage.message(
                    title: "Compiled WAP Content",
                    text: "This page is in a compiled WAP format (WBXML), which phones received from WAP gateways. RetroNavigator can show text WML and WMLScript only."
                )
            }
        } catch {
            return WAPPage.message(title: "WAP Error", text: "Could not display \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    /// Fetches WBMP images and returns them as PNG data URIs, keyed by the
    /// `src` attribute they were referenced with.
    private static func inlineImages(_ sources: [String], baseURL: URL) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for source in Set(sources) {
                group.addTask {
                    guard let url = URL(string: source, relativeTo: baseURL)?.absoluteURL,
                          let (data, _) = try? await WAPFetcher.fetch(url),
                          let png = WBMPDecoder.pngData(from: data) else {
                        return (source, nil)
                    }
                    return (source, "data:image/png;base64," + png.base64EncodedString())
                }
            }
            var images: [String: String] = [:]
            for await (source, dataURI) in group {
                images[source] = dataURI
            }
            return images
        }
    }
}

// MARK: - Fetching

nonisolated enum WAPFetcher {
    /// Fetches a WAP resource like a period phone would, from the Wayback
    /// Machine while time travelling.
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var target = url
        if BrowserSettings.isWaybackEnabled,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let archived = URL(string: "https://web.archive.org/web/\(BrowserSettings.waybackTimestamp)id_/\(url.absoluteString)") {
            target = archived
        }
        var request = URLRequest(url: target)
        request.setValue("Nokia7110/1.0 (05.01)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/vnd.wap.wml, text/vnd.wap.wmlscript, image/vnd.wap.wbmp, */*;q=0.5", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: request)
    }
}

// MARK: - WML parsing

nonisolated enum WMLParser {
    static func parse(_ data: Data) throws -> XMLDocument {
        var text = decode(data)
        // Without the WML DTD, its entities are unknown to the XML parser.
        text = text.replacingOccurrences(of: "&nbsp;", with: "&#160;")
            .replacingOccurrences(of: "&shy;", with: "&#173;")
        // Don't fetch the DTD, and declare the (already decoded) text as UTF-8.
        text = text.replacingOccurrences(of: #"<!DOCTYPE[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"(<\?xml[^>]*?encoding\s*=\s*["'])[^"']*(["'])"#, with: "$1utf-8$2", options: .regularExpression)
        do {
            return try XMLDocument(xmlString: text, options: [])
        } catch {
            // Lots of real-world WML isn't well-formed; let libxml repair it.
            return try XMLDocument(xmlString: text, options: [.documentTidyXML])
        }
    }

    /// Decodes using the encoding from the XML declaration (WML was usually
    /// ISO-8859-1 or UTF-8).
    private static func decode(_ data: Data) -> String {
        let head = String(decoding: data.prefix(200), as: UTF8.self)
        if let range = head.range(of: #"encoding\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
            let name = head[range].split(whereSeparator: { $0 == "\"" || $0 == "'" }).dropFirst().first.map(String.init) ?? ""
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

// MARK: - WML to HTML

nonisolated enum WMLConverter {
    /// `src` attributes of images that may need converting (WBMP or unknown
    /// types). Common web image formats are left for WebKit to load.
    static func imageSources(in document: XMLDocument) -> [String] {
        let images = (try? document.nodes(forXPath: "//img")) ?? []
        return images.compactMap { ($0 as? XMLElement)?.attributeValue("src") }.filter { source in
            let ext = (URL(string: source)?.pathExtension ?? "").lowercased()
            return !["gif", "png", "jpg", "jpeg"].contains(ext)
        }
    }

    static func html(from document: XMLDocument, url: URL, images: [String: String]) -> String {
        let renderer = ContentRenderer(images: images)
        guard let root = document.rootElement() else {
            return WAPPage.message(title: "WML", text: "This WML deck is empty.")
        }

        var cards: [String: Any] = [:]
        var order: [String] = []
        var sections = ""
        for (index, card) in root.elements(forName: "card").enumerated() {
            let id = card.attributeValue("id") ?? "card\(index + 1)"
            guard cards[id] == nil else { continue }
            order.append(id)
            var info: [String: Any] = [
                "title": card.attributeValue("title") ?? "",
                "newcontext": card.attributeValue("newcontext") == "true",
                "events": events(of: card),
                "dos": doElements(in: card)
            ]
            if let timer = card.elements(forName: "timer").first {
                info["timer"] = ["name": timer.attributeValue("name") ?? "", "value": timer.attributeValue("value") ?? "0"]
            }
            cards[id] = info
            sections += "<section class=\"wml-card\" data-card=\"\(escape(id))\" hidden>\(renderer.children(of: card))</section>\n"
        }

        let template = root.elements(forName: "template").first
        let deck: [String: Any] = [
            "url": url.absoluteString,
            "title": root.elements(forName: "card").first?.attributeValue("title") ?? "",
            "order": order,
            "cards": cards,
            "template": [
                "events": template.map(events(of:)) ?? [:],
                "dos": template.map(doElements(in:)) ?? []
            ]
        ]
        // JSONSerialization escapes "/", so "</script>" can't end the script early.
        let deckJSON = (try? JSONSerialization.data(withJSONObject: deck)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return WAPPage.deck(title: deck["title"] as? String ?? "", baseURL: url, sections: sections, deckJSON: deckJSON)
    }

    // MARK: Tasks and events

    /// The task (`go`, `prev`, `refresh`, `noop`) inside an element.
    static func task(in element: XMLElement) -> [String: Any]? {
        guard let child = element.children?.compactMap({ $0 as? XMLElement })
            .first(where: { ["go", "prev", "refresh", "noop"].contains($0.name?.lowercased() ?? "") }) else { return nil }
        return action(from: child)
    }

    static func action(from task: XMLElement) -> [String: Any] {
        let setvars = task.elements(forName: "setvar").map { [$0.attributeValue("name") ?? "", $0.attributeValue("value") ?? ""] }
        switch task.name?.lowercased() {
        case "go":
            return [
                "type": "go",
                "href": task.attributeValue("href") ?? "",
                "method": task.attributeValue("method") ?? "get",
                "postfields": task.elements(forName: "postfield").map { [$0.attributeValue("name") ?? "", $0.attributeValue("value") ?? ""] },
                "setvars": setvars
            ]
        case "prev": return ["type": "prev", "setvars": setvars]
        case "refresh": return ["type": "refresh", "setvars": setvars]
        default: return ["type": "noop"]
        }
    }

    /// onenterforward, onenterbackward and ontimer, from attributes
    /// (shorthand for a `go`) or `<onevent>` elements.
    private static func events(of element: XMLElement) -> [String: Any] {
        var events: [String: Any] = [:]
        for name in ["onenterforward", "onenterbackward", "ontimer"] {
            if let href = element.attributeValue(name) {
                events[name] = ["type": "go", "href": href, "method": "get", "postfields": [], "setvars": []]
            }
        }
        for onevent in element.elements(forName: "onevent") {
            if let type = onevent.attributeValue("type"), let action = task(in: onevent) {
                events[type] = action
            }
        }
        return events
    }

    /// `<do>` elements (softkeys), wherever they appear in the element.
    private static func doElements(in element: XMLElement) -> [[String: Any]] {
        let elements = (try? element.nodes(forXPath: ".//do")) ?? []
        return elements.compactMap { $0 as? XMLElement }.map { item in
            let type = item.attributeValue("type") ?? "accept"
            return [
                "type": type,
                "label": item.attributeValue("label") ?? "",
                "name": item.attributeValue("name") ?? type,
                "action": task(in: item) ?? ["type": "noop"]
            ]
        }
    }

    // MARK: Content

    /// Renders card content as HTML.
    private struct ContentRenderer {
        let images: [String: String]

        func children(of node: XMLNode) -> String {
            (node.children ?? []).map(render).joined()
        }

        func render(_ node: XMLNode) -> String {
            switch node.kind {
            case .text:
                return text(node.stringValue ?? "")
            case .element:
                guard let element = node as? XMLElement else { return "" }
                return render(element)
            default:
                return ""
            }
        }

        /// Text with variable references is filled in by the runtime.
        private func text(_ value: String) -> String {
            value.contains("$")
                ? "<span data-template=\"\(escape(value))\">\(escape(value))</span>"
                : escape(value)
        }

        private func render(_ element: XMLElement) -> String {
            let name = element.name?.lowercased() ?? ""
            switch name {
            case "p":
                var style = ""
                if let align = element.attributeValue("align"), ["left", "center", "right"].contains(align) {
                    style += "text-align:\(align);"
                }
                if element.attributeValue("mode") == "nowrap" {
                    style += "white-space:nowrap;"
                }
                return "<p\(style.isEmpty ? "" : " style=\"\(style)\"")>\(children(of: element))</p>"
            case "br":
                return "<br>"
            case "b", "i", "u", "big", "small", "em", "strong", "pre", "tr", "td":
                return "<\(name)>\(children(of: element))</\(name)>"
            case "table":
                return "<table class=\"wml-table\">\(children(of: element))</table>"
            case "a":
                let action: [String: Any] = ["type": "go", "href": element.attributeValue("href") ?? "", "method": "get", "postfields": [], "setvars": []]
                return link(action: action, content: children(of: element))
            case "anchor":
                let content = (element.children ?? []).filter { child in
                    !["go", "prev", "refresh", "noop"].contains(child.name?.lowercased() ?? "")
                }.map(render).joined()
                return link(action: WMLConverter.task(in: element) ?? ["type": "noop"], content: content)
            case "img":
                return image(element)
            case "input":
                return input(element)
            case "select":
                return select(element)
            case "fieldset":
                let legend = element.attributeValue("title").map { "<legend>\(escape($0))</legend>" } ?? ""
                return "<fieldset>\(legend)\(children(of: element))</fieldset>"
            case "do", "onevent", "timer", "setvar", "go", "prev", "refresh", "noop", "postfield", "head", "template", "access", "meta":
                // Handled by the runtime (softkeys, events) or not displayed.
                return ""
            default:
                return children(of: element)
            }
        }

        private func link(action: [String: Any], content: String) -> String {
            let href = (action["href"] as? String).flatMap { $0.contains("$") ? nil : $0 } ?? "#"
            return "<a class=\"wml-link\" href=\"\(escape(href))\" data-action='\(jsonAttribute(action))'>\(content)</a>"
        }

        private func image(_ element: XMLElement) -> String {
            let alt = element.attributeValue("alt") ?? ""
            guard let source = element.attributeValue("src") else { return escape(alt) }
            var attributes = "src=\"\(escape(images[source] ?? source))\" alt=\"\(escape(alt))\""
            for name in ["width", "height"] {
                if let value = element.attributeValue(name) {
                    attributes += " \(name)=\"\(escape(value))\""
                }
            }
            if let align = element.attributeValue("align"), ["top", "middle", "bottom"].contains(align) {
                attributes += " style=\"vertical-align:\(align == "middle" ? "middle" : align)\""
            }
            return "<img \(attributes)>"
        }

        private func input(_ element: XMLElement) -> String {
            let type = element.attributeValue("type") == "password" ? "password" : "text"
            var attributes = "type=\"\(type)\" class=\"wml-input\""
            let mapping = ["name": "data-name", "value": "data-default", "size": "size", "maxlength": "maxlength", "title": "title", "format": "data-format"]
            for (wmlName, htmlName) in mapping {
                if let value = element.attributeValue(wmlName) {
                    attributes += " \(htmlName)=\"\(escape(value))\""
                }
            }
            return "<input \(attributes)>"
        }

        private func select(_ element: XMLElement) -> String {
            var attributes = "class=\"wml-select\""
            let mapping = ["name": "data-name", "iname": "data-iname", "value": "data-default", "title": "title"]
            for (wmlName, htmlName) in mapping {
                if let value = element.attributeValue(wmlName) {
                    attributes += " \(htmlName)=\"\(escape(value))\""
                }
            }
            if element.attributeValue("multiple") == "true" {
                attributes += " multiple"
            }
            return "<select \(attributes)>\(options(in: element))</select>"
        }

        private func options(in element: XMLElement) -> String {
            (element.children ?? []).compactMap { $0 as? XMLElement }.map { child in
                switch child.name?.lowercased() {
                case "optgroup":
                    return "<optgroup label=\"\(escape(child.attributeValue("title") ?? ""))\">\(options(in: child))</optgroup>"
                case "option":
                    var attributes = "value=\"\(escape(child.attributeValue("value") ?? ""))\""
                    var pick: [String: Any]?
                    if let href = child.attributeValue("onpick") {
                        pick = ["type": "go", "href": href, "method": "get", "postfields": [], "setvars": []]
                    } else if let onevent = child.elements(forName: "onevent").first(where: { $0.attributeValue("type") == "onpick" }) {
                        pick = WMLConverter.task(in: onevent)
                    }
                    if let pick {
                        attributes += " data-onpick='\(jsonAttribute(pick))'"
                    }
                    let label = (child.children ?? []).filter { $0.kind == .text }.compactMap(\.stringValue).joined()
                    return "<option \(attributes)>\(escape(label.trimmingCharacters(in: .whitespacesAndNewlines)))</option>"
                default:
                    return ""
                }
            }.joined()
        }
    }
}

nonisolated private extension XMLElement {
    func attributeValue(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }
}

nonisolated private func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// JSON for a single-quoted HTML attribute.
nonisolated private func jsonAttribute(_ object: [String: Any]) -> String {
    let json = (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    return escape(json)
}

// MARK: - WBMP

nonisolated enum WBMPDecoder {
    /// Converts a type 0 WBMP (1 bit per pixel, 1 = white) to PNG. White
    /// pixels become transparent, so the LCD shows through as on a phone.
    static func pngData(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0

        func multiByteInteger() -> Int? {
            var value = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value = (value << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
                if value > 1 << 24 { return nil }
            }
            return nil
        }

        guard multiByteInteger() == 0, index < bytes.count else { return nil }
        // Fixed header; extension headers follow if its top bit is set.
        let fixedHeader = bytes[index]
        index += 1
        if fixedHeader & 0x80 != 0 {
            while index < bytes.count, bytes[index] & 0x80 != 0 { index += 1 }
            index += 1
        }
        guard let width = multiByteInteger(), let height = multiByteInteger(),
              width > 0, height > 0, width * height <= 4_000_000 else { return nil }
        let rowBytes = (width + 7) / 8
        guard index + rowBytes * height <= bytes.count else { return nil }

        // Gray + alpha pairs: black pixels opaque, white pixels transparent.
        var pixels = [UInt8](repeating: 0, count: width * height * 2)
        for y in 0..<height {
            for x in 0..<width {
                let byte = bytes[index + y * rowBytes + x / 8]
                let isWhite = byte & (0x80 >> (x % 8)) != 0
                pixels[(y * width + x) * 2 + 1] = isWhite ? 0 : 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

// MARK: - Pages

/// HTML templates for WAP content, styled like a period phone display.
nonisolated enum WAPPage {
    private static let runtime: String = Bundle.main.url(forResource: "wml-runtime", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    private static let style = """
    html { background: #fff; }
    body { margin: 0; padding: 24px 0 32px; font-family: Geneva, "Lucida Grande", Verdana, sans-serif; }
    .wml-phone { width: 252px; margin: 0 auto; padding: 16px 16px 24px; border-radius: 28px 28px 40px 40px;
      background: linear-gradient(#59606a, #2e3238); box-shadow: inset 0 1px 0 rgba(255,255,255,.3), 0 3px 8px rgba(0,0,0,.35); }
    .wml-brand { text-align: center; color: #d4d8dc; font: bold 10px Geneva, sans-serif; letter-spacing: 3px; margin-bottom: 10px; }
    .wml-screen { display: flex; flex-direction: column; height: 300px; background: #b7c9a0; color: #18210e;
      border: 3px solid #1c2016; border-radius: 4px; box-shadow: inset 2px 2px 6px rgba(0,0,0,.35); }
    .wml-title { padding: 2px 6px; background: #18210e; color: #b7c9a0; font: bold 12px Geneva, sans-serif;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-height: 15px; }
    .wml-cards { flex: 1; overflow-y: auto; padding: 4px 6px; font-size: 13px; line-height: 1.3; word-wrap: break-word; }
    .wml-card p { margin: 0 0 4px; }
    .wml-card a { color: #0b1404; }
    .wml-card a:hover, .wml-card a:focus { background: #18210e; color: #b7c9a0; outline: none; }
    .wml-card img { max-width: 100%; image-rendering: pixelated; }
    .wml-card input, .wml-card select { font: inherit; color: inherit; background: #cad9b6; border: 1px solid #18210e;
      box-sizing: border-box; max-width: 100%; }
    .wml-card fieldset { border: 1px solid #18210e; margin: 2px 0; padding: 2px 4px; }
    .wml-card table { border-collapse: collapse; }
    .wml-card td { padding: 0 6px 0 0; vertical-align: top; }
    .wml-card pre { font: 12px Monaco, monospace; white-space: pre-wrap; margin: 0; }
    .wml-softkeys { display: flex; justify-content: space-between; gap: 4px; min-height: 17px; padding: 1px 4px;
      border-top: 1px solid #18210e; }
    .wml-softkeys button { background: none; border: 0; padding: 0 3px; color: #18210e; font: bold 12px Geneva, sans-serif; cursor: pointer; }
    .wml-softkeys button:hover { background: #18210e; color: #b7c9a0; }
    .wml-caption { margin-top: 10px; text-align: center; color: #999; font: 10px Geneva, sans-serif; }
    .wap-source { margin: 16px; font: 12px Monaco, Menlo, monospace; white-space: pre-wrap; }
    """

    static func deck(title: String, baseURL: URL, sections: String, deckJSON: String) -> String {
        phone(title: title, baseURL: baseURL, cards: sections, script: """
        <script>window.WML_DECK = \(deckJSON);</script>
        <script>\(runtime)</script>
        """)
    }

    static func image(dataURI: String, title: String) -> String {
        phone(title: title, baseURL: nil, cards: "<section class=\"wml-card\"><p style=\"text-align:center\"><img src=\"\(dataURI)\" alt=\"\"></p></section>", script: "")
    }

    static func message(title: String, text: String) -> String {
        phone(title: title, baseURL: nil, cards: "<section class=\"wml-card\"><p>\(escape(text))</p></section>", script: "")
    }

    static func source(_ source: String, title: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>\(style)</style></head>
        <body><pre class="wap-source">\(escape(source))</pre></body></html>
        """
    }

    private static func phone(title: String, baseURL: URL?, cards: String, script: String) -> String {
        let base = baseURL.map { "<base href=\"\(escape($0.absoluteString))\">" } ?? ""
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>\(base)<style>\(style)</style></head>
        <body>
        <div class="wml-phone">
          <div class="wml-brand">WAP</div>
          <div class="wml-screen">
            <div class="wml-title" id="wml-title">\(escape(title))</div>
            <div class="wml-cards" id="wml-cards">\(cards)</div>
            <div class="wml-softkeys" id="wml-softkeys"></div>
          </div>
        </div>
        <div class="wml-caption">WAP page rendered by RetroNavigator</div>
        \(script)
        </body></html>
        """
    }
}
