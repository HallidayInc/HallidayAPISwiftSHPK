import Foundation
import Observation
import WalletCore

enum FlowMode {
    case deposit, withdraw, swap
}

enum DepositStep: Hashable {
    case crypto, fiat, sendToken, sendNetwork, receiveToken, receiveNetwork
    case currency, method, amount, address, quote, deposit
}

@MainActor
@Observable
final class DepositFlow {
    var path: [DepositStep] = []
    var inputGroup: TokenGroup?
    var gasFee: Decimal = 0
    var outputGroup: TokenGroup?
    var input: Token?
    var output: Token?
    var amount = ""
    var prices: [String: String] = [:]
    var quote: QuoteResponse?
    var payment: PaymentStatus?
    var busy = false
    var fiatCurrency: String?
    var fiatMethod: String?
    var isFiat = false
    var mode: FlowMode = .deposit
    var destinationAddress = ""
    var sending = false
    var txHash: String?

    // nil means the other side has not been picked yet, so nothing is filtered out.
    private var availableInputs: Set<String>?
    private var availableOutputs: Set<String>?

    private let wallet: Wallet
    private let assets: AssetStore
    private let balances: BalanceStore

    init(wallet: Wallet, assets: AssetStore, balances: BalanceStore, mode: FlowMode = .deposit) {
        self.wallet = wallet
        self.assets = assets
        self.balances = balances
        self.mode = mode
    }

    // Withdrawals can only send what the wallet actually holds.
    private var heldIds: Set<String> {
        Set(balances.all.filter { $0.amount > 0 }.map { $0.id.lowercased() })
    }

    var outputFamily: ChainFamily? {
        output.flatMap { assets.family($0.chain) }
    }

    var inputBalance: Decimal? {
        guard let input else { return nil }
        return balances.all.first { $0.id.lowercased() == input.priceKey }?.amount
    }

    private var isNativeInput: Bool { Native.matches(input?.address ?? "") }

    // Spending the whole native balance leaves nothing to pay the gas with.
    var gasBuffer: Decimal { isNativeInput ? gasFee : 0 }

    var maxInput: Decimal? {
        inputBalance.map { max(0, $0 - gasBuffer) }
    }

    var gasShortfall: String? {
        guard fundedByWallet, let input, gasFee > 0 else { return nil }
        let held = isNativeInput ? (inputBalance ?? 0) : balances.nativeAmount(chain: input.chain)
        let needed = isNativeInput ? gasFee + (Decimal(string: amount) ?? 0) : gasFee
        // Some chains list no coin of their own, and then there is no balance to check against.
        guard let symbol = assets.gasTokens[input.chain]?.symbol, held < needed else { return nil }
        return "You need more \(symbol) on \(input.chain.capitalized) to cover the network fee."
    }

    private func loadGasBuffer() {
        gasFee = 0
        guard fundedByWallet, let input, let chain = assets.chains[input.chain] else { return }
        Task { gasFee = await Sender.fee(chain: chain, wallet: wallet, tokenAddress: input.address) }
    }

    // Swap opens straight on its builder, so pushed screens sit on an empty stack.
    private var rootPath: [DepositStep] {
        mode == .swap ? [] : [isFiat ? .fiat : .crypto]
    }

    func go(_ step: DepositStep) {
        path = rootPath + [step]
    }

    func popToRoot() {
        path = rootPath
    }

    // The wallet funds its own swaps and withdrawals; a deposit is funded externally.
    var fundedByWallet: Bool { mode != .deposit }

    var deposit: DepositInfo? { payment?.nextInstruction?.depositInfo?.first }
    // TRANSFER_IN also carries a funding_page_url, but a crypto deposit must show the QR
    // screen, so only a true ONRAMP is allowed to hand off to the web.
    var fundingPage: URL? {
        guard payment?.nextInstruction?.type == "ONRAMP" else { return nil }
        return payment?.nextInstruction?.fundingPageUrl
    }
    var isFunded: Bool { payment?.funded == true }
    var isComplete: Bool { payment?.status == "COMPLETE" }
    var ready: Bool { input != nil && output != nil }
    var fiatReady: Bool { fiatCurrency != nil && fiatMethod != nil && output != nil }

    // The asset the user parts with: a token for crypto deposits, a currency code for cash.
    var inputAsset: String? { isFiat ? fiatCurrency : input?.id }
    var inputSymbol: String { isFiat ? (fiatCurrency ?? "") : (input?.symbol ?? "") }

    var sendGroups: [TokenGroup] {
        guard fundedByWallet else {
            return availableInputs.map { assets.groups(matching: $0) } ?? assets.groups
        }
        var ids = heldIds
        if let availableInputs { ids.formIntersection(availableInputs) }
        return assets.groups(matching: ids)
    }

    var receiveGroups: [TokenGroup] {
        availableOutputs.map { assets.groups(matching: $0) } ?? assets.groups
    }

