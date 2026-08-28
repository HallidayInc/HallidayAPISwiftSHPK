import Foundation
import Observation

// Status and deposit-wallet balances for individual payments, held in one place so the
// history list and a payment's own screen share both the data and the rate limit. Halliday
// is asked for a given payment at most once every 30 seconds whichever screen is asking.
@MainActor
@Observable
final class PaymentCache {
    static let shared = PaymentCache()
    static let interval: TimeInterval = 30

    private(set) var status: [String: PaymentStatus] = [:]
    private(set) var balances: [String: [BalanceResult]] = [:]

    // Status and balances are stamped separately: the history feed already carries a fresh
    // status, so opening a payment should still be free to fetch balances and vice versa.
    @ObservationIgnored private var statusStamp: [String: Date] = [:]
    @ObservationIgnored private var balanceStamp: [String: Date] = [:]
    @ObservationIgnored private var inflight: Set<String> = []

    private func stale(_ stamp: Date?) -> Bool {
        stamp.map { Date().timeIntervalSince($0) >= Self.interval } ?? true
    }

    // The history feed's own status responses seed the cache without spending a request.
    func record(_ payment: PaymentStatus) {
        status[payment.paymentId] = payment
        statusStamp[payment.paymentId] = .now
    }

    func current(_ payment: PaymentStatus) -> PaymentStatus {
        status[payment.paymentId] ?? payment
    }

    // Balances only. The list uses this to decide the attention badge for rows whose status
    // it already has.
    func loadBalances(_ id: String) async {
        guard stale(balanceStamp[id]), !inflight.contains(id) else { return }
        inflight.insert(id)
        defer { inflight.remove(id) }
        guard let result = try? await Halliday.balances(paymentId: id) else { return }
        balances[id] = result
        balanceStamp[id] = .now
    }

    // Status and balances together, for a payment the user has opened. Either half is
    // skipped if it was already fetched inside the window.
    func load(_ id: String) async {
        guard !inflight.contains(id) else { return }
        inflight.insert(id)
        defer { inflight.remove(id) }

        let wantStatus = stale(statusStamp[id])
        let wantBalances = stale(balanceStamp[id])
        guard wantStatus || wantBalances else { return }

        async let fetchedStatus = Self.fetchStatus(id, when: wantStatus)
        async let fetchedBalances = Self.fetchBalances(id, when: wantBalances)
        let (newStatus, newBalances) = await (fetchedStatus, fetchedBalances)

        if let newStatus {
            status[id] = newStatus
            statusStamp[id] = .now
        }
        if let newBalances {
            balances[id] = newBalances
            balanceStamp[id] = .now
        }
    }

    private static func fetchStatus(_ id: String, when wanted: Bool) async -> PaymentStatus? {
        guard wanted else { return nil }
        return try? await Halliday.payment(id: id)
    }

    private static func fetchBalances(_ id: String, when wanted: Bool) async -> [BalanceResult]? {
        guard wanted else { return nil }
        return try? await Halliday.balances(paymentId: id)
    }

    // Called after a withdrawal so the next read does not serve the balance that was moved.
    func invalidate(_ id: String) {
        statusStamp[id] = nil
        balanceStamp[id] = nil
    }
}
