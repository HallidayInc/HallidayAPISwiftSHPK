import Foundation
import WalletCore

enum TronSender {
    private static let trc20FeeLimit: Int64 = 100_000_000

    static func send(
        to recipient: String,
        amount rawAmount: String,
        tokenAddress: String,
        decimals: Int,
        wallet: Wallet
    ) async throws -> String {
        let key = HDWallet(mnemonic: wallet.mnemonic, passphrase: "")!.getKeyForCoin(coin: .tron)
        let owner = wallet.address(.tron)
        let block = try await Proxy.get("/tron/block")

        var header = TronBlockHeader()
        header.number = int64(block["number"])
        header.timestamp = int64(block["timestamp"])
        header.version = Int32(int64(block["version"]))
        header.txTrieRoot = data(hex: block["txTrieRoot"])
        header.parentHash = data(hex: block["parentHash"])
        header.witnessAddress = data(hex: block["witnessAddress"])

        var transaction = TronTransaction()
        transaction.blockHeader = header
        transaction.timestamp = header.timestamp
        // Tron drops a transaction that is not packed before this deadline.
        transaction.expiration = header.timestamp + 10 * 60 * 1000

        if tokenAddress.lowercased() == "0x" {
            var transfer = TronTransferContract()
            transfer.ownerAddress = owner
            transfer.toAddress = recipient
            transfer.amount = Int64(try Units.integer(rawAmount, decimals: decimals))
            transaction.transfer = transfer
        } else {
            var transfer = TronTransferTRC20Contract()
            transfer.contractAddress = tokenAddress
            transfer.ownerAddress = owner
            transfer.toAddress = recipient
            transfer.amount = Units.bytes(rawAmount, decimals: decimals)
            transaction.transferTrc20Contract = transfer
            transaction.feeLimit = trc20FeeLimit
        }

        var input = TronSigningInput()
        input.transaction = transaction
        input.privateKey = key.data

        let signed: TronSigningOutput = AnySigner.sign(input: input, coin: .tron)
        guard signed.error == .ok else {
            throw SendError.signing(signed.errorMessage.isEmpty ? "\(signed.error)" : signed.errorMessage)
        }
        guard let body = try JSONSerialization.jsonObject(with: Data(signed.json.utf8)) as? [String: Any] else {
            throw SendError.signing("Signer returned an unreadable transaction.")
        }

        let result = try await Proxy.post("/tron/broadcast", body)
        guard let txid = result["txid"] as? String else {
            throw SendError.rpc("broadcast", "no transaction id returned")
        }
        return txid
    }

    private static func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    private static func data(hex value: Any?) -> Data {
        guard let text = value as? String else { return Data() }
        var out = [UInt8]()
        var index = text.startIndex
        while index < text.endIndex, let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
            out.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(out)
    }
}
