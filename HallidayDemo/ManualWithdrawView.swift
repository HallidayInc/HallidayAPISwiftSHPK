import SwiftUI
import WalletCore

// Withdrawing whatever is actually sitting in a payment's deposit address. The balances
// endpoint misses funds sometimes, so this asks the user what to move rather than relying
// on what was detected.
@MainActor
@Observable
final class ManualWithdraw {
    enum Step: Hashable { case token, network }

    var path: [Step] = []
    var group: TokenGroup?
    var token: Token?
    var amount = ""
    var destination = ""
    var busy = false
    var result: WithdrawResult?
    // Shown under the address field so the user can correct the input and retry, rather
    // than a toast that disappears while they are still reading it.
    var failure: String?

    let payment: PaymentStatus
    private let wallet: Wallet
    private let account: String?

    init(payment: PaymentStatus, wallet: Wallet, account: String?) {
        self.payment = payment
        self.wallet = wallet
        self.account = account
    }

    var family: ChainFamily?
    var addressValid: Bool {
        guard let family, !destination.isEmpty else { return false }
        return AnyAddress.isValid(string: destination, coin: family.coin)
    }

    var ready: Bool {
        token != nil && (Decimal(string: amount) ?? 0) > 0 && addressValid && !busy
    }

    func select(_ group: TokenGroup) {
        self.group = group
        token = nil
        if group.tokens.count == 1 {
            choose(group.tokens[0])
        } else {
            path = [.network]
        }
    }

    func choose(_ token: Token) {
        self.token = token
        path = []
    }

