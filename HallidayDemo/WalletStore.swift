import Foundation
import Observation

@MainActor
@Observable
final class WalletStore {
    private static let file = URL.documentsDirectory.appending(path: "wallets.json")

    var wallets: [Wallet] = []
    var selectedID: UUID?

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Wallet].self, from: data) {
            wallets = saved
        }
        if wallets.isEmpty { add() }
        selectedID = wallets.first?.id
    }

    var selected: Wallet? {
        wallets.first { $0.id == selectedID }
    }

    func add() {
        wallets.append(Wallet(name: "Wallet \(wallets.count + 1)"))
        save()
    }

    @discardableResult
    func add(mnemonic: String) -> Bool {
        guard let wallet = Wallet(name: "Wallet \(wallets.count + 1)", mnemonic: mnemonic) else { return false }
        wallets.append(wallet)
        selectedID = wallet.id
        save()
        return true
    }

    func rename(_ wallet: Wallet, to name: String) {
        guard let index = wallets.firstIndex(where: { $0.id == wallet.id }) else { return }
        wallets[index].name = String(name.prefix(30))
        save()
    }

    func delete(_ wallet: Wallet) {
        wallets.removeAll { $0.id == wallet.id }
        if wallets.isEmpty { add() }
        if selected == nil { selectedID = wallets.first?.id }
        save()
    }

    private func save() {
        do {
            try JSONEncoder().encode(wallets).write(to: Self.file)
        } catch {
            Toast.shared.report(error)
        }
    }
}
