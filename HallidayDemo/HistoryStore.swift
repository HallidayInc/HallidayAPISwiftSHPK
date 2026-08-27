import Foundation
import Observation

enum HistoryScope: String, CaseIterable, Identifiable {
    case attention, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .attention: "Needs attention"
        case .all: "All transactions"
        }
    }
}

struct Transfer: Decodable, Identifiable {
    let chain: String
    let hash: String
    let direction: String
    let symbol: String
    let amount: String
    let timestamp: String?
    // The other side of the transfer. Absent on Bitcoin and Solana, where a transaction
    // has no single counterparty to point at.
    let counterparty: String?

    var id: String { "\(chain):\(hash):\(direction):\(amount)" }
    var incoming: Bool { direction == "in" }
    var date: Date? { timestamp.flatMap(Stamp.parse) }
}

// Providers vary on whether they include fractional seconds.
enum Stamp {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        withFraction.date(from: text) ?? plain.date(from: text)
    }
}

// A payment and a wallet transfer sit side by side in the combined list.
enum HistoryItem: Identifiable {
    case payment(PaymentStatus)
    case transfer(Transfer)

    var id: String {
        switch self {
        case let .payment(payment): "payment:\(payment.paymentId)"
        case let .transfer(transfer): "transfer:\(transfer.id)"
        }
    }

    var date: Date? {
        switch self {
        case let .payment(payment): payment.date
        case let .transfer(transfer): transfer.date
        }
    }
}

@MainActor
@Observable
final class HistoryStore {
    static let page = 10
    // Halliday allows polling a payment's status this often.
    static let pollInterval = Duration.seconds(5)

    var payments: [PaymentStatus] = []
    var transfers: [Transfer] = []
    var loading = false
    // False until the first page of both feeds has settled, so the view can hold the list
    // back rather than showing payments while transfers are still in flight.
    var ready = false

    private var cursor: String?
    private var paymentsDone = false
    private var transfersDone = false
    private var offset = 0
    private var owner = ""
    private var wallet: Wallet?

    var done: Bool { paymentsDone && transfersDone }

    // Set once the asset catalogue is available; empty simply means "flag everything".
    var supportedAssets: Set<String> = []

    var attention: [PaymentStatus] { payments.filter { $0.needsAttention(supported: supportedAssets) } }

    func items(_ scope: HistoryScope) -> [HistoryItem] {
        guard scope == .all else { return attention.map(HistoryItem.payment) }
        let combined = payments.map(HistoryItem.payment) + transfers.map(HistoryItem.transfer)
        return combined.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    func reset(wallet: Wallet) {
        let address = wallet.address(.evm)
        guard address != owner else { return }
        self.owner = address
        self.wallet = wallet
        payments = []
        transfers = []
        cursor = nil
        offset = 0
        paymentsDone = false
        transfersDone = false
        ready = false
    }

    // Each feed is checked separately: the home screen primes payments for the badge, so
    // by the time this modal opens only transfers may still be missing.
    func loadFirst(wallet: Wallet) async {
        reset(wallet: wallet)
        guard !ready else { return }
        loading = true
        // Both run regardless of what the badge poll already primed, so the combined list
        // is complete the first time it is shown.
        if payments.isEmpty && !paymentsDone { await loadPayments() }
        if transfers.isEmpty && !transfersDone { await loadTransfers() }
        loading = false
        ready = true
    }

    // Payments page by cursor, transfers by offset, so each keeps its own position.
    func loadMore() async {
        guard !loading, !done, !owner.isEmpty else { return }
        loading = true
        async let nextPayments = loadPayments()
        async let nextTransfers = loadTransfers()
        _ = await (nextPayments, nextTransfers)
        loading = false
    }

    private func loadPayments() async {
        guard !paymentsDone else { return }
        do {
            let batch = try await Halliday.history(owner: owner, limit: Self.page, cursor: cursor)
            payments += batch.paymentStatuses
            cursor = batch.nextPaginationKey
            paymentsDone = batch.nextPaginationKey == nil || batch.paymentStatuses.isEmpty
        } catch {
            Toast.shared.report(error)
            paymentsDone = true
        }
        }

    private func loadTransfers() async {
        guard !transfersDone, let wallet, !Config.serverURL.isEmpty else {
            transfersDone = true
            return
        }
        var components = URLComponents(string: Config.serverURL + "/transfers")
        components?.queryItems = [
            URLQueryItem(name: "evm", value: wallet.address(.evm)),
            URLQueryItem(name: "solana", value: wallet.address(.solana)),
            URLQueryItem(name: "bitcoin", value: wallet.address(.bitcoin)),
            URLQueryItem(name: "tron", value: wallet.address(.tron)),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(Self.page)"),
        ]
        guard let url = components?.url else { transfersDone = true; return }

        struct Response: Decodable {
            let transfers: [Transfer]
            let done: Bool
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let batch = try JSONDecoder().decode(Response.self, from: data)
            transfers += batch.transfers
            offset += batch.transfers.count
            transfersDone = batch.done || batch.transfers.isEmpty
        } catch {
            transfersDone = true
        }
    }

    // Records which wallet is in view without discarding anything already loaded.
    func prime(wallet: Wallet) {
        reset(wallet: wallet)
        self.owner = wallet.address(.evm)
        self.wallet = wallet
    }

    // Re-reads the newest page and folds it over what is held, so a status that changes
    // while the app is open updates in place. Failures stay silent; this runs on a timer.
    func refreshHead() async {
        guard !owner.isEmpty,
              let batch = try? await Halliday.history(owner: owner, limit: Self.page, cursor: nil)
        else { return }
        let fresh = Set(batch.paymentStatuses.map(\.paymentId))
        payments = batch.paymentStatuses + payments.filter { !fresh.contains($0.paymentId) }
        if cursor == nil { cursor = batch.nextPaginationKey }
        if payments.count <= batch.paymentStatuses.count {
            paymentsDone = batch.nextPaginationKey == nil
        }
    }

    // Runs until the calling view goes away, which cancels the surrounding task.
    func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            await refreshHead()
        }
    }
}
