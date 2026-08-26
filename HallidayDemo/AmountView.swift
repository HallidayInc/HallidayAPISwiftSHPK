import SwiftUI

struct AmountView: View {
    @Bindable var flow: DepositFlow
    @State private var usdMode = false
    @FocusState private var focused: Bool

    private let presets: [Decimal] = [250, 500, 1000]

    private var price: Decimal? { flow.isFiat ? nil : flow.price(flow.input) }
    private var symbol: String { flow.inputSymbol }
    private var typed: Decimal { Decimal(string: flow.amount) ?? 0 }

    // USD entry is money; token entry is bounded by the token's own precision.
    private var maxDecimals: Int {
        usdMode ? 2 : (flow.input?.decimals ?? 8)
    }

    private var tokenAmount: Decimal {
        guard usdMode else { return typed }
        guard let price, price > 0 else { return 0 }
        return typed / price
    }

    private var overBalance: Bool {
        guard flow.fundedByWallet, let max = flow.maxInput else { return false }
        return tokenAmount > max
    }

    // The amount is drawn as Text, which honours a font change in both directions, and the
    // field itself is an invisible input. A TextField ignores later font changes and, with
    // fixedSize, sized past the screen instead of wrapping.
    private var amountSize: CGFloat {
        switch flow.amount.count + symbol.count {
        case ...10: 44
        case 11...13: 38
        case 14...17: 30
        case 18...22: 24
        default: 20
        }
    }

    private var amountText: Text {
        let typedFont = Theme.font(amountSize, .medium)
        let digits = flow.amount.isEmpty ? "0" : flow.amount
        return Text(digits)
            .font(typedFont)
            .foregroundColor(flow.amount.isEmpty ? .secondary : .primary)
            + Text(" " + (usdMode ? "USD" : symbol))
            .font(typedFont)
            .foregroundColor(.secondary)
    }

    private var headline: String {
        switch flow.mode {
        case .withdraw: "Input the amount to withdraw."
        case .swap: "Input the amount to swap from."
        case .deposit: "Input the amount to send."
        }
    }

    private var converted: String? {
        guard let price else { return nil }
        if usdMode {
            return "\(Format.amount(tokenAmount, price: price)) \(symbol)"
        }
        return "\(Format.usd(typed * price))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(headline)
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            Spacer()

            ZStack {
                TextField("", text: $flow.amount)
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .opacity(0.01)
                    .frame(width: 1, height: 1)
                    .onChange(of: flow.amount) { _, new in
                        let clean = Format.sanitize(new, decimals: maxDecimals)
                        if clean != new { flow.amount = clean }
                    }

                amountText
                    .tracking(Theme.tracking(amountSize))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .lineSpacing(0)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
            }
            .animation(.easeOut(duration: 0.12), value: amountSize)

            if let converted {
                Button {
                    usdMode.toggle()
                    flow.amount = ""
                } label: {
                    Label(converted, systemImage: "arrow.up.arrow.down")
                        .haffer(13, .regular)
                }
                .tint(.secondary)
                .padding(.top, 16)
            }

            if overBalance {
                Text(flow.gasBuffer > 0
                     ? "More than your \(symbol) balance after fees."
                     : "More than your \(symbol) balance.")
                    .haffer(13, .regular)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            if flow.fundedByWallet, let max = flow.maxInput, max > 0 {
                HStack(spacing: 12) {
                    portion("25%", max * Decimal(string: "0.25")!)
                    portion("50%", max * Decimal(string: "0.5")!)
                    portion("Max", max)
                }
                .padding(.top, 32)
            }

            if usdMode {
                HStack(spacing: 12) {
                    ForEach(presets, id: \.self) { preset in
                        Button(Format.usd(preset)) {
                            flow.amount = "\(preset)"
                        }
                        .haffer(15, .regular)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.card, in: .capsule)
                        .tint(.primary)
                    }
                }
                .padding(.top, 20)
            }

            Spacer()

            PillButton(title: "Continue", disabled: tokenAmount <= 0 || overBalance) {
                flow.amount = "\(tokenAmount)"
                if flow.mode == .withdraw {
                    flow.path.append(.address)
                } else {
                    flow.fetchQuote()
                }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }


    private func portion(_ title: String, _ value: Decimal) -> some View {
        Button(title) {
            // Percentages are token amounts, so leave USD entry mode first.
            usdMode = false
            flow.amount = Format.sanitize("\(value)", decimals: maxDecimals)
        }
        .haffer(15, .regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.card, in: .capsule)
        .tint(.primary)
    }
}
