import Foundation
import Observation

struct TokenBalance: Identifiable {
    let id: String
    let chain: String
    let symbol: String
    let imageURL: URL?
    let amount: Decimal
    let usd: Decimal
    let decimals: Int
    let address: String
    // Present in Halliday's curated asset list; anything else is unrecognised or spam.
    let supported: Bool

    var unitPrice: Decimal? {
        amount > 0 ? usd / amount : nil
    }
}

@MainActor
@Observable
final class BalanceStore {
    var all: [TokenBalance] = []
    // False only until the first fetch settles, so the total can hold back rather than
    // showing $0.00 for a moment on a wallet that is not empty.
    private(set) var loaded = false

    func rows(showAll: Bool) -> [TokenBalance] {
        showAll ? all : all.filter(\.supported)
    }

    func nativeAmount(chain: String) -> Decimal {
        all.first { $0.chain == chain && $0.address.lowercased() == "0x" }?.amount ?? 0
    }



    func refresh(wallet: Wallet, assets: AssetStore) async {
        struct Row: Decodable {
            let chain: String
            let address: String
            let symbol: String
            let amount: String
            let usd: String
            let logo: URL?
            let decimals: Int?
        }
        struct SourceError: Decodable {
            let source: String
            let message: String
        }
        struct Response: Decodable {
            let balances: [Row]
            let errors: [SourceError]
        }

        guard !Config.serverURL.isEmpty else {
            Toast.shared.show("SERVER_URL is not set. Add it in Product → Scheme → Edit Scheme → Run → Arguments.")
            loaded = true
            return
        }
        var components = URLComponents(string: Config.serverURL + "/balances")
        components?.queryItems = [
            URLQueryItem(name: "evm", value: wallet.address(.evm)),
            URLQueryItem(name: "solana", value: wallet.address(.solana)),
        ]
        guard let url = components?.url else {
            Toast.shared.show("SERVER_URL is not a valid URL: \(Config.serverURL)")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                Toast.shared.show("Balance server \(code): \(String(data: data, encoding: .utf8) ?? "")")
                return
            }
            let payload = try JSONDecoder().decode(Response.self, from: data)
            for failure in payload.errors {
                Toast.shared.show("\(failure.source): \(failure.message)")
            }
            all = payload.balances.compactMap { row in
                guard let amount = Decimal(string: row.amount), amount > 0 else { return nil }
                // Providers mark a chain's own coin as "0x" while Halliday gives it a real
                // address, so the two have to be recognised as the same asset.
                let known = assets.tokens.first {
                    guard $0.chain == row.chain else { return false }
                    if Native.matches(row.address) { return Native.matches($0.address) }
                    return $0.address.caseInsensitiveCompare(row.address) == .orderedSame
                }
                return TokenBalance(
                    id: "\(row.chain):\(row.address)",
                    chain: row.chain,
                    symbol: AssetStore.display(symbol: row.symbol),
                    imageURL: known?.imageURL ?? row.logo,
                    amount: amount,
                    usd: Decimal(string: row.usd) ?? 0,
                    decimals: row.decimals ?? known?.decimals ?? 18,
                    address: row.address,
                    supported: known != nil
                )
            }
            await assets.cacheIcons(all.compactMap(\.imageURL))
        } catch {
            Toast.shared.report(error)
        }
        // Set even on failure: a wallet whose balances cannot be read should show its total
        // rather than a loader that never resolves.
        loaded = true
    }
}
