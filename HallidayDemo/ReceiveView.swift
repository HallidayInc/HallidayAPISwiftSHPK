import SwiftUI

struct ReceiveView: View {
    @Environment(AssetStore.self) private var assets
    @Environment(\.dismiss) private var dismiss
    let wallet: Wallet
    @State private var chain: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PickerTitle("Select a network")

                Text("Network to receive a token in your wallet.")
                    .haffer(15, .regular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                List(assets.chains.keys.sorted(), id: \.self) { name in
                    Button {
                        chain = name
                    } label: {
                        HStack(spacing: 12) {
                            TokenIcon(url: assets.chains[name]?.image)
                            Text(name.capitalized).haffer(16)
                            Spacer()
                        }
                    }
                    .tint(.primary)
                }
                .listStyle(.plain)
            }
            .navBar(trailing: .close, onTrailing: { dismiss() })
            .navigationDestination(item: $chain) { name in
                ReceiveAddressView(wallet: wallet, chain: name)
                    .navBar(
                        leading: .back,
                        onLeading: { chain = nil },
                        trailing: .close,
                        onTrailing: { dismiss() }
                    )
                    .navigationBarBackButtonHidden()
            }
        }
        .toasts()
    }
}

struct ReceiveAddressView: View {
    @Environment(AssetStore.self) private var assets
    let wallet: Wallet
    let chain: String

    // Concatenated so the network name can carry Haffer Medium; only Regular and Medium are
    // installed, so .bold() would synthesise a weight.
    private var notice: Text {
        let regular = Theme.font(15, .regular)
        let medium = Theme.font(15, .medium)
        return Text("Receive tokens in your wallet on ").font(regular)
            + Text(chain.capitalized).font(medium)
            + Text(". Tokens sent on the wrong network may not be able to be recovered.").font(regular)
    }

    private var address: String {
        wallet.address(assets.family(chain) ?? .evm)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Receive tokens in your wallet.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            notice
                .tracking(Theme.tracking(15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            QRCard(address: address, chain: chain)
                .padding(.top, 24)

            Text(address)
                .haffer(13, .regular)
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            PillButton(title: "Copy address") {
                Toast.copy(address, label: "Address")
            }
            .padding(.top, 16)

            Spacer()
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
    }
}
