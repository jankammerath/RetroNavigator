//
//  ContentView.swift
//  RetroNavigator
//
//  Created by Jan Kammerath on 26.10.26.
//

import SwiftUI
import AppKit
import WebKit

struct ContentView: View {
    @AppStorage(BrowserSettings.homePageKey) private var homePage = BrowserSettings.defaultHomePage
    @AppStorage(BrowserSettings.waybackEnabledKey) private var isWaybackEnabled = false
    @AppStorage(BrowserSettings.waybackDateKey) private var waybackDate = BrowserSettings.defaultWaybackDate

    @State private var page = WebPage.makeBrowserPage()
    @State private var address = ""
    @State private var isNavigationToolbarCollapsed = false
    @State private var isLocationBarCollapsed = false

    var body: some View {
        ClassicWindow(title: page.title.isEmpty ? "RetroNavigator" : page.title) {
            VStack(spacing: 0) {
                if !isNavigationToolbarCollapsed {
                    ToolbarPane(onCollapse: { collapse($isNavigationToolbarCollapsed) }) {
                        NavigationToolbar(isLoading: page.isLoading, onAction: handle)
                    }
                }
                if !isLocationBarCollapsed {
                    ToolbarPane(onCollapse: { collapse($isLocationBarCollapsed) }) {
                        LocationBar(address: $address, onSubmit: loadAddress)
                    }
                }
                if !collapsedToolbars.isEmpty {
                    CollapsedToolbarTray(tabs: collapsedToolbars)
                }
                ClassicWebView(page: page)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Platinum.darkShadow).frame(height: 1)
                    }
                StatusBar(message: statusMessage, progress: page.isLoading ? page.estimatedProgress : nil)
            }
            .background(Platinum.face)
        }
        // The Platinum look is light-only; keep text dark in Dark Mode.
        .environment(\.colorScheme, .light)
        .task {
            // Configure the proxy before the first load so the home page
            // already comes from the archive when time travel is on.
            await applyWaybackSettings()
            loadHomePage()
        }
        // Keep the Location field in sync with redirects and clicked links.
        .onChange(of: page.url) { _, newURL in
            if let newURL {
                address = newURL.absoluteString
            }
        }
        .onChange(of: isWaybackEnabled) {
            Task { await travelToSelectedTime() }
        }
        .onChange(of: waybackDate) {
            Task { await travelToSelectedTime() }
        }
    }

    /// Routes WebKit through the Wayback proxy while time travel is enabled.
    private func applyWaybackSettings() async {
        let dataStore = WKWebsiteDataStore.default()
        if isWaybackEnabled, let configuration = try? await WaybackProxy.shared.proxyConfiguration() {
            dataStore.proxyConfigurations = [configuration]
        } else {
            dataStore.proxyConfigurations = []
        }
        // Cached pages from the live web or another date must not be reused.
        await dataStore.removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: .distantPast
        )
    }

    /// Applies changed Wayback settings and reloads the current page in the
    /// newly selected time (or the present).
    private func travelToSelectedTime() async {
        await applyWaybackSettings()
        if let url = page.url {
            page.load(url)
        } else {
            loadHomePage()
        }
    }

    private func loadHomePage() {
        if let url = BrowserSettings.url(from: homePage) {
            page.load(url)
        }
    }

    /// Navigator-style status messages for the current loading state.
    private var statusMessage: String {
        let host = page.url?.host() ?? "host"
        if page.isLoading {
            if page.estimatedProgress < 0.1 {
                return "Connect: Contacting host \(host)..."
            }
            let percent = Int(page.estimatedProgress * 100)
            return "Transferring data from \(host)... (\(percent)%)"
        }
        return page.url == nil ? "" : "Document: Done"
    }

    /// Loads the typed address, adding a scheme if none was given.
    private func loadAddress() {
        if let url = BrowserSettings.url(from: address) {
            page.load(url)
        }
    }

    /// Bindings of the toolbars currently collapsed into the tray, in order.
    private var collapsedToolbars: [Binding<Bool>] {
        [$isNavigationToolbarCollapsed, $isLocationBarCollapsed].filter(\.wrappedValue)
    }

    private func collapse(_ isCollapsed: Binding<Bool>) {
        withAnimation(.easeInOut(duration: 0.15)) {
            isCollapsed.wrappedValue = true
        }
    }

    private func handle(_ action: NavigationToolbar.Action) {
        switch action {
        case .back:
            if let item = page.backForwardList.backList.last {
                page.load(item)
            }
        case .forward:
            if let item = page.backForwardList.forwardList.first {
                page.load(item)
            }
        case .reload:
            page.reload()
        case .home:
            loadHomePage()
        case .stop:
            page.stopLoading()
        case .print:
            printPage()
        }
    }

    /// Shows the standard print panel for the current page as a sheet on the
    /// browser window.
    private func printPage() {
        // `WebPage` has no printing API, but WebKit's own print operation
        // paginates properly, so use the WKWebView behind the SwiftUI WebView.
        guard let window = NSApp.windows.first(where: { $0.contentView?.firstDescendant(of: WKWebView.self) != nil }),
              let webView = window.contentView?.firstDescendant(of: WKWebView.self) else { return }

        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .spool

        let operation = webView.printOperation(with: printInfo)
        operation.jobTitle = page.title.isEmpty ? (page.url?.absoluteString ?? "Untitled") : page.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // Without a frame the operation's view prints blank pages.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

private extension NSView {
    /// The first view of the given type in this view's subtree.
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}

// MARK: - Platinum palette

/// Colors approximating the Mac OS 9 "Platinum" appearance.
enum Platinum {
    static let face = Color(white: 0.867)        // #DDDDDD window frame
    static let highlight = Color.white
    static let shadow = Color(white: 0.6)        // #999999
    static let darkShadow = Color(white: 0.4)    // #666666
    static let outline = Color.black
    static let stripe = Color(white: 0.6)
    static let titleBarHeight: CGFloat = 22
    static let sideBorder: CGFloat = 6
}

// MARK: - Classic window container

/// A window container that draws Mac OS 9 style chrome: a black outline,
/// beveled platinum frame, pinstriped title bar with close, zoom and
/// collapse (window shade) boxes.
struct ClassicWindow<Content: View>: View {
    let title: String
    /// Movable modal dialog style: no title bar boxes, no grow box, and the
    /// content sits directly on the platinum face.
    var isDialog = false
    @ViewBuilder var content: Content

    @Environment(\.appearsActive) private var appearsActive
    @State private var window: NSWindow?
    @State private var isCollapsed = false
    @State private var expandedFrame: NSRect?
    @State private var unzoomedFrame: NSRect?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if isDialog {
                content
            } else if !isCollapsed {
                content
                    // 1px outline around the content area. Scroll bars and the
                    // status bar share this edge, so there's no inner bevel.
                    .overlay(Rectangle().strokeBorder(Platinum.darkShadow, lineWidth: 1))
                    // Placed over the well's bottom/right edges so the grow box
                    // merges seamlessly with the platinum window frame.
                    .overlay(alignment: .bottomTrailing) {
                        GrowBox(window: window)
                    }
                    .padding([.horizontal, .bottom], Platinum.sideBorder - 1)
            }
        }
        .background(Platinum.face)
        .bevel(light: Platinum.highlight, dark: Platinum.shadow)
        .overlay(Rectangle().strokeBorder(Platinum.outline, lineWidth: 1))
        .frame(minWidth: 200, minHeight: Platinum.titleBarHeight)
        .background(WindowAccessor(window: $window))
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 0) {
            if appearsActive && !isDialog {
                ClassicBoxButton(glyph: .close, action: close)
                    .titleBarBoxWell()
            }
            stripes
                .overlay {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(appearsActive ? Color.black : Platinum.shadow)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .background(Platinum.face)
                }
            if appearsActive && !isDialog {
                ClassicBoxButton(glyph: .zoom, action: zoom)
                    .titleBarBoxWell()
                ClassicBoxButton(glyph: .collapse, action: toggleCollapse)
                    .titleBarBoxWell()
            }
        }
        .padding(.horizontal, 4)
        .frame(height: Platinum.titleBarHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) {
            if !isDialog {
                toggleCollapse()
            }
        }
    }

    /// Horizontal embossed pinstripes, only drawn while the window is active.
    private var stripes: some View {
        Canvas { context, size in
            guard appearsActive else { return }
            let grooves = 6
            let top = ((size.height - CGFloat(grooves * 2)) / 2).rounded()
            for index in 0..<grooves {
                let y = top + CGFloat(index * 2)
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(Platinum.stripe))
                context.fill(Path(CGRect(x: 0, y: y + 1, width: size.width, height: 1)),
                             with: .color(Platinum.highlight))
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Window actions

    private func close() {
        window?.close()
    }

    /// Toggles between the screen's visible frame and the previous frame.
    private func zoom() {
        guard let window, let screen = window.screen else { return }
        if let unzoomedFrame {
            window.setFrame(unzoomedFrame, display: true, animate: true)
            self.unzoomedFrame = nil
        } else {
            unzoomedFrame = window.frame
            window.setFrame(screen.visibleFrame, display: true, animate: true)
        }
    }

    /// Classic "window shade": rolls the window up into its title bar.
    private func toggleCollapse() {
        guard let window else {
            isCollapsed.toggle()
            return
        }
        if isCollapsed, let expandedFrame {
            isCollapsed = false
            // Keep the top edge anchored while restoring the height.
            var frame = expandedFrame
            frame.origin.y = window.frame.maxY - frame.height
            window.setFrame(frame, display: true, animate: true)
            self.expandedFrame = nil
        } else {
            expandedFrame = window.frame
            isCollapsed = true
            var frame = window.frame
            frame.origin.y = frame.maxY - Platinum.titleBarHeight
            frame.size.height = Platinum.titleBarHeight
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

// MARK: - Title bar boxes

private enum BoxGlyph {
    case close, zoom, collapse
}

/// A Platinum-style title bar box (close, zoom or collapse).
private struct ClassicBoxButton: View {
    let glyph: BoxGlyph
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(ClassicBoxButtonStyle(glyph: glyph))
    }
}

private struct ClassicBoxButtonStyle: ButtonStyle {
    let glyph: BoxGlyph

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        ZStack {
            // Beveled face: light top-left, dark bottom-right (inverted when pressed).
            LinearGradient(
                colors: pressed
                    ? [Platinum.darkShadow, Color(white: 0.75)]
                    : [Color(white: 0.97), Color(white: 0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .padding(1)

            glyphView
        }
        .frame(width: 13, height: 13)
        .overlay(Rectangle().strokeBorder(Platinum.darkShadow, lineWidth: 1))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .close:
            EmptyView()
        case .zoom:
            // Small square in the top-left corner, sharing the outer box's border.
            Rectangle()
                .strokeBorder(Platinum.darkShadow, lineWidth: 1)
                .frame(width: 7, height: 7)
                .frame(width: 13, height: 13, alignment: .topLeading)
        case .collapse:
            // Horizontal bar across the middle.
            VStack(spacing: 0) {
                Rectangle().fill(Platinum.darkShadow).frame(height: 1)
                Rectangle().fill(Platinum.highlight).frame(height: 1)
            }
            .frame(width: 11)
        }
    }
}

private extension View {
    /// Surrounds a title bar box with a recessed well that interrupts the pinstripes.
    func titleBarBoxWell() -> some View {
        self
            .bevel(light: Platinum.shadow, dark: Platinum.highlight, inset: -1)
            .padding(.horizontal, 3)
            .background(Platinum.face)
    }
}

// MARK: - Grow box

/// The Platinum size box in the bottom-right corner. Dragging it resizes
/// the window while keeping the top-left corner anchored.
private struct GrowBox: View {
    let window: NSWindow?

    @State private var startFrame: NSRect?
    @State private var startMouse: NSPoint?

    var body: some View {
        Canvas { context, size in
            // Three diagonal embossed ridges, like the OS 9 grow box.
            for offset in [4.0, 8.0, 12.0] {
                var dark = Path()
                dark.move(to: CGPoint(x: size.width - 2, y: size.height - 2 - offset))
                dark.addLine(to: CGPoint(x: size.width - 2 - offset, y: size.height - 2))
                context.stroke(dark, with: .color(Platinum.darkShadow), lineWidth: 1)

                var light = Path()
                light.move(to: CGPoint(x: size.width - 2, y: size.height - 1 - offset))
                light.addLine(to: CGPoint(x: size.width - 1 - offset, y: size.height - 2))
                context.stroke(light, with: .color(Platinum.highlight), lineWidth: 1)
            }
        }
        .frame(width: 15, height: 15)
        .background(Platinum.face)
        .overlay(alignment: .leading) {
            // Separator against the status bar. The top edge is provided by
            // the scroll bar corner directly above.
            Rectangle().fill(Platinum.darkShadow).frame(width: 1)
        }
        .contentShape(Rectangle())
        .gesture(resizeGesture)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard let window else { return }
                // Use screen coordinates: the box moves with the window while dragging.
                let mouse = NSEvent.mouseLocation
                if startFrame == nil {
                    startFrame = window.frame
                    startMouse = mouse
                }
                guard let startFrame, let startMouse else { return }
                let minSize = window.minSize
                let width = max(minSize.width, 200, startFrame.width + mouse.x - startMouse.x)
                let height = max(minSize.height, 100, startFrame.height - (mouse.y - startMouse.y))
                let frame = NSRect(x: startFrame.minX,
                                   y: startFrame.maxY - height,
                                   width: width,
                                   height: height)
                window.setFrame(frame, display: true)
            }
            .onEnded { _ in
                startFrame = nil
                startMouse = nil
            }
    }
}

// MARK: - Bevel

extension View {
    /// Draws a 1pt bevel: `light` along the top and left edges,
    /// `dark` along the bottom and right edges.
    func bevel(light: Color, dark: Color, inset: CGFloat = 1) -> some View {
        overlay {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)),
                             with: .color(light))
                context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)),
                             with: .color(light))
                context.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1)),
                             with: .color(dark))
                context.fill(Path(CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height)),
                             with: .color(dark))
            }
            .padding(min(inset, 0))
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Window access

/// Exposes the hosting `NSWindow` so the custom chrome can drive it.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            attach(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil {
            DispatchQueue.main.async {
                attach(nsView.window)
            }
        }
    }

    private func attach(_ nsWindow: NSWindow?) {
        guard let nsWindow, window !== nsWindow else { return }
        window = nsWindow
    }
}

#Preview {
    ContentView()
        .frame(width: 640, height: 480)
}