    var sendNetworks: [Token] {
        let tokens = networks(inputGroup, allowed: availableInputs)
        guard fundedByWallet else { return tokens }
        return tokens.filter { heldIds.contains($0.priceKey) }
    }
    var receiveNetworks: [Token] { networks(outputGroup, allowed: availableOutputs) }

    private func networks(_ group: TokenGroup?, allowed: Set<String>?) -> [Token] {
        let tokens = group?.tokens ?? []
        guard let allowed else { return tokens }
        return tokens.filter { allowed.contains($0.priceKey) }
    }

    func price(_ token: Token?) -> Decimal? {
        guard let token, let raw = prices[token.priceKey] else { return nil }
        return Decimal(string: raw)
    }

    func selectSend(_ group: TokenGroup) {
        inputGroup = group
        input = nil
        let options = networks(group, allowed: availableInputs)
        if options.count == 1 {
            chooseSend(options[0])
        } else {
            go(.sendNetwork)
        }
    }

    func chooseSend(_ token: Token) {
        input = token
        loadGasBuffer()
        popToRoot()
        run {
            let routes = try await Halliday.availableOutputs(input: token.id)
            self.availableOutputs = routes
            // Drop a receive selection this send token cannot actually reach.
            if let output = self.output, !routes.contains(output.priceKey) {
                self.output = nil
                self.outputGroup = nil
            }
        }
    }

    func selectReceive(_ group: TokenGroup) {
        outputGroup = group
        output = nil
        let options = networks(group, allowed: availableOutputs)
        if options.count == 1 {
            chooseReceive(options[0])
        } else {
            go(.receiveNetwork)
        }
    }

    func chooseReceive(_ token: Token) {
        output = token
        popToRoot()
        guard !isFiat else { return }
        run {
            let routes = try await Halliday.availableInputs(output: token.id).tokens
            self.availableInputs = routes
            if let input = self.input, !routes.contains(input.priceKey) {
                self.input = nil
                self.inputGroup = nil
            }
        }
    }

    func start() {
        guard output != nil else { return }
        go(.amount)
        guard let input, let output else { return }
        run {
            self.prices = try await Halliday.prices(input: input, output: output)
        }
    }

    func fetchQuote() {
        guard let inputAsset, let output else { return }
        path.append(.quote)
        let methods = fiatMethod.map { [$0] }
        run {
            let response = try await Halliday.quote(
                inputAsset: inputAsset,
                amount: self.amount,
                outputAsset: output.id,
                destination: self.payoutAddress(for: output),
                onrampMethods: methods
            )
            self.quote = response
            self.prices = response.currentPrices
        }
    }

    func confirm() {
        guard let quote, let best = quote.best, let output else { return }
        run {
            var status = try await Halliday.confirm(
                paymentId: best.paymentId,
                stateToken: quote.stateToken,
                owner: self.wallet.address(.evm),
                destination: self.payoutAddress(for: output)
            )
            if status.nextInstruction?.type == "USER_VERIFY" {
                status = try await self.verify(status)
            }
            self.payment = status
            self.path.append(.deposit)
            // A withdrawal is funded by this wallet, so pay Halliday's deposit address now.
            if self.fundedByWallet { self.fund() }
        }
    }

    private func fund() {
        guard let deposit, let chain = assets.chains[deposit.depositChain] else { return }
        // deposit_token is authoritative for decimals; fall back to the chosen input.
        let token = assets.tokens.first { $0.priceKey == deposit.depositToken.lowercased() } ?? input
        guard let token else { return }
        sending = true
        Task {
            do {
                txHash = try await Sender.fund(deposit: deposit, token: token, wallet: wallet, chain: chain)
            } catch {
                Toast.shared.report(error)
            }
            sending = false
        }
    }

    func poll() async {
        guard let id = payment?.paymentId else { return }
        while !Task.isCancelled && !isComplete {
            try? await Task.sleep(for: .seconds(5))
            do {
                payment = try await Halliday.payment(id: id)
            } catch {
                Toast.shared.report(error)
            }
        }
    }

    private func verify(_ status: PaymentStatus) async throws -> PaymentStatus {
        guard let instruction = status.nextInstruction,
              let token = instruction.verificationToken,
              let verifications = instruction.verifications else { return status }
        let key = HDWallet(mnemonic: wallet.mnemonic, passphrase: "")!.getKeyForCoin(coin: .ethereum)
        let signatures = verifications.map { verification in
            let raw = verification.signatureType == "EIP712"
                ? EthereumMessageSigner.signTypedMessage(privateKey: key, messageJson: verification.payload)
                : EthereumMessageSigner.signMessage(privateKey: key, message: verification.payload)
            return SignaturePayload(
                reason: verification.reason,
                signatureType: verification.signatureType,
                signature: raw.hasPrefix("0x") ? raw : "0x" + raw
            )
        }
        return try await Halliday.continueConfirm(verificationToken: token, signatures: signatures)
    }

    private func payoutAddress(for token: Token) -> String {
        mode == .withdraw ? destinationAddress : wallet.address(assets.family(token.chain) ?? .evm)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await work() } catch { Toast.shared.report(error) }
            busy = false
        }
    }
}
