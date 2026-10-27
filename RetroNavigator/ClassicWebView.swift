//
//  ClassicWebView.swift
//  RetroNavigator
//
//  A WebKit view framed by Mac OS 8/9 Platinum scroll bars instead of the
//  modern system scrollers.
//

import SwiftUI
import WebKit

// MARK: - Web view with classic scroll bars

/// Shows a `WebPage` with Platinum scroll bars on the right and bottom.
struct ClassicWebView: View {
    let page: WebPage

    /// The parts of `ScrollGeometry` the scroll bars need, in a `Hashable`
    /// form as required by `webViewOnScrollGeometryChange`.
    private struct ScrollMetrics: Hashable {
        var offsetX: CGFloat
        var offsetY: CGFloat
        var contentWidth: CGFloat
        var contentHeight: CGFloat
        var containerWidth: CGFloat
        var containerHeight: CGFloat

        init(_ geometry: ScrollGeometry) {
            offsetX = geometry.contentOffset.x
            offsetY = geometry.contentOffset.y
            contentWidth = geometry.contentSize.width
            contentHeight = geometry.contentSize.height
            containerWidth = geometry.containerSize.width
            containerHeight = geometry.containerSize.height
        }
    }

    @State private var metrics: ScrollMetrics?
    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        // Negative spacing makes adjacent 1px borders overlap into single lines.
        HStack(spacing: -1) {
            VStack(spacing: 0) {
                WebView(page)
                    .scrollIndicators(.hidden)
                    .webViewScrollPosition($scrollPosition)
                    .webViewOnScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init) { _, newValue in
                        metrics = newValue
                    }
                ClassicScrollBar(
                    axis: .horizontal,
                    offset: metrics?.offsetX ?? 0,
                    contentLength: metrics?.contentWidth ?? 0,
                    visibleLength: metrics?.containerWidth ?? 0,
                    onScrollTo: { scroll(.horizontal, to: $0) },
                    onScrollBy: { scroll(.horizontal, by: $0) }
                )
            }
            VStack(spacing: -1) {
                ClassicScrollBar(
                    axis: .vertical,
                    offset: metrics?.offsetY ?? 0,
                    contentLength: metrics?.contentHeight ?? 0,
                    visibleLength: metrics?.containerHeight ?? 0,
                    onScrollTo: { scroll(.vertical, to: $0) },
                    onScrollBy: { scroll(.vertical, by: $0) }
                )
                // Empty platinum corner where the two scroll bars meet.
                Platinum.face
                    .frame(width: ClassicScrollBar.thickness, height: ClassicScrollBar.thickness)
                    .overlay(Rectangle().strokeBorder(Platinum.darkShadow, lineWidth: 1))
            }
        }
    }

    // These read `metrics` when called (not when the closure was created),
    // so auto-repeating arrow buttons always step from the current offset.

    private func scroll(_ axis: Axis, by delta: CGFloat) {
        guard let metrics else { return }
        scroll(axis, to: (axis == .vertical ? metrics.offsetY : metrics.offsetX) + delta)
    }

    private func scroll(_ axis: Axis, to value: CGFloat) {
        guard let metrics else { return }
        switch axis {
        case .vertical:
            let maxY = max(0, metrics.contentHeight - metrics.containerHeight)
            scrollPosition.scrollTo(point: CGPoint(x: metrics.offsetX, y: min(max(value, 0), maxY)))
        case .horizontal:
            let maxX = max(0, metrics.contentWidth - metrics.containerWidth)
            scrollPosition.scrollTo(point: CGPoint(x: min(max(value, 0), maxX), y: metrics.offsetY))
        }
    }
}

