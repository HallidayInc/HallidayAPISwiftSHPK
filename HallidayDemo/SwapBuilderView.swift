import SwiftUI

struct SwapBuilderView: View {
    @Bindable var flow: DepositFlow

    var body: some View {
        VStack(spacing: 0) {
            Text("Swap tokens in your wallet.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("Swap").haffer(18, .regular)
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
                Text("from your wallet.")
                    .haffer(17, .regular)
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
