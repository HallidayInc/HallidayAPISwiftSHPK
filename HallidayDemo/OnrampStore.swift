import Foundation
import Observation

@MainActor
@Observable
final class OnrampStore {
    // Quoted at boot purely to learn which rails and currencies this user can reach.
    private static let probeAmount = "100"
    private static let probeToken = "base:0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

    static let methodLabels: [String: String] = [
        "ACH": "ACH transfer",
        "APPLE_PAY": "Apple Pay",
        "CREDIT_CARD": "Credit card",
        "DEBIT_CARD": "Debit card",
        "FASTER_PAYMENTS": "Faster Payments",
        "FIAT_BALANCE": "Fiat balance",
        "GOOGLE_PAY": "Google Pay",
        "PAYPAL": "PayPal",
        "PIX": "Pix",
        "REVOLUT": "Revolut",
        "SEPA": "SEPA transfer",
        "TOKEN_BALANCE": "Token balance",
        "UPI": "UPI",
        "VENMO": "Venmo",
        "WIRE": "Wire transfer",
    ]

    var currency: String = Locale.current.currency?.identifier.uppercased() ?? "USD"
    var methods: [String] = []
    var currencies: [String] = []
    var providers: [String] = []

    static func label(_ method: String) -> String {
        methodLabels[method] ?? method.replacingOccurrences(of: "_", with: " ").capitalized
    }

    func load() async {
        do {
            let routes = try await Halliday.availableInputs(output: Self.probeToken)
            currencies = Preferred.sort(routes.fiats, pinned: Preferred.currencies, by: { $0 })
            // Fall back to USD when the device locale is not an onramp currency.
            if !currencies.isEmpty && !currencies.contains(currency) {
                currency = currencies.contains("USD") ? "USD" : currencies[0]
            }
            await refresh()
        } catch {
            Toast.shared.report(error)
        }
    }

    func refresh() async {
        do {
            let quote = try await Halliday.quote(
                inputAsset: currency,
                amount: Self.probeAmount,
                outputAsset: Self.probeToken,
                destination: ""
            )
            methods = Preferred.sort(
                Array(Set(quote.quotes.compactMap(\.onrampMethod))),
                pinned: Preferred.methods,
                by: { $0 },
                label: Self.label
            )
            providers = Array(Set(quote.quotes.compactMap(\.onramp))).sorted()
        } catch {
            Toast.shared.report(error)
        }
    }
}
