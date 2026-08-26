import SwiftUI

struct RecoveryView: View {
    let payment: PaymentStatus
    let wallet: Wallet
    @Environment(\.dismiss) private var dismiss
    @State private var flow: RecoveryFlow

    init(payment: PaymentStatus, wallet: Wallet) {
        self.payment = payment
        self.wallet = wallet
        _flow = State(initialValue: RecoveryFlow(payment: payment, wallet: wallet))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    if flow.choice != nil {
                        NavButton(glyph: .back) { flow.choice = nil }
                    }
                    Spacer()
                    NavButton(glyph: .close) { dismiss() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if flow.result != nil {
                    finished
                } else if let choice = flow.choice {
                    confirmation(choice)
                        .task { if choice == .requote { await flow.loadQuote() } }
                } else {
                    options
                }
            }
            .background(Color.surface)
        }
        .task { await flow.load() }
        .toasts()
    }

    private var options: some View {
        VStack(spacing: 0) {
            Text("This payment needs attention.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Text(payment.attentionReason ?? "It did not complete, and its funds are still recoverable.")
                .haffer(15, .regular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)

            if flow.loading {
                Spacer()
                ProgressView()
                Spacer()
            } else if flow.hasFunds {
                balances
                Spacer()
                VStack(spacing: 10) {
                    PillButton(title: "Withdraw") { flow.choice = .withdraw }
                    // Without a quoted output there is no original intent to retry.
                    PillButton(title: "Requote", disabled: flow.outputAsset == nil) { flow.choice = .requote }
                }
                .padding(.bottom, 16)
            } else {
                Spacer()
                Text("There is nothing left to recover from this payment.")
                    .haffer(15, .regular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
    }

    private var balances: some View {
        VStack(spacing: 0) {
            ForEach(flow.recoverable, id: \.token) { balance in
                hairline
                HStack(alignment: .top) {
                    Text("Recoverable").haffer(17, .regular)
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Format.trim(balance.value.amount ?? "0")) \(chain(balance.token))")
                            .haffer(17)
                        if balance.fee > 0 {
                            Text("after fee \(Format.trim("\(balance.net)"))")
                                .haffer(13, .regular)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 18)
            }
            hairline
        }
    }

    private func confirmation(_ choice: RecoveryChoice) -> some View {
        VStack(spacing: 0) {
            Text(choice == .withdraw ? "Withdraw to your wallet." : "Requote this payment.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Text(explanation(choice))
                .haffer(15, .regular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)

            balances

            if choice == .requote, let quote = flow.replacement {
                HStack(alignment: .top) {
                    Text("You receive").haffer(17, .regular)
                    Spacer(minLength: 16)
                    Text("\(Format.trim(quote.outputAmount.amount)) \(chain(quote.outputAmount.asset))")
                        .haffer(17)
                }
                .padding(.vertical, 18)
                hairline
            } else if choice == .requote && flow.quoting {
                ProgressView().padding(.vertical, 18)
            }

            Spacer()

            PillButton(title: "Confirm", busy: flow.busy) {
                Task { await flow.run(choice) }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
    }

    private func explanation(_ choice: RecoveryChoice) -> String {
        switch choice {
        case .withdraw:
            return "The funds still held by this payment will be signed for and returned to this wallet, on the chain they are already on. This cannot be undone."
        case .requote:
            return "A replacement payment will be created for the original destination, and the funds held by this one will be signed over to fund it."
        }
    }

    private var finished: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(flow.result?.status == "SUCCESS" ? "Recovery complete." : "Recovery submitted.")
                .haffer(30)
                .multilineTextAlignment(.center)
            Text(flow.result?.status == "SUCCESS"
                 ? "The funds have been signed over."
                 : "It is confirming onchain and will land shortly.")
                .haffer(15, .regular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            PillButton(title: "Done") { dismiss() }
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
    }

    private var hairline: some View {
        Rectangle().fill(Color.hairline).frame(maxWidth: .infinity).frame(height: 1)
    }

    private func chain(_ token: String) -> String {
        token.split(separator: ":").first.map(String.init)?.capitalized ?? token
    }
}
