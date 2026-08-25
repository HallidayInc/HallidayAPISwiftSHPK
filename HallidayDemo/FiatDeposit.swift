import SwiftUI

struct DepositTypeView: View {
    var mode: FlowMode = .deposit
    var cashEnabled = true
    let onSelect: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(mode == .withdraw ? "Select a withdrawal type." : "Select a deposit type.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .padding(.bottom, 28)

            PillButton(
                title: cashEnabled ? "Cash" : "Cash (coming soon)",
                disabled: !cashEnabled
            ) { onSelect(true) }
                .padding(.bottom, 12)
            PillButton(title: "Crypto") { onSelect(false) }

            Spacer()
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
    }

}

struct OptionPicker: View {
    let title: String
    let options: [String]
    let label: (String) -> String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PickerTitle(title)

            List(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack {
                        Text(label(option)).haffer(16)
                        Spacer()
                    }
                }
                .tint(.primary)
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FiatBuilderView: View {
    @Bindable var flow: DepositFlow

    var body: some View {
        VStack(spacing: 0) {
            Text("Convert cash to tokens in your wallet.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("Pay").haffer(18, .regular)
                    pill(flow.fiatCurrency ?? "Select currency") { flow.go(.currency) }
                }
                HStack(spacing: 12) {
                    Text("with").haffer(18, .regular)
                    pill(flow.fiatMethod.map(OnrampStore.label) ?? "Select method") { flow.go(.method) }
                }
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
                Text("in this wallet.").haffer(17, .regular)
            }

            Spacer()

            PillButton(title: "Continue", disabled: !flow.fiatReady) { flow.start() }
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).haffer(18, .regular)
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
