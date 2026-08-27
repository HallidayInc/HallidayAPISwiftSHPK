import Foundation

struct Token: Identifiable, Hashable {
    let chain: String
    let address: String
    let name: String
    let symbol: String
    let decimals: Int
    let imageURL: URL?

    var id: String { "\(chain):\(address)" }
    var priceKey: String { id.lowercased() }
}

struct TokenGroup: Identifiable {
    let symbol: String
    let imageURL: URL?
    let tokens: [Token]

    var id: String { symbol }
    var name: String { tokens.first?.name ?? symbol }
}

struct ChainIdentifier: Decodable {
    let value: String
    enum CodingKeys: String, CodingKey { case value = "#" }
}

struct ChainInfo: Decodable {
    let image: URL?
    let addressFamily: String
    let rpc: URL?
    let chainId: ChainIdentifier?
    let explorer: URL?

    var family: ChainFamily? {
        switch addressFamily {
        case "EVM": .evm
        case "SOL": .solana
        default: nil
        }
    }
}

struct AssetAmount: Codable {
    let asset: String
    let amount: String
}

struct Quote: Decodable {
    let paymentId: String
    let outputAmount: AssetAmount
    let onramp: String?
    let onrampMethod: String?
}

struct AmountLimits: Decodable {
    let min: String?
    let max: String?
}

struct QuoteFault: Decodable {
    let message: String?
    let limits: AmountLimits?
}

struct QuoteResponse: Decodable {
    let quotes: [Quote]
    let currentPrices: [String: String]
    let stateToken: String
    let fault: QuoteFault?
    let limits: [AmountLimits]?

    // fault.limits is sometimes empty, so fold in the top-level ranges and take the widest span.
    var acceptedRange: (min: Decimal?, max: Decimal?)? {
        guard fault != nil else { return nil }
        var ranges = limits ?? []
        if let faultLimits = fault?.limits { ranges.append(faultLimits) }
        let mins = ranges.compactMap { $0.min.flatMap { Decimal(string: $0) } }
        let maxes = ranges.compactMap { $0.max.flatMap { Decimal(string: $0) } }
        guard !mins.isEmpty || !maxes.isEmpty else { return nil }
        return (mins.min(), maxes.max())
    }

    var best: Quote? {
        quotes.max { (Decimal(string: $0.outputAmount.amount) ?? 0) < (Decimal(string: $1.outputAmount.amount) ?? 0) }
    }

    // Halliday reports amount-limit problems on a 200 response, sometimes alongside quotes.
    var issue: String? { fault?.message }
    var isValid: Bool { best != nil && fault == nil }
}

struct Verification: Decodable {
    let reason: String
    let signatureType: String
    let payload: String
}

struct DepositInfo: Decodable {
    let depositToken: String
    let depositAmount: String
    let depositAddress: String
    let depositChain: String
}

struct NextInstruction: Decodable {
    let type: String?
    let instructionType: String?
    let errorMessage: String?
    let assetAmounts: [AssetAmount]?
    let fundingPageUrl: URL?
    let verificationToken: String?
    let verifications: [Verification]?
    let depositInfo: [DepositInfo]?
}

struct PaymentStatus: Decodable, Identifiable {
    let paymentId: String
    let status: String
    let funded: Bool
    let nextInstruction: NextInstruction?
    let createdAt: String?
    let quoted: QuotedAmounts?
    let parentPaymentId: String?
    let destinationAddress: String?
    let issues: [Issue]?
    let quoteRequest: QuoteRequest?
    let withdrawals: [Withdrawal]?

    var id: String { paymentId }

    // A payment the user has to act on: the workflow failed, it expired with money already
    // in the one-time wallet, or it was funded for less than the route will accept.
    var needsAttention: Bool { needsAttention(supported: []) }

    // `supported` is the set of assets Halliday can actually withdraw. A fund parked in
    // anything else — a missent token, say — is not recoverable through the API, so it is
    // not worth flagging. An empty set means the catalogue has not loaded yet; everything
    // is accepted rather than silently under-reporting.
    func needsAttention(supported: Set<String>) -> Bool {
        // Money still parked outranks everything, including a previous withdrawal that only
        // took part of it.
        if hasParked(supported: supported) { return true }
        // Nothing left to recover once a withdrawal has gone through.
        if withdrawn { return false }
        if status == "FAILED" { return true }
        if status == "EXPIRED" && funded { return true }
        return nextInstruction?.instructionType == "ERROR_WITHDRAW_OR_ROLLOVER"
    }

    var withdrawn: Bool {
        withdrawals?.contains { $0.status == "SUCCESS" } ?? false
    }

    func hasParked(supported: Set<String>) -> Bool {
        parked.contains { issue in
            guard let token = issue.token, !supported.isEmpty else { return true }
            return supported.contains(token.lowercased())
        }
    }

