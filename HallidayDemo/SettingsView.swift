import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("showAllTokens") private var showAllTokens = false
    @State private var addingWallet = false
    @State private var importing = false
    @State private var managing = false
    @Environment(WalletStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let toast = Toast.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    NavButton(glyph: .close) { dismiss() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Text("Settings.")
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    header("Appearance")
                    appearancePicker
                        .padding(.bottom, 20)

                    header("Wallets")
                    card {
                        ForEach(store.wallets) { wallet in
                            Button {
                                store.selectedID = wallet.id
                            } label: {
                                HStack {
                                    Text(wallet.name).haffer(16, .regular)
                                    Spacer()
                                    if wallet.id == store.selectedID {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Color.crtGlyph)
                                    }
                                }
                                .padding(16)
                            }
                            .tint(.primary)
                            divider
                        }

                        Button {
                            addingWallet = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.crtGlyph)
                                Text("Add wallet").haffer(16, .regular)
                                Spacer()
                            }
                            .padding(16)
                        }
                        .tint(.primary)

                        divider

                        Button {
                            managing = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.crtGlyph)
                                Text("Manage wallets").haffer(16, .regular)
                                Spacer()
                            }
                            .padding(16)
                        }
                        .tint(.primary)
                    }
                    .padding(.bottom, 20)

                    if let wallet = store.selected {
                        header("Addresses")
                        card {
                            ForEach(Array(ChainFamily.allCases.enumerated()), id: \.element) { index, family in
                                Button {
                                    Toast.copy(wallet.address(family), label: "\(family.rawValue) address")
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(family.rawValue)
                                            .haffer(12, .regular)
                                            .foregroundStyle(.secondary)
                                        Text(wallet.address(family))
                                            .haffer(14, .regular)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                }
                                .tint(.primary)
                                if index < ChainFamily.allCases.count - 1 { divider }
                            }
                        }
                        .padding(.bottom, 20)
                    }

                    header("Tokens")
                    card {
                        // Reads as the state it is in, so the switch is on by default and
                        // the label never changes under the user's finger.
                        Toggle(isOn: Binding(get: { !showAllTokens }, set: { showAllTokens = !$0 })) {
                            Text("Show supported tokens only")
                                .haffer(16, .regular)
                        }
                        .tint(Color.crtGreen)
                        .padding(16)
                    }
                    .padding(.bottom, 20)

                    header("Errors")
                    card {
                        if toast.history.isEmpty {
                            Text("No errors yet.")
                                .haffer(15, .regular)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                        ForEach(Array(toast.history.enumerated()), id: \.element.id) { index, error in
                            Button {
                                Toast.copy(error.message, label: "Error")
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(error.date, format: .dateTime.hour().minute().second())
                                        .haffer(12, .regular)
                                        .foregroundStyle(.secondary)
                                    Text(error.message)
                                        .haffer(14, .regular)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                            }
                            .tint(.primary)
                            if index < toast.history.count - 1 { divider }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                }
            }
            .background(Color(.systemBackground))
            .toasts()
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(appearance.resolved)
        .fullScreenCover(isPresented: $addingWallet) {
            ConfirmModal(
                title: "Add a wallet.",
                message: "Would you like to import a wallet from a mnemonic or generate a new wallet automatically?",
                confirmTitle: "Mnemonic",
                secondaryTitle: "Auto-generate",
                onSecondary: {
                    store.add()
                    addingWallet = false
                },
                onConfirm: {
                    addingWallet = false
                    importing = true
                },
                onCancel: { addingWallet = false }
            )
        }
        .fullScreenCover(isPresented: $importing) {
            ImportWalletView().environment(store)
        }
        .fullScreenCover(isPresented: $managing) {
            ManageWalletsView().environment(store)
        }
    }

    private var appearancePicker: some View {
        HStack(spacing: 0) {
            ForEach(Appearance.allCases) { option in
                Button {
                    appearance = option
                } label: {
                    Text(option.label)
                        .haffer(15, .regular)
                        .foregroundStyle(appearance == option ? Color(.systemBackground) : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        // Selected pill inverts against the page, per the spec.
                        .background { if appearance == option { Capsule().fill(Color.primary) } }
                }
                .tint(.primary)
            }
        }
        .padding(4)
        .background(Color.card, in: .capsule)
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .haffer(12, .regular)
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .background(Color.surface, in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.hairline, lineWidth: 1) }
    }
}
