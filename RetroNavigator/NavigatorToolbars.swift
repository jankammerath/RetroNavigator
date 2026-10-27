//
//  NavigatorToolbars.swift
//  RetroNavigator
//
//  Netscape Navigator 4 style toolbars: the navigation toolbar and the
//  location bar, each collapsible via a tab on its left edge.
//

import SwiftUI
import AppKit

/// Loads one of the bundled toolbar images from the Content folder.
private func navigatorImage(_ name: String) -> NSImage {
    NSImage(named: name) ?? NSImage()
}

// MARK: - Collapsible panes

/// An expanded toolbar with a Navigator 4 collapse tab along its left edge.
struct ToolbarPane<Content: View>: View {
    let onCollapse: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            CollapseTab(orientation: .vertical, action: onCollapse)
                .frame(width: 11)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Platinum.face)
        .bevel(light: Platinum.highlight, dark: Platinum.shadow, inset: 0)
    }
}

/// A thin strip holding the horizontal tabs of collapsed toolbars,
/// side by side as in Navigator 4. Clicking a tab expands its toolbar.
struct CollapsedToolbarTray: View {
    let tabs: [Binding<Bool>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs.indices, id: \.self) { index in
                CollapseTab(orientation: .horizontal) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        tabs[index].wrappedValue = false
                    }
                }
                .frame(width: 44, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(Platinum.face)
        .bevel(light: Platinum.highlight, dark: Platinum.shadow, inset: 0)
    }
}

/// The raised, dotted grip tab with a disclosure triangle.
private struct CollapseTab: View {
    enum Orientation {
        /// Along the left edge of an expanded toolbar; triangle points down.
        case vertical
        /// In the collapsed tray; triangle points right.
        case horizontal
    }

    let orientation: Orientation
    let action: () -> Void

    var body: some View {
        Canvas { context, size in
            let dark = GraphicsContext.Shading.color(Platinum.darkShadow)
            let light = GraphicsContext.Shading.color(Platinum.highlight)

            // Disclosure triangle.
            var triangle = Path()
            switch orientation {
            case .vertical:
                let x = (size.width - 5) / 2
                triangle.move(to: CGPoint(x: x, y: 4))
                triangle.addLine(to: CGPoint(x: x + 5, y: 4))
                triangle.addLine(to: CGPoint(x: x + 2.5, y: 7))
            case .horizontal:
                let y = (size.height - 5) / 2
                triangle.move(to: CGPoint(x: 4, y: y))
                triangle.addLine(to: CGPoint(x: 7, y: y + 2.5))
                triangle.addLine(to: CGPoint(x: 4, y: y + 5))
            }
            triangle.closeSubpath()
            context.fill(triangle, with: dark)

            // Embossed dot texture: dark pixel with a white pixel below-right.
            func dot(_ x: CGFloat, _ y: CGFloat) {
                context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: dark)
                context.fill(Path(CGRect(x: x + 1, y: y + 1, width: 1, height: 1)), with: light)
            }
            switch orientation {
            case .vertical:
                for y in stride(from: 11.0, through: size.height - 5, by: 3) {
                    dot(3, y)
                    dot(6, y + 1.5)
                }
            case .horizontal:
                for x in stride(from: 11.0, through: size.width - 5, by: 3) {
                    dot(x, 2)
                    dot(x + 1.5, 5)
                }
            }
        }
        .background(Platinum.face)
        .bevel(light: Platinum.highlight, dark: Platinum.shadow, inset: 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: - Navigation toolbar

/// The main button bar: Back, Forward, Reload, Home, Print, Stop and the
/// animated Netscape throbber on the far right.
struct NavigationToolbar: View {
    enum Action {
        case back, forward, reload, home, print, stop
    }

    let isLoading: Bool
    let onAction: (Action) -> Void

    var body: some View {
        HStack(spacing: 2) {
            NavigatorButton(title: "Back", imageName: "icon_back") { onAction(.back) }
            NavigatorButton(title: "Forward", imageName: "icon_forward") { onAction(.forward) }
            NavigatorButton(title: "Reload", imageName: "icon_reload") { onAction(.reload) }
            NavigatorButton(title: "Home", imageName: "icon_home") { onAction(.home) }
            NavigatorButton(title: "Print", imageName: "icon_print") { onAction(.print) }
            NavigatorButton(title: "Stop", imageName: "icon_stop") { onAction(.stop) }
                .disabled(!isLoading)
            Spacer(minLength: 8)
            Throbber(isAnimating: isLoading)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
    }
}

/// A Navigator 4 toolbar button: icon above a small label, flat until
/// hovered (raised bevel) or pressed (sunken bevel).
private struct NavigatorButton: View {
    let title: String
    let imageName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(nsImage: navigatorImage(imageName))
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.black)
            }
            .frame(minWidth: 40)
        }
        .buttonStyle(NavigatorButtonStyle())
    }
}

private struct NavigatorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NavigatorButtonBody(configuration: configuration)
    }
}