    // A payment funded below what its route needs cannot proceed on its own. Halliday
    // reports this as a parked fund rather than a status change, so the payment sits in
    // PENDING looking healthy.
    var underfunded: Bool {
        issues?.contains(where: \.underfunded) ?? false
    }

    var parked: [Issue] { issues?.filter(\.parkedFund) ?? [] }

    var inputAmount: AssetAmount? { quoteRequest?.request?.fixedInputAmount }
    var outputAmount: AssetAmount? { quoted?.outputAmount }
    var inputAsset: String? { quoteRequest?.request?.fixedInputAmount?.asset }
    var outputAsset: String? { quoted?.outputAmount?.asset ?? quoteRequest?.request?.outputAsset }

    // What the route still expects, so the reason can name a figure.
    var required: String? {
        nextInstruction?.depositInfo?.first?.depositAmount
    }

    var attentionReason: String? {
        if underfunded {
            if let message = issues?.first(where: \.underfunded)?.message { return message }
            if let required {
                return "This payment was funded for less than the \(required) its route needs to continue."
            }
            return "This payment was funded for less than its route needs to continue."
        }
        if let message = nextInstruction?.errorMessage { return message }
        if status == "EXPIRED" && funded { return "This payment expired after it was funded." }
        if status == "FAILED" { return "A step in this payment failed to execute." }
        return nil
    }

    // TAINTED is sanctions-flagged: it cannot be completed, retried, or withdrawn.
    var recoverable: Bool { needsAttention && status != "TAINTED" }

    var date: Date? { createdAt.flatMap(Halliday.timestamp.date(from:)) }
}

// The live API returns kinds the spec does not document, notably "parked_fund", which is
// how an underfunded payment is reported. Everything past `kind` is therefore optional.
struct Withdrawal: Decodable {
    let status: String?
    let transactionHash: String?
    let recipientAddress: String?
}

struct Issue: Decodable {
    let kind: String
    let reason: String?
    let message: String?
    let given: String?
    let limits: AmountLimits?
    let classification: String?
    let severity: String?
    let token: String?
    let balance: ChainIdentifier?

    var parkedFund: Bool { kind == "parked_fund" }

    // UNDERFUNDED is a short deposit, MISSENT is the wrong token at the deposit address.
    var underfunded: Bool {
        if parkedFund { return true }
        guard kind == "amount" else { return false }
        if reason == "TOO_LOW" || reason == "UNEXPECTEDLY_LOW" { return true }
        guard let given = given.flatMap({ Decimal(string: $0) }),
              let minimum = limits?.min.flatMap({ Decimal(string: $0) })
        else { return false }
        return given < minimum
    }
}

// quoted.input_amount is always null, so the request is what says what was put in.
struct QuoteRequest: Decodable {
    struct Inner: Decodable {
        let fixedInputAmount: AssetAmount?
        let outputAsset: String?
    }
    let request: Inner?
}

struct QuotedAmounts: Decodable {
    let inputAmount: AssetAmount?
    let outputAmount: AssetAmount?
}

struct BalanceResult: Decodable {
    struct Value: Decodable {
        let kind: String
        let amount: String?
        let withdrawalFee: String?
    }
    let address: String
    let token: String
    let withdrawAccount: String?
    let value: Value

    var amount: Decimal? {
        guard value.kind == "amount", let raw = value.amount else { return nil }
        return Decimal(string: raw)
    }
    var fee: Decimal { value.withdrawalFee.flatMap { Decimal(string: $0) } ?? 0 }
    var net: Decimal { max(0, (amount ?? 0) - fee) }
}

struct WithdrawAuthorization: Decodable {
    let signatureType: String
    let paymentId: String
    let withdrawAuthorization: String
    let stateToken: String
}

struct WithdrawResult: Decodable {
    let paymentId: String
    let status: String
    let transactionHash: String?
}

struct PaymentHistory: Decodable {
    let paymentStatuses: [PaymentStatus]
    let nextPaginationKey: String?
    let totalPayments: Int?
}

struct SignaturePayload: Encodable {
    let reason: String
    let signatureType: String
    let signature: String
}

enum HallidayError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case let .http(code, body): "Halliday API error \(code): \(body)"
        }
    }
}

enum Halliday {
    private static let base = URL(string: "https://v2.prod.halliday.xyz")!

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static func send<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(Config.hallidayKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw HallidayError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(T.self, from: data)
    }

    static func tokens() async throws -> [Token] {
        struct Raw: Decodable {
            let chain: String?
            let address: String?
            let name: String
            let symbol: String
            let decimals: Int
            let imageUrl: URL?
        }
        let raw: [String: Raw] = try await send("/assets")
        return raw.values.compactMap { r in
            guard let chain = r.chain, let address = r.address else { return nil }
            return Token(chain: chain, address: address, name: r.name, symbol: r.symbol, decimals: r.decimals, imageURL: r.imageUrl)
        }
    }

