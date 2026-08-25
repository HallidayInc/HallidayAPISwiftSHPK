import SwiftUI
import WalletCore

struct MnemonicGrid: View {
    @Binding var words: [String]
    var editable = true
    @FocusState.Binding var focused: Int?

    var body: some View {
        // Two columns read top to bottom: 1-6 on the left, 7-12 on the right.
        HStack(alignment: .top, spacing: 10) {
            column(0..<6)
            column(6..<12)
        }
    }

    private func column(_ range: Range<Int>) -> some View {
        VStack(spacing: 10) {
            ForEach(range, id: \.self) { index in
                field(index)
            }
        }
    }

    private func field(_ index: Int) -> some View {
        let word = index < words.count ? words[index] : ""
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .haffer(13, .regular)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            if editable && index < words.count {
                TextField("", text: $words[index])
                    .haffer(15, .regular)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused, equals: index)
                    .submitLabel(index == 11 ? .done : .next)
                    .onSubmit {
                        // Return walks the fields, and closes the keyboard on the last one.
                        focused = index == 11 ? nil : index + 1
                    }
                    .onChange(of: words[index]) { _, new in
                        let clean = new.lowercased().filter(\.isLetter)
                        if clean != new { words[index] = clean }
                    }
            } else {
                Text(word).haffer(15, .regular)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.card, in: .capsule)
        .overlay {
            // Flag a word that is not in the BIP39 list as soon as it is typed.
            if editable && !word.isEmpty && !Mnemonic.isValidWord(word: word) {
                Capsule().strokeBorder(.red.opacity(0.7), lineWidth: 1)
            }
        }
    }
}

struct ImportWalletView: View {
    @Environment(WalletStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var words = Array(repeating: "", count: 12)
    @FocusState private var focused: Int?

    private var phrase: String {
        words.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    // Checks the BIP39 checksum, not just that twelve boxes are filled.
    private var isValid: Bool {
        words.allSatisfy { !$0.isEmpty } && Mnemonic.isValid(mnemonic: phrase)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Import a wallet from a mnemonic.")
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)

                ScrollView {
                    MnemonicGrid(words: $words, focused: $focused)
                        .padding(.bottom, 12)
                        // Taps on the padding around the fields land here, not on the fields.
                        .contentShape(Rectangle())
                        .onTapGesture { focused = nil }
                }
                .scrollDismissesKeyboard(.interactively)

                if words.allSatisfy({ !$0.isEmpty }) && !isValid {
                    Text("That phrase is not a valid 12 word mnemonic.")
                        .haffer(13, .regular)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }

                PillButton(title: "Paste mnemonic") { paste() }
                    .padding(.bottom, 10)

                PillButton(title: "Import", disabled: !isValid) {
                    if store.add(mnemonic: phrase) {
                        dismiss()
                    } else {
                        Toast.shared.show("Could not import that mnemonic.")
                    }
                }
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 20)
            // Tapping anywhere off the fields puts the keyboard away.
            .contentShape(Rectangle())
            .onTapGesture { focused = nil }
            // Let the keyboard cover the buttons rather than shoving the layout upward.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navBar(trailing: .close, onTrailing: { dismiss() })
        }
        .toasts()
    }

    private func paste() {
        let clipboard = UIPasteboard.general.string ?? ""
        // Any run of whitespace separates words, so newlines and tabs paste cleanly too.
        let parts = clipboard.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !parts.isEmpty else {
            Toast.shared.show("Clipboard is empty.")
            return
        }
        words = (0..<12).map { $0 < parts.count ? parts[$0] : "" }
        focused = nil
    }
}

struct ViewMnemonicView: View {
    @Environment(\.dismiss) private var dismiss
    let wallet: Wallet
    @FocusState private var focused: Int?

    // Computed, not @State filled in onAppear: the body renders first, and indexing an
    // empty array in the grid crashed before onAppear ever ran.
    private var words: [String] {
        let parts = wallet.mnemonic.split(separator: " ").map(String.init)
        return (0..<12).map { $0 < parts.count ? parts[$0] : "" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("\(wallet.name) recovery phrase.")
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                Text("Anyone with these words controls this wallet.")
                    .haffer(15, .regular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.bottom, 24)

                ScrollView {
                    MnemonicGrid(words: .constant(words), editable: false, focused: $focused)
                        .padding(.bottom, 12)
                }

                PillButton(title: "Copy to clipboard") {
                    Toast.copy(wallet.mnemonic, label: "Recovery phrase")
                }
                .padding(.bottom, 10)

                PillButton(title: "Close") { dismiss() }
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 20)
            .navBar(trailing: .close, onTrailing: { dismiss() })
        }
        .toasts()
    }
}
