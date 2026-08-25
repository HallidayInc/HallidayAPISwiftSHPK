import Foundation
import WalletCore

struct Wallet: Codable, Identifiable {
    let id: UUID
    var name: String
    let mnemonic: String
    let addresses: [String: String]

    init?(name: String, mnemonic: String) {
        guard let hd = HDWallet(mnemonic: mnemonic, passphrase: "") else { return nil }
        self.id = UUID()
        self.name = name
        self.mnemonic = hd.mnemonic
        self.addresses = Dictionary(
            uniqueKeysWithValues: ChainFamily.allCases.map { ($0.rawValue, hd.getAddressForCoin(coin: $0.coin)) }
        )
    }

    init(name: String) {
        let hd = HDWallet(strength: 128, passphrase: "")!
        self.id = UUID()
        self.name = name
        self.mnemonic = hd.mnemonic
        self.addresses = Dictionary(
            uniqueKeysWithValues: ChainFamily.allCases.map { ($0.rawValue, hd.getAddressForCoin(coin: $0.coin)) }
        )
    }

    func address(_ family: ChainFamily) -> String {
        addresses[family.rawValue] ?? ""
    }
}
