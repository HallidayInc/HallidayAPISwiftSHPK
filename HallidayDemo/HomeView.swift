import SwiftUI

struct HomeView: View {
    @AppStorage("showAllTokens") private var showAllTokens = false
    @Environment(WalletStore.self) private var store
    @Environment(AssetStore.self) private var assets
    @State private var balances = BalanceStore()
    @State private var showSettings = false
    @State private var showDeposit = false
    @State private var showWithdraw = false
    @State private var showSwap = false
    @State private var showChains = false
    @State private var showReceive = false
    @State private var showSend = false
    @State private var chain: String?

    private var total: Decimal {
        filtered.reduce(0) { $0 + $1.usd }
    }

    private var filtered: [TokenBalance] {
        let rows = balances.rows(showAll: showAllTokens)
        guard let chain else { return rows }
        return rows.filter { $0.chain == chain }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text("Total balance")
                        .haffer(14, .regular)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(total, format: .currency(code: "USD"))
                            .haffer(46)
                        // The badge only appears when the total is scoped to one chain.
                        if let chain {
                            ChainBadge(chain: chain, size: 26)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)

                HStack(spacing: 0) {
                    ActionButton(title: "Deposit", icon: "arrow.down") { showDeposit = true }
                    ActionButton(title: "Withdraw", icon: "arrow.up") { showWithdraw = true }
                    ActionButton(title: "Swap", icon: "arrow.left.arrow.right") { showSwap = true }
                    ActionButton(title: "Send", icon: "paperplane") { showSend = true }
                    ActionButton(title: "Receive", icon: "qrcode") { showReceive = true }
                }
                .padding(.vertical, 15)

                Button {
                    showChains = true
                } label: {
                    HStack(spacing: 4) {
                        Text(chain?.capitalized ?? "All networks")
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
                    }
                    .haffer(15, .regular)
                }
                .tint(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 24)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(Color.hairline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)

                List(filtered) { balance in
                    HStack(spacing: 12) {
                        TokenIcon(url: balance.imageURL)
                        Text(balance.symbol).haffer(16)
                        ChainBadge(chain: balance.chain)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Format.amount(balance.amount, price: balance.unitPrice))
                                .haffer(16)
                            Text(balance.usd, format: .currency(code: "USD"))
                                .haffer(13, .regular)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 14, trailing: 0))
                    .listRowSeparatorTint(Color.hairline)
                }
                .listStyle(.plain)
                .overlay {
                    if filtered.isEmpty {
                        Text("No balances yet")
                            .haffer(15, .regular)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .navBar(leading: .menu, onLeading: { showSettings = true })
            .fullScreenCover(isPresented: $showSettings, onDismiss: refresh) {
                SettingsView()
            }
            .fullScreenCover(isPresented: $showDeposit, onDismiss: refresh) {
                if let wallet = store.selected {
                    DepositView(wallet: wallet, assets: assets, balances: balances)
                }
            }
            .fullScreenCover(isPresented: $showWithdraw, onDismiss: refresh) {
                if let wallet = store.selected {
                    DepositView(wallet: wallet, assets: assets, balances: balances, mode: .withdraw)
                }
            }
            .fullScreenCover(isPresented: $showSend, onDismiss: refresh) {
                if let wallet = store.selected {
                    SendView(wallet: wallet, assets: assets, balances: balances)
                        .environment(assets)
                }
            }
            .fullScreenCover(isPresented: $showReceive) {
                if let wallet = store.selected {
                    ReceiveView(wallet: wallet).environment(assets)
                }
            }
            .fullScreenCover(isPresented: $showChains) {
                ChainFilterView(chain: $chain).environment(assets)
            }
            .fullScreenCover(isPresented: $showSwap, onDismiss: refresh) {
                if let wallet = store.selected {
                    DepositView(wallet: wallet, assets: assets, balances: balances, mode: .swap)
                }
            }
            .task { refresh() }
        }
        .toasts()
    }

    private func refresh() {
        guard let wallet = store.selected else { return }
        Task { await balances.refresh(wallet: wallet, assets: assets) }
    }
}
