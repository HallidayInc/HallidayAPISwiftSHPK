import SwiftUI

struct QuoteView: View {
    @Bindable var flow: DepositFlow

    private var sent: Decimal { Decimal(string: flow.amount) ?? 0 }

    private var received: Decimal {
        Decimal(string: flow.quote?.best?.outputAmount.amount ?? "") ?? 0
    }

    private var priceImpact: Decimal? {
        guard let inPrice = flow.price(flow.input), let outPrice = flow.price(flow.output), sent > 0 else { return nil }
        let sentUSD = sent * inPrice
        guard sentUSD > 0 else { return nil }
        return abs(sentUSD - received * outPrice) / sentUSD * 100
    }

    private var valid: Bool { flow.quote?.isValid == true && flow.gasShortfall == nil }

    private var headline: String {
        switch flow.mode {
        case .withdraw: "Review and confirm your withdrawal."
        case .swap: "Review and confirm your swap."
        case .deposit: "Review and confirm your deposit."
        }
    }

    // Prefer a range the user can act on; fall back to Halliday's own wording.
    private var issue: String? {
        if let shortfall = flow.gasShortfall { return shortfall }
        guard let quote = flow.quote, let message = quote.issue else { return nil }
        guard let range = quote.acceptedRange else { return message }
        let symbol = flow.inputSymbol
        let price = flow.price(flow.input)
        // Round the bounds inward so a user typing the shown figure lands inside the range.
        let low = range.min.map { "\(Format.amount($0, price: price, rounding: .up)) \(symbol)" }
        let high = range.max.map { "\(Format.amount($0, price: price, rounding: .down)) \(symbol)" }
        switch (low, high) {
        case let (low?, high?): return "Enter an amount between \(low) and \(high)."
        case let (low?, nil): return "Enter an amount of at least \(low)."
        case let (nil, high?): return "Enter an amount of at most \(high)."
        default: return message
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(headline)
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)

            if flow.quote == nil {
                Spacer()
                GridWave()
                Spacer()
            } else {
                hairline
                row("You send", "\(Format.amount(sent, price: flow.price(flow.input))) \(flow.inputSymbol)", flow.input?.chain)
                hairline
                row(flow.mode == .withdraw ? "External address receives" : "You receive", "\(Format.amount(received, price: flow.price(flow.output))) \(flow.output?.symbol ?? "")", flow.output?.chain)
                hairline
                if let priceImpact {
                    row("Price impact", "\(priceImpact.formatted(.number.precision(.fractionLength(0...2))))%", nil)
                    hairline
                }

                if let issue {
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

                PillButton(title: "Confirm", disabled: !valid, busy: flow.busy) { flow.confirm() }
                    .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
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
                    Text(chain.capitalized)
                        .haffer(13, .regular)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 18)
    }
}