    static func chains() async throws -> [String: ChainInfo] {
        try await send("/chains")
    }

    static func prices(input: Token, output: Token) async throws -> [String: String] {
        try await quote(inputAsset: input.id, amount: "0.0001", outputAsset: output.id, destination: "").currentPrices
    }

    private struct Routes: Decodable {
        let tokens: [String]
        let fiats: [String]?
    }

    static func availableInputs(output: String) async throws -> (tokens: Set<String>, fiats: [String]) {
        let raw: [String: Routes] = try await send(
            "/assets/available-inputs", query: [URLQueryItem(name: "outputs[]", value: output)]
        )
        let routes = raw.values.first
        return (
            Set(routes?.tokens.map { $0.lowercased() } ?? []),
            (routes?.fiats ?? []).map { $0.uppercased() }.sorted()
        )
    }

    static func availableOutputs(input: String) async throws -> Set<String> {
        let raw: [String: Routes] = try await send(
            "/assets/available-outputs", query: [URLQueryItem(name: "inputs[]", value: input)]
        )
        return Set(raw.values.first?.tokens.map { $0.lowercased() } ?? [])
    }

    static func quote(
        inputAsset: String,
        amount: String,
        outputAsset: String,
        destination: String,
        onrampMethods: [String]? = nil,
        parentPaymentId: String? = nil
    ) async throws -> QuoteResponse {
        struct Request: Encodable {
            struct Inner: Encodable {
                let kind = "FIXED_INPUT"
                let fixedInputAmount: AssetAmount
                let outputAsset: String
                let destAddress: String
            }
            let request: Inner
            let priceCurrency = "USD"
            let onrampMethods: [String]?
            // Tells Halliday this quote replaces a payment whose funds are still in its
            // one-time wallet, so the new one can be funded from the old.
            let parentPaymentId: String?
        }
        let body = Request(
            request: .init(
                fixedInputAmount: AssetAmount(asset: inputAsset, amount: amount),
                outputAsset: outputAsset,
                destAddress: destination
            ),
            onrampMethods: onrampMethods,
            parentPaymentId: parentPaymentId
        )
        return try await send("/payments/quotes", body: try encoder.encode(body))
    }

    static func confirm(paymentId: String, stateToken: String, owner: String, destination: String) async throws -> PaymentStatus {
        struct Request: Encodable {
            let paymentId: String
            let stateToken: String
            let ownerAddress: String
            let destinationAddress: String
        }
        let body = Request(paymentId: paymentId, stateToken: stateToken, ownerAddress: owner, destinationAddress: destination)
        return try await send("/payments/confirm", body: try encoder.encode(body))
    }

    static func continueConfirm(verificationToken: String, signatures: [SignaturePayload]) async throws -> PaymentStatus {
        struct Request: Encodable {
            let verificationToken: String
            let signatures: [SignaturePayload]
        }
        let body = Request(verificationToken: verificationToken, signatures: signatures)
        return try await send("/payments/confirm", body: try encoder.encode(body))
    }

    static func payment(id: String) async throws -> PaymentStatus {
        try await send("/payments", query: [URLQueryItem(name: "payment_id", value: id)])
    }

    static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func history(owner: String, limit: Int = 10, cursor: String? = nil) async throws -> PaymentHistory {
        var query = [
            URLQueryItem(name: "owner_address", value: owner),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "categories[]", value: "ALL"),
        ]
        if let cursor { query.append(URLQueryItem(name: "pagination_key", value: cursor)) }
        return try await send("/payments/history", query: query)
    }

    static func balances(paymentId: String) async throws -> [BalanceResult] {
        struct Request: Encodable { let paymentId: String }
        struct Response: Decodable { let balanceResults: [BalanceResult] }
        let body: Response = try await send("/payments/balances", body: try encoder.encode(Request(paymentId: paymentId)))
        return body.balanceResults
    }

    static func withdraw(
        paymentId: String,
        tokenAmounts: [(token: String, amount: String)],
        recipient: String,
        account: String?
    ) async throws -> WithdrawAuthorization {
        struct TokenAmount: Encodable { let token: String; let amount: String }
        struct Request: Encodable {
            let paymentId: String
            let tokenAmounts: [TokenAmount]
            let recipientAddress: String
            let withdrawAccount: String?
        }
        let body = Request(
            paymentId: paymentId,
            tokenAmounts: tokenAmounts.map { TokenAmount(token: $0.token, amount: $0.amount) },
            recipientAddress: recipient,
            withdrawAccount: account
        )
        return try await send("/payments/withdraw", body: try encoder.encode(body))
    }

    static func withdrawConfirm(signature: String, stateToken: String) async throws -> WithdrawResult {
        struct Request: Encodable { let signature: String; let stateToken: String }
        return try await send("/payments/withdraw/confirm", body: try encoder.encode(Request(signature: signature, stateToken: stateToken)))
    }
}
