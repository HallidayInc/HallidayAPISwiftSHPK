import Foundation
import Observation
import WalletCore

enum RecoveryChoice {
    case withdraw, requote

    var title: String {
        switch self {
        case .withdraw: "Withdraw"
        case .requote: "Requote"
        }
    }
}

@MainActor
@Observable
final class RecoveryFlow {
    var choice: RecoveryChoice?
    var loading = true
    var busy = false
    var result: WithdrawResult?

    private let original: PaymentStatus
    private let wallet: Wallet
    private let supported: Set<String>
    private let cache = PaymentCache.shared

    // Only the address that owns a payment can sign against it, so Solana-originated
    // payments are owned by the Solana address and everything else by the EVM one.
    let ownerAddress: String

    init(payment: PaymentStatus, wallet: Wallet, supported: Set<String>, owner: String) {
        self.original = payment
        self.wallet = wallet
        self.supported = supported
        self.ownerAddress = owner
    }

    // Both come from the shared cache, which holds this to one round trip per payment per
    // interval however many screens ask for it.
    var payment: PaymentStatus { cache.current(original) }
    var balances: [BalanceResult] { cache.balances[original.paymentId] ?? [] }

    // What can actually be moved: a positive balance in an asset Halliday can withdraw.
    // The endpoint also returns zero-balance rows and, occasionally, tokens that simply
    // arrived at the deposit address and are not part of the catalogue.
    var recoverable: [BalanceResult] {
        balances.filter { balance in
            guard (balance.amount ?? 0) > 0 else { return false }
            return supported.isEmpty || supported.contains(balance.token.lowercased())
        }
    }

    var hasFunds: Bool { !recoverable.isEmpty }

    // A requote refunds the original intent, so it needs the stuck money to be the same
    // asset the payment was quoted from. The exception is when /balances reports nothing
    // at all for that asset while the status API still shows a parked fund — the balance
    // lookup can lag, and the funds are known to be there.
    var canRequote: Bool {
        guard !loading, payment.outputAsset != nil, let input = payment.inputAsset?.lowercased() else {
            return false
        }
        if recoverable.contains(where: { $0.token.lowercased() == input }) { return true }
        let reported = balances.contains { $0.token.lowercased() == input }
        return !reported && payment.hasParked(supported: supported)
    }

    // Prefer the stuck balance in the asset the payment started from.
    var requoteSource: BalanceResult? {
        recoverable.first { $0.token.lowercased() == payment.inputAsset?.lowercased() } ?? recoverable.first
    }

    // Opening a payment refreshes its status and its deposit-wallet balance together.
    func load() async {
        loading = true
        await cache.load(original.paymentId)
        loading = false
    }

    // What a requote would deliver, once one has been fetched.
    var quoted: QuoteResponse?
    var quoting = false

    var replacement: Quote? { quoted?.best }

    // The stuck balance the replacement would be funded from.
    var source: BalanceResult? { requoteSource }

    func price(_ asset: String?) -> Decimal? {
        guard let asset, let raw = quoted?.prices[asset.lowercased()] else { return nil }
        return Decimal(string: raw)
    }

    var outputAsset: String? { payment.quoted?.outputAmount?.asset }

    // Withdrawing returns the one-time wallet's balance to this wallet. Requoting instead
    // funds a replacement payment from it, so the original intent still completes.
    func run(_ choice: RecoveryChoice) async {
        guard !busy else { return }
        busy = true
        do {
            let recipient = try await destination(for: choice)
            let authorization = try await Halliday.withdraw(
                paymentId: payment.paymentId,
                tokenAmounts: recoverable.map { ($0.token, $0.value.amount ?? "0") },
                recipient: recipient,
                account: recoverable.first?.withdrawAccount
            )
            let signature = try sign(authorization)
            result = try await Halliday.withdrawConfirm(signature: signature, stateToken: authorization.stateToken)
            // The cached balance is now the one that was just moved.
            cache.invalidate(original.paymentId)
        } catch {
            Toast.shared.report(error)
        }
        busy = false
    }

    // A withdrawal goes straight back to this wallet. A requote has to create and confirm a
    // replacement payment first, then send the funds to that payment's deposit address.
    private func destination(for choice: RecoveryChoice) async throws -> String {
        guard choice == .requote else { return ownerAddress }
        let confirmed = try await confirmedReplacement()
        guard let deposit = confirmed.nextInstruction?.depositInfo?.first?.depositAddress else {
            throw HallidayError.http(0, "The replacement payment did not return a deposit address.")
        }
        return deposit
    }

    private func confirmedReplacement() async throws -> PaymentStatus {
        let response = try await requote()
        guard let quote = response.best else {
            throw HallidayError.http(0, response.issue ?? "No route is available to retry this payment.")
        }
        return try await Halliday.confirm(
            paymentId: quote.paymentId,
            stateToken: response.stateToken,
            owner: ownerAddress,
            destination: payment.destinationAddress ?? ownerAddress
        )
    }

    // Fetched up front so the confirmation screen can say what the retry actually delivers.
    func loadQuote() async {
        guard quoted == nil, !quoting else { return }
        quoting = true
        quoted = try? await requote()
        quoting = false
    }

    private func requote() async throws -> QuoteResponse {
        guard let source = requoteSource, let outputAsset else {
            throw HallidayError.http(0, "This payment cannot be retried.")
        }
        return try await Halliday.quote(
            inputAsset: source.token,
            amount: source.value.amount ?? "0",
            outputAsset: outputAsset,
            destination: payment.destinationAddress ?? ownerAddress,
            parentPaymentId: payment.paymentId
        )
    }

    private func sign(_ authorization: WithdrawAuthorization) throws -> String {
        guard let hd = HDWallet(mnemonic: wallet.mnemonic, passphrase: "") else {
            throw SendError.signing("Wallet unavailable.")
        }
        let key = hd.getKeyForCoin(coin: .ethereum)
        let payload = authorization.withdrawAuthorization

        // Matches how USER_VERIFY payloads are signed during a payment.
        let raw: String
        switch authorization.signatureType {
        case "EIP712": raw = EthereumMessageSigner.signTypedMessage(privateKey: key, messageJson: payload)
        case "EIP191": raw = EthereumMessageSigner.signMessage(privateKey: key, message: payload)
        default: throw SendError.signing("Unsupported signature type \(authorization.signatureType).")
        }
        guard !raw.isEmpty else { throw SendError.signing("Could not sign the withdrawal authorization.") }
        return raw.hasPrefix("0x") ? raw : "0x" + raw
    }
}
