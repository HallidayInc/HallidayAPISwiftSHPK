import SwiftUI

struct DepositView: View {
    @AppStorage("appearance") private var appearance = Appearance.system
    @Environment(\.dismiss) private var dismiss
    @Environment(OnrampStore.self) private var onramp
    @State private var flow: DepositFlow

    init(wallet: Wallet, assets: AssetStore, balances: BalanceStore, mode: FlowMode = .deposit) {
        _flow = State(initialValue: DepositFlow(wallet: wallet, assets: assets, balances: balances, mode: mode))
    }

    private var canClose: Bool { !flow.isFunded || flow.isComplete }

    var body: some View {
        NavigationStack(path: $flow.path) {
            Group {
                if flow.mode == .swap {
                    SwapBuilderView(flow: flow)
                } else {
                    DepositTypeView(mode: flow.mode, cashEnabled: flow.mode == .deposit) { cash in
                        flow.isFiat = cash
                        if cash {
                            flow.fiatCurrency = flow.fiatCurrency ?? onramp.currency
                            flow.fiatMethod = flow.fiatMethod ?? onramp.methods.first
                        }
                        flow.path = [cash ? .fiat : .crypto]
                    }
                }
            }
            .navigationDestination(for: DepositStep.self) { destination($0) }
            .navBar(trailing: canClose ? .close : nil, onTrailing: { dismiss() })
        }
        .toasts()
        .preferredColorScheme(appearance.resolved)
    }

    @ViewBuilder
    private func destination(_ step: DepositStep) -> some View {
        Group {
            switch step {
            case .crypto:
                if flow.mode == .withdraw {
                    WithdrawBuilderView(flow: flow)
                } else {
                    DepositBuilderView(flow: flow)
                }
            case .fiat:
                FiatBuilderView(flow: flow)
            case .currency:
                OptionPicker(title: "Select a currency", options: onramp.currencies, label: { $0 }) {
                    flow.fiatCurrency = $0
                    flow.path = [.fiat]
                    Task { await onramp.refresh() }
                }
            case .method:
                OptionPicker(title: "Select a payment method", options: onramp.methods, label: OnrampStore.label) {
                    flow.fiatMethod = $0
                    flow.path = [.fiat]
                }
            case .sendToken:
                TokenPicker(title: "Select a token to send", groups: flow.sendGroups) {
                    flow.selectSend($0)
                }
            case .sendNetwork:
                NetworkPicker(
                    title: "Select a network",
                    subtitle: "Networks you can send \(flow.inputGroup?.symbol ?? "") from.",
                    tokens: flow.sendNetworks
                ) {
                    flow.chooseSend($0)
                }
            case .receiveToken:
                TokenPicker(title: "Select a token to receive", groups: flow.receiveGroups) {
                    flow.selectReceive($0)
                }
            case .receiveNetwork:
                NetworkPicker(
                    title: "Select a network",
                    subtitle: "Networks you can receive \(flow.outputGroup?.symbol ?? "") on.",
                    tokens: flow.receiveNetworks
                ) {
                    flow.chooseReceive($0)
                }
            case .amount:
                AmountView(flow: flow)
            case .address:
                AddressView(flow: flow)
            case .quote:
                QuoteView(flow: flow)
            case .deposit:
                DepositStatusView(flow: flow)
            }
        }
        .navBar(
            // The funding/QR step is terminal: leaving it would abandon a live payment.
            leading: step == .deposit ? nil : .back,
            onLeading: { if !flow.path.isEmpty { flow.path.removeLast() } },
            trailing: canClose ? .close : nil,
            onTrailing: { dismiss() }
        )
        .navigationBarBackButtonHidden()
    }


}
