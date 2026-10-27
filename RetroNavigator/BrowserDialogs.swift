//
//  BrowserDialogs.swift
//  RetroNavigator
//
//  JavaScript alert(), confirm() and prompt() as classic Mac OS dialogs.
//  WMLScript's Dialogs library uses these too.
//

import SwiftUI
import AppKit
import WebKit

struct BrowserDialogPresenter: WebPage.DialogPresenting {
    func handleJavaScriptAlert(message: String, initiatedBy frame: WebPage.FrameInfo) async {
        _ = await ClassicAlert.run(message: message, defaultText: nil, showsCancel: false)
    }

    func handleJavaScriptConfirm(message: String, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptConfirmResult {
        await ClassicAlert.run(message: message, defaultText: nil, showsCancel: true) == nil ? .cancel : .ok
    }

    func handleJavaScriptPrompt(message: String, defaultText: String?, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptPromptResult {
        if let text = await ClassicAlert.run(message: message, defaultText: defaultText ?? "", showsCancel: true) {
            return .ok(text)
        }
        return .cancel
    }
}

@MainActor
enum ClassicAlert {
    /// Shows a dialog and waits for it. Returns `nil` for Cancel, otherwise
    /// the entered text (empty without a text field).
    static func run(message: String, defaultText: String?, showsCancel: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            let state = CompletionState()
            ClassicDialog.present(title: "[JavaScript Application]") { close in
                ClassicAlertView(message: message, defaultText: defaultText, showsCancel: showsCancel) { result in
                    guard !state.isFinished else { return }
                    state.isFinished = true
                    close()
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private final class CompletionState {
        var isFinished = false
    }
}

private struct ClassicAlertView: View {
    let message: String
    let defaultText: String?
    let showsCancel: Bool
    let onFinish: (String?) -> Void

    @State private var text = ""

    var body: some View {
        ClassicWindow(title: "[JavaScript Application]", isDialog: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: NSImage(named: NSImage.cautionName) ?? NSImage())
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.black)
                            .fixedSize(horizontal: false, vertical: true)
                        if defaultText != nil {
                            ClassicTextField(text: $text)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Spacer()
                    if showsCancel {
                        Button("Cancel") { onFinish(nil) }
                            .buttonStyle(ClassicPushButtonStyle())
                            .keyboardShortcut(.cancelAction)
                    }
                    Button("OK") { onFinish(text) }
                        .buttonStyle(ClassicPushButtonStyle(isDefault: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .light)
        .onAppear { text = defaultText ?? "" }
    }
}