extension WebPage {
    /// Creates the browser's page: native scroll bars are hidden with a user
    /// stylesheet so only the Platinum scroll bars are visible, and the
    /// Wayback navigation decider is attached.
    static func makeBrowserPage() -> WebPage {
        var configuration = WebPage.Configuration()
        // The Wayback proxy is configured on the default data store.
        configuration.websiteDataStore = .default()
        // Silent http → https upgrades would bypass the Wayback proxy, which
        // only serves plain http. Live sites still redirect to https themselves.
        configuration.upgradeKnownHostsToHTTPS = false
        let css = """
        html::-webkit-scrollbar, body::-webkit-scrollbar { display: none; width: 0; height: 0; }
        html { scrollbar-width: none; }
        """
        let source = """
        (function() {
            var style = document.createElement('style');
            style.textContent = `\(css)`;
            (document.head || document.documentElement).appendChild(style);
        })();
        """
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(script)

        return WebPage(configuration: configuration, navigationDecider: WaybackNavigationDecider())
    }
}

// MARK: - Scroll bar

/// A Platinum scroll bar: sunken track, square lavender thumb, and both
/// arrow buttons together at the end, as in Mac OS 8/9.
struct ClassicScrollBar: View {
    static let thickness: CGFloat = 15

    let axis: Axis
    /// Current scroll offset along `axis`.
    let offset: CGFloat
    let contentLength: CGFloat
    let visibleLength: CGFloat
    /// Scrolls to an absolute offset (clamped by the receiver).
    let onScrollTo: (CGFloat) -> Void
    /// Scrolls relative to the current offset.
    let onScrollBy: (CGFloat) -> Void

    @State private var dragStartOffset: CGFloat?

    private var maxOffset: CGFloat { max(0, contentLength - visibleLength) }
    private var isScrollable: Bool { maxOffset > 0.5 }
    private var lineStep: CGFloat { 40 }
    private var pageStep: CGFloat { max(visibleLength - lineStep, lineStep) }

    var body: some View {
        let stack = axis == .vertical
            ? AnyLayout(VStackLayout(spacing: -1))
            : AnyLayout(HStackLayout(spacing: -1))
        stack {
            track
            ScrollArrowButton(direction: axis == .vertical ? .up : .left, isEnabled: isScrollable) {
                onScrollBy(-lineStep)
            }
            ScrollArrowButton(direction: axis == .vertical ? .down : .right, isEnabled: isScrollable) {
                onScrollBy(lineStep)
            }
        }
        .frame(
            width: axis == .vertical ? Self.thickness : nil,
            height: axis == .horizontal ? Self.thickness : nil
        )
    }

    private var track: some View {
        GeometryReader { proxy in
            let length = axis == .vertical ? proxy.size.height : proxy.size.width
            let travel = max(0, length - Self.thickness)
            let fraction = maxOffset > 0 ? min(max(offset / maxOffset, 0), 1) : 0
            let position = travel * fraction

            ZStack(alignment: .topLeading) {
                // Active tracks are a darker sunken grey; inactive ones are plain.
                (isScrollable ? Color(white: 0.75) : Platinum.face)
                if isScrollable {
                    Color.clear.bevel(light: Platinum.shadow, dark: Platinum.highlight)
                    ScrollThumb(axis: axis)
                        .frame(width: Self.thickness, height: Self.thickness)
                        .offset(
                            x: axis == .horizontal ? position : 0,
                            y: axis == .vertical ? position : 0
                        )
                        .gesture(thumbDrag(travel: travel))
                }
            }
            .overlay(Rectangle().strokeBorder(Platinum.darkShadow, lineWidth: 1))
            .contentShape(Rectangle())
            // Clicking the track pages towards the click, like classic Mac OS.
            .onTapGesture { location in
                guard isScrollable else { return }
                let point = axis == .vertical ? location.y : location.x
                onScrollBy(point < position ? -pageStep : pageStep)
            }
        }
    }

    private func thumbDrag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = offset
                }
                guard travel > 0, let start = dragStartOffset else { return }
                let delta = axis == .vertical ? value.translation.height : value.translation.width
                onScrollTo(start + delta * maxOffset / travel)
            }
            .onEnded { _ in
                dragStartOffset = nil
            }
    }
}