private struct NavigatorButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .offset(x: pressed ? 1 : 0, y: pressed ? 1 : 0)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(pressed ? Color(white: 0.78) : Color.clear)
            .overlay {
                if isEnabled && (isHovered || pressed) {
                    Color.clear.bevel(
                        light: pressed ? Platinum.darkShadow : Platinum.highlight,
                        dark: pressed ? Platinum.highlight : Platinum.darkShadow,
                        inset: 0
                    )
                }
            }
            // Disabled buttons look greyed out, as in Navigator.
            .saturation(isEnabled ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// The Netscape "N" throbber in a sunken frame; animates while loading.
private struct Throbber: View {
    let isAnimating: Bool

    var body: some View {
        AnimatedGIFView(resourceName: "Loading", isAnimating: isAnimating)
            .frame(width: 40, height: 40)
            .padding(1)
            .background(Color.black)
            .padding(1)
            .bevel(light: Platinum.shadow, dark: Platinum.highlight, inset: 0)
    }
}

/// Displays an animated GIF from the app bundle using `NSImageView`,
/// which plays GIF animations natively.
private struct AnimatedGIFView: NSViewRepresentable {
    let resourceName: String
    let isAnimating: Bool

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = Bundle.main.url(forResource: resourceName, withExtension: "gif")
            .flatMap { NSImage(contentsOf: $0) }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.canDrawSubviewsIntoLayer = true
        // Let SwiftUI size the view instead of the GIF's 200×200 intrinsic size.
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.animates = isAnimating
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        imageView.animates = isAnimating
    }
}

// MARK: - Location bar

/// The "Location:" bar with the page proxy icon and the address field.
struct LocationBar: View {
    @Binding var address: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("Location:")
                .font(.system(size: 10))
                .foregroundStyle(Color.black)
            Image(nsImage: navigatorImage("icon_address"))
                .resizable()
                .frame(width: 18, height: 18)
            TextField("", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 3)
                .frame(height: 18)
                .background(Color.white)
                // Sunken Platinum edit field border.
                .overlay(Rectangle().strokeBorder(Color.black, lineWidth: 1))
                .padding(1)
                .bevel(light: Platinum.shadow, dark: Platinum.highlight, inset: 0)
                .onSubmit(onSubmit)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
    }
}

// MARK: - Status bar

/// The Navigator status bar: status message on the left, loading progress
/// on the right. The right end is left free for the window's grow box.
struct StatusBar: View {
    static let height: CGFloat = 15

    let message: String
    /// Loading progress from 0 to 1, or `nil` when idle (empty bar).
    let progress: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(Color.black)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            ClassicProgressBar(progress: progress)
                .frame(width: 160, height: 10)
            // Space for the grow box overlaid by the window.
            Color.clear
                .frame(width: ClassicScrollBar.thickness)
        }
        .padding(.leading, 6)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(DitherPattern())
        .bevel(light: Platinum.highlight, dark: Platinum.shadow, inset: 0)
    }
}

/// The 50% dithered platinum fill used behind the status bar.
private struct DitherPattern: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Platinum.face))
            let dot = GraphicsContext.Shading.color(Color(white: 0.8))
            var path = Path()
            for y in stride(from: 0, to: size.height, by: 1) {
                let start = Int(y) % 2 == 0 ? 0.0 : 1.0
                for x in stride(from: start, to: size.width, by: 2) {
                    path.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            context.fill(path, with: dot)
        }
    }
}

/// A sunken Platinum progress bar with a lavender fill.
struct ClassicProgressBar: View {
    let progress: Double?

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(max(progress ?? 0, 0), 1)
            ZStack(alignment: .leading) {
                Color(white: 0.93)
                Rectangle()
                    .fill(Color(red: 0.4, green: 0.4, blue: 0.8))
                    .overlay(alignment: .top) {
                        // Highlight line gives the fill a slightly raised look.
                        Rectangle().fill(Color(red: 0.7, green: 0.7, blue: 1.0)).frame(height: 1)
                    }
                    .frame(width: (proxy.size.width - 2) * fraction)
                    .padding(1)
            }
        }
        .overlay(Rectangle().strokeBorder(Platinum.darkShadow, lineWidth: 1))
        .padding(1)
        .bevel(light: Platinum.shadow, dark: Platinum.highlight, inset: 0)
        .animation(.linear(duration: 0.15), value: progress)
    }
}

#Preview("Toolbars") {
    VStack(spacing: 0) {
        ToolbarPane(onCollapse: {}) {
            NavigationToolbar(isLoading: true) { _ in }
        }
        ToolbarPane(onCollapse: {}) {
            LocationBar(address: .constant("http://home.netscape.com/")) {}
        }
        CollapsedToolbarTray(tabs: [.constant(true), .constant(true)])
        Color.white.frame(height: 40)
        StatusBar(message: "Document: Done", progress: 0.6)
    }
    .frame(width: 640)
    .environment(\.colorScheme, .light)
}
