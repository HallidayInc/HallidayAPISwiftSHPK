import WalletCore

enum ChainFamily: String, CaseIterable {
    case evm = "EVM"
    case solana = "Solana"
    case bitcoin = "Bitcoin"
    case tron = "Tron"

    var coin: CoinType {
        switch self {
        case .evm: .ethereum
        case .solana: .solana
        case .bitcoin: .bitcoin
        case .tron: .tron
        }
    }
}

// Each provider spells "this is the chain's own coin" differently: our balance proxy uses
// "0x" everywhere, while Halliday's asset list gives a mint for Solana and "bc1" for Bitcoin.
enum Native {
    static let solanaMint = "So11111111111111111111111111111111111111111"

    static func matches(_ address: String) -> Bool {
        let value = address.lowercased()
        return value == "0x" || value == "bc1" || address == solanaMint
    }
}