/// The square Platinum thumb with embossed grip ridges.
private struct ScrollThumb: View {
    let axis: Axis

    var body: some View {
        Canvas { context, size in
            // Four grip ridges across the thumb, perpendicular to the scroll axis.
            let dark = GraphicsContext.Shading.color(Color(red: 0.4, green: 0.4, blue: 0.6))
            let light = GraphicsContext.Shading.color(Platinum.highlight)
            for index in 0..<4 {
                let step = CGFloat(index * 2)
                switch axis {
                case .vertical:
                    let y = size.height / 2 - 4 + step
                    context.fill(Path(CGRect(x: 4, y: y, width: size.width - 8, height: 1)), with: dark)
                    context.fill(Path(CGRect(x: 5, y: y + 1, width: size.width - 8, height: 1)), with: light)
                case .horizontal:
                    let x = size.width / 2 - 4 + step
                    context.fill(Path(CGRect(x: x, y: 4, width: 1, height: size.height - 8)), with: dark)
                    context.fill(Path(CGRect(x: x + 1, y: 5, width: 1, height: size.height - 8)), with: light)
                }
            }
        }
        .background(Color(red: 0.8, green: 0.8, blue: 1.0))
        .bevel(light: Platinum.highlight, dark: Color(red: 0.5, green: 0.5, blue: 0.7))
        .overlay(Rectangle().strokeBorder(Platinum.darkShadow, lineWidth: 1))
    }
}

/// A scroll arrow button that repeats while held down.
private struct ScrollArrowButton: View {
    enum Direction {
        case up, down, left, right
    }

    let direction: Direction
    let isEnabled: Bool
    let onStep: () -> Void

    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var triangle = Path()
            switch direction {
            case .up:
                triangle.move(to: CGPoint(x: center.x - 3.5, y: center.y + 2))
                triangle.addLine(to: CGPoint(x: center.x + 3.5, y: center.y + 2))
                triangle.addLine(to: CGPoint(x: center.x, y: center.y - 2))
            case .down:
                triangle.move(to: CGPoint(x: center.x - 3.5, y: center.y - 2))
                triangle.addLine(to: CGPoint(x: center.x + 3.5, y: center.y - 2))
                triangle.addLine(to: CGPoint(x: center.x, y: center.y + 2))
            case .left:
                triangle.move(to: CGPoint(x: center.x + 2, y: center.y - 3.5))
                triangle.addLine(to: CGPoint(x: center.x + 2, y: center.y + 3.5))
                triangle.addLine(to: CGPoint(x: center.x - 2, y: center.y))
            case .right:
                triangle.move(to: CGPoint(x: center.x - 2, y: center.y - 3.5))
                triangle.addLine(to: CGPoint(x: center.x - 2, y: center.y + 3.5))
                triangle.addLine(to: CGPoint(x: center.x + 2, y: center.y))
            }
            triangle.closeSubpath()
            context.fill(triangle, with: .color(isEnabled ? .black : Platinum.shadow))
        }
        .frame(width: ClassicScrollBar.thickness, height: ClassicScrollBar.thickness)
        .background(isPressed ? Platinum.shadow : Platinum.face)
        .bevel(
            light: isPressed ? Platinum.darkShadow : Platinum.highlight,
            dark: isPressed ? Platinum.highlight : Platinum.shadow
        )
        .overlay(Rectangle().strokeBorder(Platinum.darkShadow, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startRepeating() }
                .onEnded { _ in stopRepeating() }
        )
        .onDisappear(perform: stopRepeating)
    }

    /// Steps once immediately, then auto-repeats after a short delay.
    private func startRepeating() {
        guard isEnabled, !isPressed else { return }
        isPressed = true
        onStep()
        repeatTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            while !Task.isCancelled {
                onStep()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopRepeating() {
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}
