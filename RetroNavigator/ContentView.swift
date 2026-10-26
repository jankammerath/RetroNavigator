//
//  ContentView.swift
//  RetroNavigator
//
//  Created by Jan Kammerath on 26.10.26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    var body: some View {
        ClassicWindow(title: "RetroNavigator") {
            VStack {
                Image(systemName: "globe")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Hello, world!")
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
    }
}

// MARK: - Platinum palette

/// Colors approximating the Mac OS 9 "Platinum" appearance.
private enum Platinum {
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
    @ViewBuilder var content: Content

    @Environment(\.appearsActive) private var appearsActive
    @State private var window: NSWindow?
    @State private var isCollapsed = false
    @State private var expandedFrame: NSRect?
    @State private var unzoomedFrame: NSRect?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if !isCollapsed {
                content
                    .overlay(alignment: .bottomTrailing) {
                        GrowBox(window: window)
                    }
                    // Inset well around the content area.
                    .overlay(Rectangle().strokeBorder(Platinum.darkShadow, lineWidth: 1))
                    .bevel(light: Platinum.shadow, dark: Platinum.highlight)
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
            if appearsActive {
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
            if appearsActive {
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
        .onTapGesture(count: 2, perform: toggleCollapse)
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
            // Small square nested in the top-left corner.
            Rectangle()
                .strokeBorder(Platinum.darkShadow, lineWidth: 1)
                .frame(width: 7, height: 7)
                .frame(width: 11, height: 11, alignment: .topLeading)
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
        .overlay {
            // Separator lines against the content area.
            ZStack(alignment: .topLeading) {
                Color.clear
                Rectangle().fill(Platinum.darkShadow).frame(width: 15, height: 1)
                Rectangle().fill(Platinum.darkShadow).frame(width: 1, height: 15)
            }
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

private extension View {
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
