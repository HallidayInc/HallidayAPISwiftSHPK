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
    let payment: PaymentStatus
    var choice: RecoveryChoice?
    var balances: [BalanceResult] = []
    var loading = true
    var busy = false
    var result: WithdrawResult?

    private let wallet: Wallet

    init(payment: PaymentStatus, wallet: Wallet) {
        self.payment = payment
        self.wallet = wallet
    }

    // Entries that failed to price are skipped; the rest are what can actually be moved.
    var recoverable: [BalanceResult] {
        balances.filter { ($0.amount ?? 0) > 0 }
    }

    var hasFunds: Bool { !recoverable.isEmpty }

    func load() async {
        loading = true
        do {
            balances = try await Halliday.balances(paymentId: payment.paymentId)
        } catch {
            Toast.shared.report(error)
        }
        loading = false
    }

    var ownerAddress: String { wallet.address(.evm) }

    // What a requote would deliver, once one has been fetched.
    var replacement: Quote?
    var quoting = false

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
        guard replacement == nil, !quoting else { return }
        quoting = true
        replacement = (try? await requote())?.best
        quoting = false
    }

    private func requote() async throws -> QuoteResponse {
        guard let source = recoverable.first, let outputAsset else {
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
