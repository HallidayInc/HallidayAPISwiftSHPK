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

    var family: ChainFamily? {
        switch addressFamily {
        case "EVM": .evm
        case "SOL": .solana
        case "BTC": .bitcoin
        case "TRON": .tron
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
    let type: String
    let fundingPageUrl: URL?
    let verificationToken: String?
    let verifications: [Verification]?
    let depositInfo: [DepositInfo]?
}

struct PaymentStatus: Decodable {
    let paymentId: String
    let status: String
    let funded: Bool
    let nextInstruction: NextInstruction?
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
        onrampMethods: [String]? = nil
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
        }
        let body = Request(
            request: .init(
                fixedInputAmount: AssetAmount(asset: inputAsset, amount: amount),
                outputAsset: outputAsset,
                destAddress: destination
            ),
            onrampMethods: onrampMethods
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
}
