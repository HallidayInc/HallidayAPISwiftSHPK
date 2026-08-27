import SwiftUI

struct TransferDetailView: View {
    let transfer: Transfer
    @Environment(AssetStore.self) private var assets
    @Environment(\.dismiss) private var dismiss
    @State private var explorerURL: URL?

    private var symbol: String { AssetStore.display(symbol: transfer.symbol) }
    private var chain: String { transfer.chain.capitalized }
    private var value: String { "\(Format.trim(transfer.amount)) \(symbol)" }

    // "You received 10.03 USDC on Base." with the figures carrying the weight. Built from
    // fonts rather than the haffer modifier, which returns a View and cannot be concatenated.
    private var summary: Text {
        let plain = Theme.font(15, .regular)
        let strong = Theme.font(15, .medium)
        return Text(transfer.incoming ? "You received " : "You sent ").font(plain)
            + Text(value).font(strong)
            + Text(" on ").font(plain)
            + Text(chain).font(strong)
            + Text(".").font(plain)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    NavButton(glyph: .back) { dismiss() }
                    Spacer()
                    NavButton(glyph: .close) { dismiss() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Text(transfer.incoming ? "Received funds." : "Sent funds.")
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)
                    .padding(.top, 12)

                summary
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 44)
                    .padding(.top, 8)
                    .padding(.bottom, 24)

                ScrollView {
                    VStack(spacing: 0) {
                        hairline
                        row("When", value: when, sub: nil)
                        hairline
                        row("Amount", value: value, sub: chain)
                        hairline
                        if let counterparty = transfer.counterparty {
                            Button {
                                Toast.copy(counterparty, label: transfer.incoming ? "From address" : "To address")
                            } label: {
                                row(transfer.incoming ? "From" : "To", value: short(counterparty), sub: nil)
                            }
                            .tint(.primary)
                            hairline
                        }
                        Button {
                            explorerURL = explorer
                        } label: {
                            row("Transaction hash", value: short(transfer.hash), sub: nil)
                        }
                        .tint(.primary)
                        .disabled(explorer == nil)
                        hairline
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxHeight: .infinity)
            }
            .background(Color.surface)
        }
        .fullScreenCover(item: $explorerURL) { SafariView(url: $0) }
        .toasts()
    }

    private var when: String {
        transfer.date.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "—"
    }

    // Solana is the one chain Halliday publishes no explorer for.
    private var explorer: URL? {
        if let base = assets.chains[transfer.chain]?.explorer {
            return URL(string: base.absoluteString.hasSuffix("/") ? "\(base.absoluteString)tx/\(transfer.hash)"
                                                                  : "\(base.absoluteString)/tx/\(transfer.hash)")
        }
        guard transfer.chain == "solana" else { return nil }
        return URL(string: "https://solscan.io/tx/\(transfer.hash)")
    }

    private func short(_ value: String) -> String {
        guard value.count > 12 else { return value }
        return "\(value.prefix(6))…\(value.suffix(4))"
    }

    private func row(_ label: String, value: String, sub: String?) -> some View {
        HStack(alignment: .top) {
            Text(label).haffer(17, .regular)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .haffer(17)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sub ?? " ")
                    .haffer(13, .regular)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 18)
    }

    private var hairline: some View {
        Rectangle().fill(Color.hairline).frame(maxWidth: .infinity).frame(height: 1)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
