import SwiftUI

struct DepositStatusView: View {
    @Bindable var flow: DepositFlow
    @State private var showFunding = false

    var body: some View {
        VStack(spacing: 0) {
            if flow.isComplete {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.crtGlyph)
                Text(completedText)
                    .haffer(22)
                    .padding(.top, 16)
                Spacer()
            } else if flow.isFunded {
                Spacer()
                GridWave()
                Text(fundedText)
                    .haffer(22)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                Spacer()
            } else if let funding = flow.fundingPage {
                Spacer()
                Text("Finish your payment.")
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)
                Text("You will receive \(flow.output?.symbol ?? "") in your wallet on \(flow.output?.chain.capitalized ?? "").")
                    .haffer(17, .regular)
                    .multilineTextAlignment(.center)
                PillButton(title: "Continue to payment") { showFunding = true }
                    .padding(.top, 24)
                .onAppear { showFunding = true }
                Spacer()
            } else if flow.fundedByWallet {
                Spacer()
                GridWave()
                Text(flow.txHash == nil ? sendingText : sentText)
                    .haffer(22)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                if let hash = flow.txHash {
                    Button {
                        Toast.copy(hash, label: "Transaction")
                    } label: {
                        Text(hash)
                            .haffer(13, .regular)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .tint(.secondary)
                    .padding(.top, 12)
                }
                Spacer()
            } else if let deposit = flow.deposit {
                Text("Send your deposit now.")
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 16)

                sendLine(deposit)
                    .tracking(Theme.tracking(17))
                    .multilineTextAlignment(.center)

                Text("You will receive \(flow.output?.symbol ?? "") in your wallet on \(flow.output?.chain.capitalized ?? "").")
                    .haffer(17, .regular)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)

                QRCard(address: deposit.depositAddress, chain: deposit.depositChain)
                    .padding(.top, 24)

                Text(deposit.depositAddress)
                    .haffer(13, .regular)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)

                PillButton(title: "Copy address") {
                    Toast.copy(deposit.depositAddress, label: "Address")
                }
                .padding(.top, 16)

                Spacer()
            } else {
                Spacer()
                GridWave()
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        // The nav bar eats height at the top, so a plain centre sits visibly low.
        .padding(.bottom, flow.deposit == nil ? 44 : 0)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .sheet(isPresented: $showFunding) {
            if let funding = flow.fundingPage {
                SafariView(url: funding).ignoresSafeArea()
            }
        }
        // Polling keeps running behind the sheet, so close it once the money lands.
        .onChange(of: flow.isFunded) { _, funded in
            if funded { showFunding = false }
        }
        .task { await flow.poll() }
    }

    private var completedText: String {
        switch flow.mode {
        case .withdraw: "Withdrawal Completed."
        case .swap: "Swap Completed."
        case .deposit: "Deposit Completed."
        }
    }

    private var fundedText: String {
        switch flow.mode {
        case .withdraw: "Withdrawal is funded. Processing now."
        case .swap: "Swap is funded. Processing now."
        case .deposit: "Deposit is funded. Processing now."
        }
    }

    private var sendingText: String {
        flow.mode == .swap ? "Sending your swap." : "Sending your withdrawal."
    }

    private var sentText: String {
        flow.mode == .swap ? "Swap sent. Processing now." : "Withdrawal sent. Processing now."
    }

    private func sendLine(_ deposit: DepositInfo) -> Text {
        let required = Decimal(string: deposit.depositAmount) ?? 0
        // Rounded up: sending slightly over still settles, sending under does not.
        let amount = Format.amount(required, price: flow.price(flow.input), rounding: .up)
        let regular = Theme.font(17, .regular)
        let medium = Theme.font(17, .medium)
        return Text("Send exactly ").font(regular)
            + Text("\(amount) \(flow.input?.symbol ?? "")").font(medium)
            + Text(" to this deposit address on ").font(regular)
            + Text(deposit.depositChain.capitalized).font(medium)
            + Text(".").font(regular)
    }


}
