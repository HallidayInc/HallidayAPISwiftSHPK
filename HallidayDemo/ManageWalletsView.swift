import SwiftUI

struct ManageWalletsView: View {
    @Environment(WalletStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var renaming: Wallet?
    @State private var draftName = ""
    @State private var confirmingReveal: Wallet?
    @State private var revealing: Wallet?
    @State private var deleting: Wallet?

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Manage wallets.")
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                    .padding(.bottom, 24)

                ScrollView {
                    VStack(spacing: 0) {
                        hairline
                        ForEach(store.wallets) { wallet in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(wallet.name).haffer(17)

                                // All three share one treatment, centred as a group.
                                HStack(spacing: 10) {
                                    action("Rename") {
                                        draftName = wallet.name
                                        renaming = wallet
                                    }
                                    action("View mnemonic") { confirmingReveal = wallet }
                                    action("Delete") { deleting = wallet }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 16)
                            hairline
                        }
                    }
                    .padding(.bottom, 12)
                }

                PillButton(title: "Close") { dismiss() }
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 20)
            .navBar(trailing: .close, onTrailing: { dismiss() })
        }
        .toasts()
        .fullScreenCover(item: $renaming) { wallet in
            ConfirmModal(
                title: "Rename wallet.",
                message: "Give this wallet a personalized display name.",
                confirmTitle: "Save",
                confirmDisabled: trimmedName.isEmpty,
                onConfirm: {
                    store.rename(wallet, to: trimmedName)
                    renaming = nil
                },
                onCancel: { renaming = nil }
            ) {
                CountedTextField(placeholder: "Wallet name", text: $draftName, limit: 30)
            }
        }
        .fullScreenCover(item: $confirmingReveal) { wallet in
            ConfirmModal(
                title: "View recovery phrase?",
                message: "Are you sure you want to view the wallet mnemonic? Keep it secured!",
                confirmTitle: "Show",
                onConfirm: {
                    confirmingReveal = nil
                    revealing = wallet
                },
                onCancel: { confirmingReveal = nil }
            )
        }
        .fullScreenCover(item: $deleting) { wallet in
            ConfirmModal(
                title: "Delete wallet?",
                message: "Are you sure you want to delete this wallet? Make sure you have it backed up! This action cannot be undone.",
                confirmTitle: "Delete",
                destructive: true,
                onConfirm: {
                    store.delete(wallet)
                    deleting = nil
                },
                onCancel: { deleting = nil }
            )
        }
        .fullScreenCover(item: $revealing) { wallet in
            ViewMnemonicView(wallet: wallet).environment(store)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }

    private func action(_ title: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .haffer(15)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color.card, in: .capsule)
        }
        .tint(.primary)
    }
}
