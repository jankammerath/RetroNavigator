//
//  ClassicControls.swift
//  RetroNavigator
//
//  Mac OS 8/9 Platinum dialog controls: text fields, checkboxes, pop-up
//  menus, push buttons and group boxes.
//

import SwiftUI

private let classicFont = Font.system(size: 12)

// MARK: - Text field

/// A white edit field with a sunken border; the border thickens when focused.
struct ClassicTextField: View {
    @Binding var text: String

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(classicFont)
            .foregroundStyle(Color.black)
            .focused($isFocused)
            .focusEffectDisabled()
            .padding(.horizontal, 4)
            .frame(height: 20)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(Color.black, lineWidth: isFocused ? 2 : 1))
            .padding(1)
            .bevel(light: Platinum.shadow, dark: Platinum.highlight, inset: 0)
    }
}

// MARK: - Checkbox

struct ClassicCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    LinearGradient(colors: [Color.white, Color(white: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Rectangle().strokeBorder(Color.black, lineWidth: 1)
                    if isOn {
                        // Check mark.
                        Path { path in
                            path.move(to: CGPoint(x: 3, y: 6))
                            path.addLine(to: CGPoint(x: 5.5, y: 9))
                            path.addLine(to: CGPoint(x: 10, y: 2.5))
                        }
                        .stroke(Color.black, style: StrokeStyle(lineWidth: 2, lineCap: .square))
                    }
                }
                .frame(width: 13, height: 13)
                Text(title)
                    .font(classicFont)
                    .foregroundStyle(Color.black)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pop-up menu

/// A Platinum pop-up menu button with the double-arrow box on the right.
struct ClassicPopUp<Value: Hashable>: View {
    struct Option: Hashable {
        let value: Value
        let label: String
    }

    let options: [Option]
    @Binding var selection: Value

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option.label) {
                    selection = option.value
                }
            }
        } label: {
            HStack(spacing: 0) {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .font(classicFont)
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                    .padding(.leading, 7)
                Spacer(minLength: 6)
                arrows
            }
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// The ⇕ arrows in their own box, separated by a vertical line.
    private var arrows: some View {
        Canvas { context, size in
            let x = size.width / 2
            var up = Path()
            up.move(to: CGPoint(x: x - 3.5, y: size.height / 2 - 2))
            up.addLine(to: CGPoint(x: x + 3.5, y: size.height / 2 - 2))
            up.addLine(to: CGPoint(x: x, y: size.height / 2 - 6))
            var down = Path()
            down.move(to: CGPoint(x: x - 3.5, y: size.height / 2 + 2))
            down.addLine(to: CGPoint(x: x + 3.5, y: size.height / 2 + 2))
            down.addLine(to: CGPoint(x: x, y: size.height / 2 + 6))
            context.fill(up, with: .color(.black))
            context.fill(down, with: .color(.black))
        }
        .frame(width: 18)
        .overlay(alignment: .leading) {
            Rectangle().fill(Platinum.darkShadow).frame(width: 1).padding(.vertical, 3)
        }
    }
}

// MARK: - Push button

/// A rounded Platinum push button. The default button gets the thick black
/// outer ring of classic Mac OS dialogs.
struct ClassicPushButtonStyle: ButtonStyle {
    var isDefault = false

    func makeBody(configuration: Configuration) -> some View {
        ClassicPushButton(configuration: configuration, isDefault: isDefault)
    }
}

private struct ClassicPushButton: View {
    let configuration: ButtonStyleConfiguration
    let isDefault: Bool

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(pressed ? Color.white : Color.black)
            .padding(.horizontal, 14)
            .frame(minWidth: 70, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(pressed
                          ? LinearGradient(colors: [Color(white: 0.35), Color(white: 0.55)], startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [Color.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black, lineWidth: 1))
            .padding(4)
            .overlay {
                if isDefault {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.black, lineWidth: 3)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

// MARK: - Group box

/// An etched rounded box with its title set into the top edge.
struct ClassicGroupBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Etched line: dark groove with a white highlight below-right.
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white, lineWidth: 1)
                        .offset(x: 1, y: 1)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Platinum.shadow, lineWidth: 1)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(classicFont)
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 4)
                    .background(Platinum.face)
                    .offset(x: 10, y: -8)
            }
            .padding(.top, 8)
    }
}
