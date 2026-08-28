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
    // The other side of the transfer. Absent on Solana, where a transaction touches many
    // accounts and none of them is "the" counterparty.
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
    static let interval: TimeInterval = 30

    // Payments are owned by whichever address confirmed them, and only that address can
    // sign a withdrawal against them. Both of the wallet's owner addresses are therefore
    // queried and their results merged.
    private struct Feed {
        let owner: String
        var cursor: String?
        var buffer: [PaymentStatus] = []
        var exhausted = false
    }

    private(set) var payments: [PaymentStatus] = []
    private(set) var transfers: [Transfer] = []
    var loading = false
    // False until the first page of both feeds has settled, so the view can hold the list
    // back rather than showing payments while transfers are still in flight.
    var ready = false
    // True while the history screen is up. The badge's timer stands down then, so the list
    // is never rebuilt under someone who is scrolling it.
    var viewing = false
    // True while the balances behind the attention badges are in flight. The payments are
    // already on screen at that point, but which of them need attention is not yet known.
    private(set) var checking = false

    // How much of what has been fetched is on screen. Closing the modal winds this back to
    // a single page, so reopening starts from the ten most recent again.
    private(set) var shownPayments = 0
    private(set) var shownTransfers = 0

    private var feeds: [Feed] = []
    private var offset = 0
    private var transfersExhausted = false
    private var wallet: Wallet?
    private var lastLoad: Date?
    private let cache = PaymentCache.shared

    private var owners: [String] {
        guard let wallet else { return [] }
        return [wallet.address(.evm), wallet.address(.solana)]
    }

    var done: Bool {
        shownPayments >= payments.count && shownTransfers >= transfers.count
            && feeds.allSatisfy { $0.exhausted && $0.buffer.isEmpty } && transfersExhausted
    }

    // Nothing further is coming: every page is in and every badge is decided. An empty list
    // only means "there is nothing" once this is true.
    var settled: Bool { done && !loading && !checking }

    // The window the list is showing, each payment upgraded to the freshest status held.
    var visible: [PaymentStatus] { payments.prefix(shownPayments).map(cache.current) }

    var attention: [PaymentStatus] {
        visible.filter { $0.needsAttention(balances: cache.balances[$0.paymentId]) }
    }

    func items(_ scope: HistoryScope) -> [HistoryItem] {
        guard scope == .all else { return attention.map(HistoryItem.payment) }
        let combined = visible.map(HistoryItem.payment)
            + transfers.prefix(shownTransfers).map(HistoryItem.transfer)
        return combined.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var stale: Bool {
        lastLoad.map { Date().timeIntervalSince($0) >= Self.interval } ?? true
    }

    // Opening the history screen, and the home screen's badge, both come through here. The
    // feed is rebuilt at most once every thirty seconds; in between, opening the modal only
    // winds the window back to the first page of what is already held.
    func load(wallet: Wallet) async {
        if self.wallet?.address(.evm) != wallet.address(.evm) {
            self.wallet = wallet
            lastLoad = nil
        }
        guard !loading else { return }

        if stale {
            loading = true
            feeds = owners.map { Feed(owner: $0) }
            payments = []
            transfers = []
            offset = 0
            transfersExhausted = false
            shownPayments = 0
            shownTransfers = 0
            await appendPage()
            lastLoad = .now
            loading = false
            ready = true
        } else {
            shownPayments = min(Self.page, payments.count)
            shownTransfers = min(Self.page, transfers.count)
        }
        await loadVisibleBalances()
    }

    func refreshBadge(wallet: Wallet) async {
        guard !viewing else { return }
        await load(wallet: wallet)
    }

    // Driven by the list reaching its end, so it runs as the user scrolls rather than on a
    // schedule. Anything already fetched is revealed before the network is touched again.
    func loadMore() async {
        guard !loading, !done else { return }
        if shownPayments < payments.count || shownTransfers < transfers.count {
            shownPayments = min(shownPayments + Self.page, payments.count)
            shownTransfers = min(shownTransfers + Self.page, transfers.count)
        } else {
            loading = true
            await appendPage()
            loading = false
        }
        await loadVisibleBalances()
    }

    private func appendPage() async {
        async let nextPayments = takePayments(Self.page)
        async let nextTransfers = takeTransfers()
        let (batch, moreTransfers) = await (nextPayments, nextTransfers)
        payments += batch
        transfers += moreTransfers
        shownPayments = payments.count
        shownTransfers = transfers.count
        batch.forEach(cache.record)
    }

    // A k-way merge over the owner feeds. Each returns newest first, so comparing the head
    // of every buffer gives a correctly ordered combined page without over-fetching either.
    private func takePayments(_ count: Int) async -> [PaymentStatus] {
        var page: [PaymentStatus] = []
        while page.count < count {
            for index in feeds.indices where feeds[index].buffer.isEmpty && !feeds[index].exhausted {
                await fill(index)
            }
            let available = feeds.indices.filter { !feeds[$0].buffer.isEmpty }
            guard let pick = available.max(by: {
                (feeds[$0].buffer[0].date ?? .distantPast) < (feeds[$1].buffer[0].date ?? .distantPast)
            }) else { break }
            page.append(feeds[pick].buffer.removeFirst())
        }
        return page
    }

    private func fill(_ index: Int) async {
        do {
            let batch = try await Halliday.history(
                owner: feeds[index].owner,
                limit: Self.page,
                cursor: feeds[index].cursor
            )
            // Unconfirmed payments were quoted and abandoned; they never reach the list, so
            // a page can come back empty and the merge simply asks for the next one.
            feeds[index].buffer += batch.paymentStatuses.filter(\.listed)
            feeds[index].cursor = batch.nextPaginationKey
            feeds[index].exhausted = batch.nextPaginationKey == nil || batch.paymentStatuses.isEmpty
        } catch {
            Toast.shared.report(error)
            feeds[index].exhausted = true
        }
    }

    private func takeTransfers() async -> [Transfer] {
        guard !transfersExhausted, let wallet, !Config.serverURL.isEmpty else {
            transfersExhausted = true
            return []
        }
        var components = URLComponents(string: Config.serverURL + "/transfers")
        components?.queryItems = [
            URLQueryItem(name: "evm", value: wallet.address(.evm)),
            URLQueryItem(name: "solana", value: wallet.address(.solana)),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(Self.page)"),
        ]
        guard let url = components?.url else { transfersExhausted = true; return [] }

        struct Response: Decodable {
            let transfers: [Transfer]
            let done: Bool
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let batch = try JSONDecoder().decode(Response.self, from: data)
            offset += batch.transfers.count
            transfersExhausted = batch.done || batch.transfers.isEmpty
            return batch.transfers
        } catch {
            transfersExhausted = true
            return []
        }
    }

    // Every attention rule but TAINTED is decided by the payment's deposit-wallet balance,
    // so the rows on screen each need one. The cache keeps this to a single request per
    // payment per interval however often the window is recomputed.
    private func loadVisibleBalances() async {
        let ids = payments.prefix(shownPayments).map(\.paymentId)
        checking = true
        defer { checking = false }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor in await self.cache.loadBalances(id) }
            }
        }
    }
}
