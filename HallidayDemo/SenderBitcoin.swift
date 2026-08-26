import Foundation
import WalletCore

enum BitcoinSender {
    static func send(
        to recipient: String,
        amount rawAmount: String,
        decimals: Int,
        wallet: Wallet
    ) async throws -> String {
        let hd = HDWallet(mnemonic: wallet.mnemonic, passphrase: "")!
        let key = hd.getKeyForCoin(coin: .bitcoin)
        let sender = wallet.address(.bitcoin)

        let response = try await Proxy.get("/bitcoin/utxos", ["address": sender])
        let rows = response["utxos"] as? [[String: Any]] ?? []
        guard !rows.isEmpty else {
            throw SendError.rpc("utxos", "This address has nothing to spend.")
        }

        var input = BitcoinSigningInput()
        input.hashType = BitcoinSigHashType.all.rawValue
        input.amount = Int64(try Units.integer(rawAmount, decimals: decimals))
        input.byteFee = Int64((response["feePerByte"] as? NSNumber)?.intValue ?? 2)
        input.toAddress = recipient
        input.changeAddress = sender
        input.coinType = CoinType.bitcoin.rawValue
        input.privateKey = [key.data]
        input.utxo = rows.compactMap(utxo)

        // Coin selection and the change output are the planner's job; it also reports when
        // the balance cannot cover the amount plus the fee.
        let plan: BitcoinTransactionPlan = AnySigner.plan(input: input, coin: .bitcoin)
        guard plan.error == .ok else {
            throw SendError.signing("Not enough bitcoin to cover the amount and its fee.")
        }
        input.plan = plan

        let signed: BitcoinSigningOutput = AnySigner.sign(input: input, coin: .bitcoin)
        guard signed.error == .ok else {
            throw SendError.signing(signed.errorMessage.isEmpty ? "\(signed.error)" : signed.errorMessage)
        }

        let result = try await Proxy.post("/bitcoin/broadcast", ["hex": signed.encoded.hexString])
        guard let txid = result["txid"] as? String else {
            throw SendError.rpc("broadcast", "no transaction id returned")
        }
        return txid
    }

    private static func utxo(_ row: [String: Any]) -> BitcoinUnspentTransaction? {
        guard let hash = row["hash"] as? String,
              let script = row["script"] as? String,
              let index = (row["index"] as? NSNumber)?.uint32Value,
              let value = (row["value"] as? NSNumber)?.int64Value
        else { return nil }

        var outPoint = BitcoinOutPoint()
        outPoint.hash = Data(hexString: hash) ?? Data()
        outPoint.index = index
        outPoint.sequence = UInt32.max

        var utxo = BitcoinUnspentTransaction()
        utxo.outPoint = outPoint
        utxo.script = Data(hexString: script) ?? Data()
        utxo.amount = value
        return utxo
    }
}
