import SwiftUI

// A single-line field with a live character count and a clear button.
struct CountedTextField: View {
    let placeholder: String
    @Binding var text: String
    var limit: Int

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .haffer(17, .regular)
                .autocorrectionDisabled()
                .onChange(of: text) { _, new in
                    if new.count > limit { text = String(new.prefix(limit)) }
                }
            Text("\(text.count)/\(limit)")
                .haffer(13, .regular)
                .foregroundStyle(.secondary)
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
            }
            .tint(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color.card, in: .capsule)
    }
}

// Confirmations use the same shape as every other modal in the app: headline, subtext,
// optional input, then full-width pills.
struct ConfirmModal<Content: View>: View {
    let title: String
    let message: String
    var confirmTitle: String
    var confirmDisabled = false
    var destructive = false
    var secondaryTitle: String?
    var onSecondary: (() -> Void)?
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(title)
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                Text(message)
                    .haffer(15, .regular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)

                content()
                    .padding(.top, 28)

                // Buttons hug the copy rather than sitting at the bottom of the screen.
                VStack(spacing: 10) {
                    PillButton(title: confirmTitle, disabled: confirmDisabled, action: onConfirm)

                    if let secondaryTitle, let onSecondary {
                        PillButton(title: secondaryTitle, action: onSecondary)
                    }

                    PillButton(title: "Cancel", action: onCancel)
                }
                .padding(.top, 36)

                Spacer()
            }
            .padding(.horizontal, 20)
            // Tapping anywhere off the field puts the keyboard away.
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navBar(trailing: .close, onTrailing: onCancel)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}

extension ConfirmModal where Content == EmptyView {
    init(
        title: String,
        message: String,
        confirmTitle: String,
        destructive: Bool = false,
        secondaryTitle: String? = nil,
        onSecondary: (() -> Void)? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.init(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            confirmDisabled: false,
            destructive: destructive,
            secondaryTitle: secondaryTitle,
            onSecondary: onSecondary,
            onConfirm: onConfirm,
            onCancel: onCancel,
            content: { EmptyView() }
        )
    }
}
