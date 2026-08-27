import SwiftUI

struct RecoveryView: View {
    let payment: PaymentStatus
    let wallet: Wallet
    let assets: AssetStore
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var flow: RecoveryFlow
    @State private var withdrawing = false

    init(payment: PaymentStatus, wallet: Wallet, assets: AssetStore, onFinished: @escaping () -> Void) {
        self.payment = payment
        self.wallet = wallet
        self.assets = assets
        self.onFinished = onFinished
        _flow = State(initialValue: RecoveryFlow(payment: payment, wallet: wallet, supported: assets.assetIDs))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    NavButton(glyph: .back) {
                        if flow.choice == nil { dismiss() } else { flow.choice = nil }
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
        .fullScreenCover(isPresented: $withdrawing) {
            ManualWithdrawView(
                payment: payment,
                wallet: wallet,
                account: flow.recoverable.first?.withdrawAccount,
                stuck: flow.requoteSource,
                onFinished: onFinished
            )
            .environment(assets)
        }
        .toasts()
    }

    private var options: some View {
        VStack(spacing: 0) {
            Text(actionable ? "This payment needs attention." : "Halliday payment.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
                .padding(.top, 12)

            Text(actionable
                 ? "Further action is required in order to recover stuck funds."
                 : "No action is required for this payment. Funds can still be withdrawn manually.")
                .haffer(15, .regular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 44)
                .padding(.top, 8)
                .padding(.bottom, 24)

            // The rows scroll on their own so a long list cannot squeeze the headline into
            // an ellipsis or push the buttons off the bottom.
            ScrollView {
                VStack(spacing: 0) {
                    hairline
                    Button {
                        Toast.copy(payment.paymentId, label: "Order ID")
                    } label: {
                        detail("Order ID", value: shortID, sub: "\(created) · \(status)")
                    }
                    .tint(.primary)
                    hairline
                    detail("Input", value: amount(payment.inputAmount), sub: chainName(payment.inputAsset))
                    hairline
                    detail("Output", value: amount(payment.outputAmount), sub: chainName(payment.outputAsset))
                    hairline

                    // Always last: how many of these there are depends on the payment.
                    stuckRows
                }
                // Inset the rows, not the scroll view, so the indicator rides the screen edge.
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 10) {
                // Always enabled: the balances endpoint does not always see funds that are
                // genuinely sitting in the deposit address.
                PillButton(title: "Withdraw stuck funds") { withdrawing = true }
                PillButton(title: "Requote with stuck funds", disabled: !flow.canRequote) {
                    flow.choice = .requote
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
    }

    // Halliday drops the parked_fund issue once a payment expires, so the balances endpoint
    // is the only place stuck funds can be confirmed. It is queried whenever this opens.
    // Nothing is rendered while balances load: a placeholder row would flash on every
    // healthy payment, which is most of them. A payment already reporting a parked fund
    // shows its row immediately, since that is known without the network.
    @ViewBuilder
    private var stuckRows: some View {
        if !flow.recoverable.isEmpty {
            ForEach(flow.recoverable, id: \.token) { balance in
                detail(
                    "Stuck",
                    value: "\(Format.trim(balance.value.amount ?? "0")) \(assets.label(for: balance.token))",
                    sub: chainName(balance.token)
                )
                hairline
            }
        } else {
            // Nothing confirmed by balances; fall back to whatever the payment still reports.
            ForEach(payment.parked.filter { withdrawable($0.token) }, id: \.token) { issue in
                detail("Stuck", value: stuck(issue), sub: chainName(issue.token))
                hairline
            }
        }
    }

    // Decides how the screen reads. The status is known up front, so a payment that is
    // already flagged says so immediately; everything else stays calm while balances load
    // and only changes if that call turns something up. Waiting on the network is not a
    // reason to tell someone their payment is broken.
    private var actionable: Bool {
        payment.needsAttention(supported: assets.assetIDs) || flow.hasFunds
    }

    private func withdrawable(_ token: String?) -> Bool {
        guard let token, !assets.assetIDs.isEmpty else { return true }
        return assets.assetIDs.contains(token.lowercased())
    }

    // Enough of the id at each end to recognise it; the whole thing is what gets copied.
    private var shortID: String {
        let id = payment.paymentId
        guard id.count > 12 else { return id }
        return "\(id.prefix(5))…\(id.suffix(5))"
    }

    private var created: String {
        payment.date.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "—"
    }

    private var status: String {
        payment.status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func amount(_ value: AssetAmount?) -> String {
        guard let value else { return "—" }
        return "\(Format.trim(value.amount)) \(assets.label(for: value.asset))"
    }

    // A parked balance is reported in the token's smallest units.
    private func stuck(_ issue: Issue) -> String {
        guard let token = issue.token, let raw = issue.balance?.value else { return "—" }
        let units = Decimal(string: raw) ?? 0
        let scaled = units * Decimal(sign: .plus, exponent: -(assets.decimals(for: token) ?? 0), significand: 1)
        return "\(Format.trim("\(scaled)")) \(assets.label(for: token))"
    }

    private func chainName(_ asset: String?) -> String? {
        asset.flatMap { assets.chain(for: $0) }?.capitalized
    }

    private func detail(_ label: String, value: String, sub: String?) -> some View {
        HStack(alignment: .top) {
            Text(label).haffer(17, .regular)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .haffer(17)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Always rendered, blank when there is no chain, so every row is the same
                // height whether or not it has a second line.
                Text(sub ?? " ")
                    .haffer(13, .regular)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 18)
    }

    private func confirmation(_ choice: RecoveryChoice) -> some View {
        VStack(spacing: 0) {
            Text("Review and confirm your recovery payment.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)

            if flow.quoting {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                hairline
                row("You send", sent, chainName(flow.source?.token))
                hairline
                row("You receive", received, chainName(flow.replacement?.outputAmount.asset))
                hairline
                if let impact = priceImpact {
                    row("Price impact", "\(impact.formatted(.number.precision(.fractionLength(0...2))))%", nil)
                    hairline
                }

                if let issue = flow.quoted?.issue {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 16))
                        Text(issue)
                            .haffer(15, .regular)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                }

                Spacer()

                PillButton(title: "Confirm", disabled: flow.replacement == nil, busy: flow.busy) {
                    Task { await flow.run(choice) }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 20)
    }

    private var sent: String {
        guard let source = flow.source else { return "—" }
        return "\(Format.trim(source.value.amount ?? "0")) \(assets.label(for: source.token))"
    }

    private var received: String {
        guard let output = flow.replacement?.outputAmount else { return "—" }
        return "\(Format.trim(output.amount)) \(assets.label(for: output.asset))"
    }

    private var priceImpact: Decimal? {
        guard let source = flow.source,
              let output = flow.replacement?.outputAmount,
              let inPrice = flow.price(source.token),
              let outPrice = flow.price(output.asset),
              let sentAmount = Decimal(string: source.value.amount ?? ""),
              let receivedAmount = Decimal(string: output.amount)
        else { return nil }
        let sentUSD = sentAmount * inPrice
        guard sentUSD > 0 else { return nil }
        return abs(sentUSD - receivedAmount * outPrice) / sentUSD * 100
    }

    private func row(_ label: String, _ value: String, _ chain: String?) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .haffer(17, .regular)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .haffer(17)
                if let chain {
                    Text(chain)
                        .haffer(13, .regular)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 18)
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
