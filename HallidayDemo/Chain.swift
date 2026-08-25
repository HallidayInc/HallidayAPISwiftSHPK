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