    // Returns true when Halliday accepted the withdrawal.
    func run() async -> Bool {
        guard let token, !busy else { return false }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            let authorization = try await Halliday.withdraw(
                paymentId: payment.paymentId,
                tokenAmounts: [(token.id, amount)],
                recipient: destination,
                account: account
            )
            let signature = try sign(authorization)
            result = try await Halliday.withdrawConfirm(signature: signature, stateToken: authorization.stateToken)
            return true
        } catch {
            failure = Self.message(for: error)
            return false
        }
    }

    // Halliday reports problems as { "errors": [{ "kind": ..., "message": ... }] }.
    private static func message(for error: Error) -> String {
        guard case let HallidayError.http(_, body) = error else { return error.localizedDescription }
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = json["errors"] as? [[String: Any]] {
            let messages = errors.compactMap { $0["message"] as? String }
            if !messages.isEmpty { return messages.joined(separator: "\n") }
        }
        return body.isEmpty ? "The withdrawal was rejected." : body
    }

    private func sign(_ authorization: WithdrawAuthorization) throws -> String {
        guard let hd = HDWallet(mnemonic: wallet.mnemonic, passphrase: "") else {
            throw SendError.signing("Wallet unavailable.")
        }
        let key = hd.getKeyForCoin(coin: .ethereum)
        let payload = authorization.withdrawAuthorization
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

struct ManualWithdrawView: View {
    @Environment(AssetStore.self) private var assets
    @Environment(\.dismiss) private var dismiss
    @State private var flow: ManualWithdraw
    @FocusState private var focus: Field?

    private let wallet: Wallet
    private let stuck: BalanceResult?
    private let onFinished: () -> Void

    private enum Field { case amount, address }

    init(
        payment: PaymentStatus,
        wallet: Wallet,
        account: String?,
        stuck: BalanceResult?,
        onFinished: @escaping () -> Void
    ) {
        self.wallet = wallet
        self.stuck = stuck
        self.onFinished = onFinished
        _flow = State(initialValue: ManualWithdraw(payment: payment, wallet: wallet, account: account))
    }

    // A detected stuck balance is a good default; the user can still change any of it.
    private func prefill() {
        guard flow.token == nil, let stuck else { return }
        guard let token = assets.tokens.first(where: { $0.priceKey == stuck.token.lowercased() }) else { return }
        flow.token = token
        flow.group = assets.groups.first { $0.symbol == token.symbol }
        flow.amount = stuck.value.amount ?? ""
    }

    // The destination is this wallet's own address on whichever network is selected, so a
    // withdrawal defaults to somewhere the user actually controls.
    private func follow(_ chain: String?) {
        let family = chain.flatMap { assets.family($0) }
        flow.family = family
        if let family { flow.destination = wallet.address(family) }
    }

    var body: some View {
        NavigationStack(path: $flow.path) {
            content
                .navigationDestination(for: ManualWithdraw.Step.self) { step in
                    picker(step)
                        .navBar(
                            leading: .back,
                            onLeading: { if !flow.path.isEmpty { flow.path.removeLast() } },
                            trailing: .close,
                            onTrailing: { dismiss() }
                        )
                        .navigationBarBackButtonHidden()
                }
        }
        .toasts()
    }

    @ViewBuilder
    private func picker(_ step: ManualWithdraw.Step) -> some View {
        switch step {
        case .token:
            TokenPicker(title: "Select a token", groups: assets.groups) { flow.select($0) }
        case .network:
            NetworkPicker(title: "Select a network", subtitle: nil, tokens: flow.group?.tokens ?? []) {
                flow.choose($0)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                NavButton(glyph: .close) { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if flow.result != nil {
                finished
            } else {
                // safeAreaInset keeps the button against the bottom edge whatever the
                // content height.
                form.safeAreaInset(edge: .bottom) { withdrawButton }
            }
        }
        .background(Color.surface)
        // The button stays at the bottom of the screen and the keyboard rides over it,
        // rather than the whole layout being pushed up to make room.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task {
            prefill()
            follow(flow.token?.chain)
        }
        // Validation and the default address both follow whichever network is chosen.
        .onChange(of: flow.token?.chain) { _, chain in follow(chain) }
        .onChange(of: flow.destination) { _, _ in flow.failure = nil }
        .onChange(of: flow.amount) { _, _ in flow.failure = nil }
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Withdraw.")
                    .haffer(30)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)

                Text("Withdraw funds from the payment to any address.")
                    .haffer(15, .regular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 28)

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Text("Withdraw").haffer(18, .regular)
                        SelectorButton(placeholder: "Select token", symbol: flow.group?.symbol) {
                            flow.path = [.token]
                        }
                    }
                    HStack(spacing: 12) {
                        Text("on").haffer(18, .regular)
                        SelectorButton(placeholder: "Select network", chain: flow.token?.chain) {
                            flow.path = flow.group == nil ? [.token] : [.network]
                        }
                    }
                    Text("to the address specified below.")
                        .haffer(17, .regular)
                }
                .padding(.bottom, 28)

                field("Amount", text: $flow.amount, field: .amount)
                    .keyboardType(.decimalPad)
                    .onChange(of: flow.amount) { _, new in
                        let clean = Format.sanitize(new, decimals: flow.token?.decimals ?? 8)
                        if clean != new { flow.amount = clean }
                    }

                HStack(spacing: 8) {
                    TextField("Address", text: $flow.destination)
                        .haffer(16, .regular)
                        .focused($focus, equals: .address)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !flow.destination.isEmpty {
                        Button {
                            flow.destination = ""
                            focus = .address
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear address")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.card, in: .capsule)
                .padding(.top, 10)

                if flow.busy {
                    GridWave(cell: 6, gap: 3)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                } else if let message = notice {
                    // Same treatment quote problems get on the review screen.
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 16))
                        Text(message)
                            .haffer(15, .regular)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                }

            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            // Anywhere off the fields dismisses the keyboard. Buttons still win the tap.
            .contentShape(Rectangle())
            .onTapGesture { focus = nil }
        }
        .frame(maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
    }

    // Whatever the user needs to know about their input, one at a time.
    private var notice: String? {
        if let failure = flow.failure { return failure }
        guard !flow.destination.isEmpty, !flow.addressValid else { return nil }
        return flow.token == nil
            ? "Pick a network to check this address."
            : "Not a valid \(flow.family?.rawValue ?? "") address."
    }

    // Pinned outside the scroll view so it stays against the bottom of the modal.
    private var withdrawButton: some View {
        PillButton(title: "Withdraw", disabled: !flow.ready) {
            Task { if await flow.run() { onFinished() } }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(Color.surface)
    }

    private func field(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .haffer(16, .regular)
            .focused($focus, equals: field)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.card, in: .capsule)
            .padding(.top, 10)
    }

    private var finished: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(flow.result?.status == "SUCCESS" ? "Withdrawal complete." : "Withdrawal submitted.")
                .haffer(30)
                .multilineTextAlignment(.center)
            Text(flow.result?.status == "SUCCESS"
                 ? "The funds have been sent to that address."
                 : "It is confirming onchain and will land shortly.")
                .haffer(15, .regular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            PillButton(title: "Done") { dismiss() }
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
    }
}
