import SwiftUI

struct SelectorButton: View {
    @Environment(AssetStore.self) private var assets
    let placeholder: String
    var symbol: String?
    var chain: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let chain {
                    ChainBadge(chain: chain, size: 22)
                } else if let symbol, let group = assets.groups.first(where: { $0.symbol == symbol }) {
                    TokenIcon(url: group.imageURL, size: 22)
                }
                Text(symbol ?? chain?.capitalized ?? placeholder)
                    .haffer(18, .regular)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color.card, in: .capsule)
        }
        .tint(.primary)
    }
}

struct DepositBuilderView: View {
    @Bindable var flow: DepositFlow

    var body: some View {
        VStack(spacing: 0) {
            Text("Deposit tokens to your wallet.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("Send").haffer(18, .regular)
                    SelectorButton(placeholder: "Select token", symbol: flow.inputGroup?.symbol) {
                        flow.go(.sendToken)
                    }
                }
                HStack(spacing: 12) {
                    Text("on").haffer(18, .regular)
                    SelectorButton(placeholder: "Select network", chain: flow.input?.chain) {
                        flow.go(flow.inputGroup == nil ? .sendToken : .sendNetwork)
                    }
                }
                Text("from an external wallet or exchange account.")
                    .haffer(17, .regular)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Rectangle()
                .fill(Color.hairline)
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .padding(.vertical, 28)

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("Receive").haffer(18, .regular)
                    SelectorButton(placeholder: "Select token", symbol: flow.outputGroup?.symbol) {
                        flow.go(.receiveToken)
                    }
                }
                HStack(spacing: 12) {
                    Text("on").haffer(18, .regular)
                    SelectorButton(placeholder: "Select network", chain: flow.output?.chain) {
                        flow.go(flow.outputGroup == nil ? .receiveToken : .receiveNetwork)
                    }
                }
                Text("in this wallet.")
                    .haffer(17, .regular)
            }

            Spacer()

            PillButton(title: "Continue", disabled: !flow.ready) { flow.start() }
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
    }
}
