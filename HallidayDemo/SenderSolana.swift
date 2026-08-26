import Foundation
import WalletCore

enum SolanaSender {
    static func send(
        to recipient: String,
        amount rawAmount: String,
        tokenAddress: String,
        decimals: Int,
        wallet: Wallet
    ) async throws -> String {
        let key = HDWallet(mnemonic: wallet.mnemonic, passphrase: "")!.getKeyForCoin(coin: .solana)
        let sender = wallet.address(.solana)
        let amount = try Units.integer(rawAmount, decimals: decimals)

        var input = SolanaSigningInput()
        input.privateKey = key.data
        input.recentBlockhash = try await blockhash()

        if Native.matches(tokenAddress) {
            var transfer = SolanaTransfer()
            transfer.recipient = recipient
            transfer.value = amount
            input.transferTransaction = transfer
        } else {
            try await addTokenTransfer(
                to: &input, sender: sender, recipient: recipient,
                mint: tokenAddress, amount: amount, decimals: decimals
            )
        }

        let signed: SolanaSigningOutput = AnySigner.sign(input: input, coin: .solana)
        guard signed.error == .ok else {
            throw SendError.signing(signed.errorMessage.isEmpty ? "\(signed.error)" : signed.errorMessage)
        }

        let result = try await Proxy.solana("sendTransaction", [signed.encoded, ["encoding": "base64"]])
        guard let signature = result as? String else {
            throw SendError.rpc("sendTransaction", "no signature returned")
        }
        return signature
    }

    // An SPL balance lives in an associated token account, not the wallet address. The
    // recipient may not have one yet, in which case this transaction has to create it.
    private static func addTokenTransfer(
        to input: inout SolanaSigningInput,
        sender: String, recipient: String, mint: String, amount: UInt64, decimals: Int
    ) async throws {
        guard let senderAccount = SolanaAddress(string: sender)?.defaultTokenAddress(tokenMintAddress: mint),
              let recipientAccount = SolanaAddress(string: recipient)?.defaultTokenAddress(tokenMintAddress: mint)
        else { throw SendError.signing("Could not derive the token account for \(mint).") }

        if try await accountExists(recipientAccount) {
            var transfer = SolanaTokenTransfer()
            transfer.tokenMintAddress = mint
            transfer.senderTokenAddress = senderAccount
            transfer.recipientTokenAddress = recipientAccount
            transfer.amount = amount
            transfer.decimals = UInt32(decimals)
            input.tokenTransferTransaction = transfer
        } else {
            var transfer = SolanaCreateAndTransferToken()
            transfer.recipientMainAddress = recipient
            transfer.tokenMintAddress = mint
            transfer.recipientTokenAddress = recipientAccount
            transfer.senderTokenAddress = senderAccount
            transfer.amount = amount
            transfer.decimals = UInt32(decimals)
            input.createAndTransferTokenTransaction = transfer
        }
    }

    private static func accountExists(_ address: String) async throws -> Bool {
        let result = try await Proxy.solana("getAccountInfo", [address, ["encoding": "base64"]])
        let value = (result as? [String: Any])?["value"]
        return value != nil && !(value is NSNull)
    }

    private static func blockhash() async throws -> String {
        let result = try await Proxy.solana("getLatestBlockhash", [])
        guard let value = (result as? [String: Any])?["value"] as? [String: Any],
              let blockhash = value["blockhash"] as? String
        else { throw SendError.rpc("getLatestBlockhash", "no blockhash returned") }
        return blockhash
    }
}
