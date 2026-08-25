import Foundation
import WalletCore

enum SendError: LocalizedError {
    case unsupported(String)
    case rpc(String, String)
    case signing(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(chain): "Sending from \(chain) is not implemented yet."
        case let .rpc(method, message): "\(method) failed: \(message)"
        case let .signing(message): "Could not sign the transaction: \(message)"
        }
    }
}

// Funds a Halliday payment from the app's own wallet. Withdrawals need this because the
// deposit address Halliday returns has to be paid by us, not by an external wallet.
enum Sender {
    // Fallbacks only. Gas is estimated per transaction: EIP-2780 proposes changing the
    // intrinsic 21,000 cost, so assuming it is not safe.
    private static let nativeGas = "21000"
    private static let tokenGas = "150000"
    private static let gasHeadroom = Decimal(string: "1.25")!

    static func fund(deposit: DepositInfo, token: Token, wallet: Wallet, chain: ChainInfo) async throws -> String {
        try await send(
            to: deposit.depositAddress,
            amount: deposit.depositAmount,
            tokenAddress: token.address,
            decimals: token.decimals,
            wallet: wallet,
            chain: chain,
            chainName: deposit.depositChain
        )
    }

    static func send(
        to recipient: String,
        amount rawAmount: String,
        tokenAddress: String,
        decimals: Int,
        wallet: Wallet,
        chain: ChainInfo,
        chainName: String
    ) async throws -> String {
        guard chain.family == .evm, let rpcURL = chain.rpc, let chainId = chain.chainId?.value else {
            throw SendError.unsupported(chainName)
        }

        let from = wallet.address(.evm)
        let key = HDWallet(mnemonic: wallet.mnemonic, passphrase: "")!.getKeyForCoin(coin: .ethereum)
        let isNative = tokenAddress.lowercased() == "0x"
        let amount = baseUnits(rawAmount, decimals: decimals)

        async let nonceHex = call(rpcURL, "eth_getTransactionCount", [from, "pending"])
        async let gasPriceHex = call(rpcURL, "eth_gasPrice", [])

        let callData = isNative ? nil : erc20TransferData(to: recipient, amount: amount)
        let gasLimit = await estimatedGas(
            rpcURL,
            from: from,
            to: isNative ? recipient : tokenAddress,
            value: isNative ? "0x" + hex(amount) : nil,
            data: callData,
            fallback: isNative ? nativeGas : tokenGas
        )

        var input = EthereumSigningInput()
        input.chainID = bytes(decimal: chainId)
        input.nonce = bytes(hex: try await nonceHex)
        input.gasPrice = bytes(hex: try await gasPriceHex)
        input.gasLimit = gasLimit
        input.privateKey = key.data
        input.txMode = .legacy

        if isNative {
            input.toAddress = recipient
            input.transaction.transfer.amount = amount
        } else {
            // An ERC-20 transfer is sent to the contract, with the recipient in the calldata.
            input.toAddress = tokenAddress
            input.transaction.erc20Transfer.to = recipient
            input.transaction.erc20Transfer.amount = amount
        }

        let signed: EthereumSigningOutput = AnySigner.sign(input: input, coin: .ethereum)
        guard signed.error == .ok else {
            throw SendError.signing(signed.errorMessage.isEmpty ? "\(signed.error)" : signed.errorMessage)
        }

        return try await call(rpcURL, "eth_sendRawTransaction", ["0x" + hex(signed.encoded)])
    }

    // What this transfer will cost in gas coin, so "Max" can hold it back and the review
    // screen can refuse a send the wallet cannot pay for. Zero means the estimate failed.
    static func fee(chain: ChainInfo, from: String, tokenAddress: String) async -> Decimal {
        guard chain.family == .evm, let rpc = chain.rpc else { return 0 }
        let isNative = tokenAddress.lowercased() == "0x"
        // A one-unit transfer back to the sender stands in for the real one: the recipient
        // and amount are not known yet, and neither changes the gas materially.
        let probe: [String: Any] = isNative
            ? ["from": from, "to": from, "value": "0x0"]
            : ["from": from, "to": tokenAddress, "data": erc20TransferData(to: from, amount: Data([1]))]

        async let priceHex = try? call(rpc, "eth_gasPrice", [])
        async let gasHex = try? call(rpc, "eth_estimateGas", [probe])
        guard let price = await priceHex.map(number(hex:)) else { return 0 }
        let gas = await gasHex.map(number(hex:)) ?? Decimal(string: isNative ? nativeGas : tokenGas)!
        let wei = price * gas * gasHeadroom
        return wei * Decimal(sign: .plus, exponent: -18, significand: 1)
    }

    private static func estimatedGas(
        _ url: URL,
        from: String,
        to: String,
        value: String?,
        data: String?,
        fallback: String
    ) async -> Data {
        var tx: [String: Any] = ["from": from, "to": to]
        if let value { tx["value"] = value }
        if let data { tx["data"] = data }
        guard let hexResult = try? await call(url, "eth_estimateGas", [tx]) else {
            return bytes(decimal: fallback)
        }
        var padded = Decimal()
        var estimate = number(hex: hexResult) * gasHeadroom
        NSDecimalRound(&padded, &estimate, 0, .up)
        return bytes(decimal: NSDecimalNumber(decimal: padded).stringValue)
    }

    // transfer(address,uint256)
    private static func erc20TransferData(to: String, amount: Data) -> String {
        let address = to.lowercased().replacingOccurrences(of: "0x", with: "")
        let amountHex = hex(amount)
        return "0xa9059cbb"
            + String(repeating: "0", count: max(0, 64 - address.count)) + address
            + String(repeating: "0", count: max(0, 64 - amountHex.count)) + amountHex
    }

    private static func number(hex: String) -> Decimal {
        var total: Decimal = 0
        for character in hex.dropFirst(2) {
            guard let digit = character.hexDigitValue else { continue }
            total = total * 16 + Decimal(digit)
        }
        return total
    }

    private static func call(_ url: URL, _ method: String, _ params: [Any]) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        )
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = body?["error"] as? [String: Any] {
            throw SendError.rpc(method, String(describing: error["message"] ?? error))
        }
        guard let result = body?["result"] as? String else {
            throw SendError.rpc(method, String(data: data, encoding: .utf8) ?? "no result")
        }
        return result
    }

    // Protobuf wants minimal big-endian bytes, so amounts are converted by long division
    // rather than through a fixed-width integer that 18 decimals would overflow.
    private static func baseUnits(_ amount: String, decimals: Int) -> Data {
        let value = Decimal(string: amount) ?? 0
        var scaled = value * Decimal(sign: .plus, exponent: decimals, significand: 1)
        var whole = Decimal()
        NSDecimalRound(&whole, &scaled, 0, .down)
        return bytes(decimal: NSDecimalNumber(decimal: whole).stringValue)
    }

    private static func bytes(decimal text: String) -> Data {
        var digits = text.compactMap(\.wholeNumberValue)
        var out: [UInt8] = []
        while digits.contains(where: { $0 != 0 }) {
            var remainder = 0
            var next: [Int] = []
            for digit in digits {
                let current = remainder * 10 + digit
                next.append(current / 256)
                remainder = current % 256
            }
            out.insert(UInt8(remainder), at: 0)
            while next.count > 1 && next.first == 0 { next.removeFirst() }
            digits = next
        }
        return out.isEmpty ? Data([0]) : Data(out)
    }

    private static func bytes(hex: String) -> Data {
        var text = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        if text.count % 2 == 1 { text = "0" + text }
        var out = [UInt8]()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        while out.count > 1 && out.first == 0 { out.removeFirst() }
        return Data(out)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
