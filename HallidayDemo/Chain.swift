import WalletCore

enum ChainFamily: String, CaseIterable {
    case evm = "EVM"
    case solana = "Solana"

    var coin: CoinType {
        switch self {
        case .evm: .ethereum
        case .solana: .solana
        }
    }
}

// Each provider spells "this is the chain's own coin" differently: our balance proxy uses
// "0x" everywhere, while Halliday's asset list gives a mint for Solana.
enum Native {
    static let solanaMint = "So11111111111111111111111111111111111111111"

    static func matches(_ address: String) -> Bool {
        let value = address.lowercased()
        return value == "0x" || address == solanaMint
    }
}
