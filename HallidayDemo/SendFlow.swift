import Foundation
import Observation

// One row in the send token list. Official tokens gather their chains together; anything
// unrecognised stays on the single chain it was found on.
struct SendAsset: Identifiable {
    let id: String
    let symbol: String
    let imageURL: URL?
    let balances: [TokenBalance]

    var chains: [String] { balances.map(\.chain).sorted() }
}

enum SendStep: Hashable {
    case network, amount, address, review, sending
}

@MainActor
@Observable
final class SendFlow {
    var path: [SendStep] = []
    var asset: SendAsset?
    var selected: TokenBalance?
    var amount = ""
    var destination = ""
    var txHash: String?
    var busy = false
    var gasFee: Decimal = 0

    private let wallet: Wallet
    private let assets: AssetStore
    private let balances: BalanceStore

    init(wallet: Wallet, assets: AssetStore, balances: BalanceStore) {
        self.wallet = wallet
        self.assets = assets
        self.balances = balances
    }

    var family: ChainFamily? {
        selected.flatMap { assets.family($0.chain) }
    }

    var canSend: Bool {
        guard let typed = Decimal(string: amount) else { return false }
        return typed > 0 && typed <= maxSendable && !destination.isEmpty && gasShortfall == nil
    }

    var gasShortfall: String? {
        guard let selected, family == .evm, gasFee > 0 else { return nil }
        let held = isNative ? selected.amount : balances.nativeAmount(chain: selected.chain)
        let needed = isNative ? gasFee + (Decimal(string: amount) ?? 0) : gasFee
        guard held < needed else { return nil }
        let symbol = assets.gasTokens[selected.chain]?.symbol ?? "gas"
        return "You need more \(symbol) on \(selected.chain.capitalized) to pay for gas."
    }

    // Only what the wallet actually holds, grouped by symbol when the token is recognised.
    func sendable(showAll: Bool) -> [SendAsset] {
        let rows = balances.rows(showAll: showAll).filter { $0.amount > 0 }
        var official: [String: [TokenBalance]] = [:]
        var singles: [SendAsset] = []

        for row in rows {
            if row.supported {
                official[row.symbol.uppercased(), default: []].append(row)
            } else {
                singles.append(SendAsset(id: row.id, symbol: row.symbol, imageURL: row.imageURL, balances: [row]))
            }
        }

        let grouped = official.map { symbol, rows in
            SendAsset(id: symbol, symbol: rows[0].symbol, imageURL: rows[0].imageURL, balances: rows)
        }
        return Preferred.sort(grouped + singles, pinned: Preferred.tokens, by: \.symbol)
    }

    func select(_ asset: SendAsset) {
        self.asset = asset
        if asset.balances.count == 1 {
            choose(asset.balances[0])
        } else {
            path = [.network]
        }
    }

    func choose(_ balance: TokenBalance) {
        selected = balance
        amount = ""
        gasFee = 0
        path = [.amount]
        guard let chain = assets.chains[balance.chain] else { return }
        let from = wallet.address(.evm)
        Task { gasFee = await Sender.fee(chain: chain, from: from, tokenAddress: balance.address) }
    }

    private var isNative: Bool { selected?.address.lowercased() == "0x" }

    // Only a native send competes with its own gas; an ERC-20 pays it from a separate balance.
    var gasBuffer: Decimal { isNative ? gasFee : 0 }

    var maxSendable: Decimal {
        guard let selected else { return 0 }
        return max(0, selected.amount - gasBuffer)
    }

    func send() {
        guard let selected, let chain = assets.chains[selected.chain] else { return }
        path.append(.sending)
        busy = true
        Task {
            do {
                txHash = try await Sender.send(
                    to: destination,
                    amount: amount,
                    tokenAddress: selected.address,
                    decimals: selected.decimals,
                    wallet: wallet,
                    chain: chain,
                    chainName: selected.chain
                )
            } catch {
                Toast.shared.report(error)
            }
            busy = false
        }
    }
}
