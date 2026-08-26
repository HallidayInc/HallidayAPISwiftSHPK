import SwiftUI

struct HistoryView: View {
    let wallet: Wallet
    @Bindable var history: HistoryStore
    @AppStorage("showAllTokens") private var showAllTokens = false
    @Environment(AssetStore.self) private var assets
    @Environment(\.dismiss) private var dismiss
    @State private var scope = HistoryScope.attention
    @State private var selected: PaymentStatus?

    private var rows: [HistoryItem] {
        let items = history.items(scope)
        guard !showAllTokens else { return items }
        // Halliday payments are always shown; it is the wallet's own transfers that carry
        // whatever a spam contract calls itself.
        return items.filter {
            guard case let .transfer(transfer) = $0 else { return true }
            return supported(transfer)
        }
    }

    private func supported(_ transfer: Transfer) -> Bool {
        let symbol = AssetStore.display(symbol: transfer.symbol).uppercased()
        return assets.tokens.contains { $0.chain == transfer.chain && $0.symbol.uppercased() == symbol }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    NavButton(glyph: .close) { dismiss() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Text("History.")
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                scopePicker
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                list
            }
            .background(Color.surface)
        }
        .task { await history.loadFirst(wallet: wallet) }
        .fullScreenCover(item: $selected) { payment in
            RecoveryView(payment: payment, wallet: wallet)
        }
        .toasts()
    }

    private var scopePicker: some View {
        HStack(spacing: 0) {
            ForEach(HistoryScope.allCases) { option in
                Button {
                    scope = option
                } label: {
                    Text(option.label)
                        .haffer(15, .regular)
                        .foregroundStyle(scope == option ? Color(.systemBackground) : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background { if scope == option { Capsule().fill(Color.primary) } }
                }
                .tint(.primary)
            }
        }
        .padding(4)
        .background(Color.card, in: .capsule)
    }

    private var list: some View {
        List {
            ForEach(rows) { item in
                Group {
                    switch item {
                    case let .payment(payment):
                        Button {
                            if payment.recoverable { selected = payment }
                        } label: {
                            PaymentRow(payment: payment)
                        }
                        .tint(.primary)
                    case let .transfer(transfer):
                        TransferRow(transfer: transfer)
                    }
                }
                .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 14, trailing: 0))
                .listRowSeparatorTint(Color.hairline)
                .listRowBackground(Color.clear)
            }

            // Reaching the end of what is loaded pulls the next page in. This runs in either
            // scope, since an item needing attention may sit on a later page.
            if !history.done {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .task { await history.loadMore() }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 16)
        .overlay {
            if rows.isEmpty && !history.loading && history.done {
                Text(scope == .attention ? "Nothing needs attention." : "No transactions yet.")
                    .haffer(15, .regular)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PaymentRow: View {
    let payment: PaymentStatus

    // Onramp and transfer-in payments quote only an output, so the arrow form is used
    // solely when both sides are known.
    private var amounts: String {
        let output = payment.quoted?.outputAmount
        guard let output else { return "Payment \(payment.paymentId.prefix(8))" }
        let received = "\(Format.trim(output.amount)) \(symbol(output.asset))"
        guard let input = payment.quoted?.inputAmount else { return received }
        return "\(Format.trim(input.amount)) \(symbol(input.asset)) → \(received)"
    }

    private func symbol(_ asset: String) -> String {
        // Assets read "chain:address"; the chain alone is enough for a one-line summary.
        asset.split(separator: ":").first.map(String.init)?.capitalized ?? asset
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(amounts)
                    .haffer(16)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    Text(payment.underfunded
                         ? "Underfunded"
                         : payment.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        .haffer(13, .regular)
                        .foregroundStyle(payment.needsAttention ? Color.badge : .secondary)
                    if let date = payment.date {
                        Text(date.formatted(.dateTime.month().day().hour().minute()))
                            .haffer(13, .regular)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if payment.recoverable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 12) {
            ChainBadge(chain: transfer.chain, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(transfer.incoming ? "Received" : "Sent") \(AssetStore.display(symbol: transfer.symbol))")
                    .haffer(16)
                    .lineLimit(1)
                if let date = transfer.date {
                    Text(date.formatted(.dateTime.month().day().hour().minute()))
                        .haffer(13, .regular)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text("\(transfer.incoming ? "+" : "-")\(Format.trim(transfer.amount))")
                .haffer(16)
                .foregroundStyle(transfer.incoming ? Color.crtGlyph : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
