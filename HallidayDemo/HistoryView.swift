import SwiftUI

struct HistoryView: View {
    let wallet: Wallet
    @Bindable var history: HistoryStore
    // Unwinds the whole modal stack back to the home screen.
    let onFinished: () -> Void
    @AppStorage("showAllTokens") private var showAllTokens = false
    @Environment(AssetStore.self) private var assets
    @Environment(\.dismiss) private var dismiss
    private let cache = PaymentCache.shared
    @State private var scope = HistoryScope.attention
    @State private var selected: PaymentStatus?
    @State private var transfer: Transfer?

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

                if history.ready {
                    list
                } else {
                    Spacer()
                    GridWave()
                    Spacer()
                }
            }
            .background(Color.surface)
        }
        .task {
            history.viewing = true
            await history.load(wallet: wallet)
        }
        .onDisappear { history.viewing = false }
        .fullScreenCover(item: $transfer) { row in
            TransferDetailView(transfer: row).environment(assets)
        }
        .fullScreenCover(item: $selected) { payment in
            RecoveryView(payment: payment, wallet: wallet, assets: assets, onFinished: onFinished)
                .environment(assets)
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
                            selected = payment
                        } label: {
                            PaymentRow(payment: payment, assets: assets, cache: cache)
                        }
                        .tint(.primary)
                    case let .transfer(row):
                        Button { transfer = row } label: { TransferRow(transfer: row) }
                            .tint(.primary)
                    }
                }
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .listRowSeparatorTint(Color.hairline)
                .listRowBackground(Color.clear)
            }

            // Reaching the end of what is loaded pulls the next page in. This runs in either
            // scope, since an item needing attention may sit on a later page.
            if !history.done {
                // Paging still runs in either scope, but only the full list shows a spinner
                // for it. Under Needs attention the pages are being scanned for flagged
                // payments, which is not something to leave a spinner sitting under.
                Group {
                    if scope == .all {
                        HStack {
                            Spacer()
                            GridWave(cell: 6, gap: 3)
                            Spacer()
                        }
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                // Keyed on what is loaded: a call that arrives while another page is in
                // flight returns immediately, and without this the row would never ask again.
                .task(id: history.shownPayments + history.shownTransfers) {
                    await history.loadMore()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // An empty list is ambiguous until every page and every balance is in, so it holds
        // the loader rather than claiming there is nothing.
        .overlay {
            if rows.isEmpty {
                if history.settled {
                    Text(scope == .attention
                         ? "No payments need attention right now."
                         : "No transactions yet.")
                        .haffer(15, .regular)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    GridWave()
                }
            }
        }
    }
}

// Every Halliday payment reads the same way regardless of what it was — onramp, swap,
// deposit or withdrawal: what went in, what came out, and when.
struct PaymentRow: View {
    let payment: PaymentStatus
    let assets: AssetStore
    let cache: PaymentCache

    var body: some View {
        HStack(spacing: 12) {
            HistoryTile()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    side(payment.inputAsset)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    side(payment.outputAsset)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Text(payment.date.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "")
                    .haffer(13, .regular)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if payment.needsAttention(balances: cache.balances[payment.paymentId]) {
                    Circle().fill(Color.badge).frame(width: 8, height: 8)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func side(_ asset: String?) -> some View {
        if let asset {
            HStack(spacing: 4) {
                Text(assets.label(for: asset)).haffer(16)
                if let chain = assets.chain(for: asset) {
                    ChainBadge(chain: chain, size: 14)
                }
            }
        } else {
            Text("—").haffer(16).foregroundStyle(.secondary)
        }
    }
}

// A payment is a Halliday order, so it is marked as one. Built to the same plate, radius
// and outline as ChainBadge so the two read as the same class of thing.
struct HistoryTile: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Color.white
            Image("HallidayMark").resizable().scaledToFit().padding(3)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 5))
        .overlay {
            if colorScheme == .light {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.black, lineWidth: 1)
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
            HStack(spacing: 8) {
                Text("\(transfer.incoming ? "+" : "-")\(Format.trim(transfer.amount))")
                    .haffer(16)
                    .foregroundStyle(transfer.incoming ? Color.crtGlyph : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
