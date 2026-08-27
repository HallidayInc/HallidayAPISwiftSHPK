import SwiftUI
import WalletCore

struct SendView: View {
    @AppStorage("showAllTokens") private var showAllTokens = false
    @Environment(\.dismiss) private var dismiss
    @State private var flow: SendFlow
    @State private var search = ""

    init(wallet: Wallet, assets: AssetStore, balances: BalanceStore) {
        _flow = State(initialValue: SendFlow(wallet: wallet, assets: assets, balances: balances))
    }

    private var assets: [SendAsset] {
        let all = flow.sendable(showAll: showAllTokens)
        guard !search.isEmpty else { return all }
        return all.filter { $0.symbol.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack(path: $flow.path) {
            VStack(spacing: 0) {
                PickerTitle("Select a token to send")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    TextField("Search name or symbol", text: $search)
                        .haffer(16, .regular)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.card, in: .capsule)
                .padding(.bottom, 8)

                List(assets) { asset in
                    Button {
                        flow.select(asset)
                    } label: {
                        HStack(spacing: 12) {
                            TokenIcon(url: asset.imageURL)
                            Text(asset.symbol).haffer(16)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            ChainBadges(chains: asset.chains)
                        }
                    }
                    .tint(.primary)
                }
                .listStyle(.plain)
                .overlay {
                    if assets.isEmpty {
                        Text("Nothing to send yet.")
                            .haffer(15, .regular)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .navBar(trailing: .close, onTrailing: { dismiss() })
            .navigationDestination(for: SendStep.self) { step in
                destination(step)
                    .navBar(
                        leading: step == .sending ? nil : .back,
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
    private func destination(_ step: SendStep) -> some View {
        switch step {
        case .network: SendNetworkView(flow: flow)
        case .amount: SendAmountView(flow: flow)
        case .address: SendAddressView(flow: flow)
        case .review: SendReviewView(flow: flow)
        case .sending: SendStatusView(flow: flow)
        }
    }
}

struct ChainBadges: View {
    let chains: [String]
    private let limit = 6

    var body: some View {
        HStack(spacing: 4) {
            ForEach(chains.prefix(limit), id: \.self) { chain in
                ChainBadge(chain: chain, size: 20)
            }
            if chains.count > limit {
                Text("+\(chains.count - limit)")
                    .haffer(11, .regular)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
    }
}

struct SendNetworkView: View {
    @Bindable var flow: SendFlow

    var body: some View {
        VStack(spacing: 0) {
            PickerTitle("Select a network")

            Text("Networks you hold \(flow.asset?.symbol ?? "") on.")
                .haffer(15, .regular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)

            List(flow.asset?.balances.sorted { $0.chain < $1.chain } ?? []) { balance in
                Button {
                    flow.choose(balance)
                } label: {
                    HStack(spacing: 12) {
                        ChainBadge(chain: balance.chain, size: 32)
                        Text(balance.chain.capitalized).haffer(16)
                        Spacer()
                        Text(Format.amount(balance.amount, price: balance.unitPrice))
                            .haffer(15, .regular)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            .listStyle(.plain)
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SendAmountView: View {
    @Bindable var flow: SendFlow
    @FocusState private var focused: Bool

    private var balance: Decimal { flow.selected?.amount ?? 0 }
    private var symbol: String { flow.selected?.symbol ?? "" }
    private var typed: Decimal { Decimal(string: flow.amount) ?? 0 }
    private var overBalance: Bool { typed > flow.maxSendable }

    private var amountSize: CGFloat {
        switch flow.amount.count + symbol.count {
        case ...10: 44
        case 11...13: 38
        case 14...17: 30
        case 18...22: 24
        default: 20
        }
    }

    private var amountText: Text {
        let font = Theme.font(amountSize, .medium)
        return Text(flow.amount.isEmpty ? "0" : flow.amount)
            .font(font)
            .foregroundColor(flow.amount.isEmpty ? .secondary : .primary)
            + Text(" " + symbol).font(font).foregroundColor(.secondary)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Input the amount to send.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            Spacer()

            ZStack {
                TextField("", text: $flow.amount)
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .opacity(0.01)
                    .frame(width: 1, height: 1)
                    .onChange(of: flow.amount) { _, new in
                        let clean = Format.sanitize(new, decimals: flow.selected?.decimals ?? 8)
                        if clean != new { flow.amount = clean }
                    }

                amountText
                    .tracking(Theme.tracking(amountSize))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .lineSpacing(0)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
            }

            if let price = flow.selected?.unitPrice {
                Text(Format.usd(typed * price))
                    .haffer(13, .regular)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
            }

            if overBalance {
                Text(flow.gasBuffer > 0
                     ? "More than your \(symbol) balance after fees."
                     : "More than your \(symbol) balance.")
                    .haffer(13, .regular)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                portion("25%", flow.maxSendable * Decimal(string: "0.25")!)
                portion("50%", flow.maxSendable * Decimal(string: "0.5")!)
                portion("Max", flow.maxSendable)
            }
            .padding(.top, 32)

            Spacer()

            PillButton(title: "Continue", disabled: typed <= 0 || overBalance) {
                flow.path.append(.address)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func portion(_ title: String, _ value: Decimal) -> some View {
        Button(title) {
            flow.amount = Format.sanitize("\(value)", decimals: flow.selected?.decimals ?? 8)
        }
        .haffer(15, .regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.card, in: .capsule)
        .tint(.primary)
    }
}

struct SendAddressView: View {
    @Bindable var flow: SendFlow
    @FocusState private var focused: Bool

    private var isValid: Bool {
        guard let family = flow.family, !flow.destination.isEmpty else { return false }
        return AnyAddress.isValid(string: flow.destination, coin: family.coin)
    }

    private var placeholder: String {
        switch flow.family {
        case .evm: "0x..."
        case .solana: "Solana address"
        case nil: "Address"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Input an address to send to.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            Text("This address will receive \(flow.selected?.symbol ?? "") on \(flow.selected?.chain.capitalized ?? "").")
                .haffer(15, .regular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .padding(.bottom, 32)

            HStack(spacing: 8) {
                TextField(placeholder, text: $flow.destination)
                    .haffer(15, .regular)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                Button("Paste") {
                    flow.destination = UIPasteboard.general.string?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    focused = false
                }
                .haffer(15, .regular)
                .tint(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color.card, in: .capsule)

            if !flow.destination.isEmpty && !isValid {
                Text("Not a valid \(flow.family?.rawValue ?? "") address.")
                    .haffer(13, .regular)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .padding(.leading, 4)
            }

            Spacer()

            PillButton(title: "Continue", disabled: !isValid) {
                flow.path.append(.review)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SendReviewView: View {
    @Bindable var flow: SendFlow

    var body: some View {
        VStack(spacing: 0) {
            Text("Review and confirm your send.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)

            hairline
            row("You send", "\(flow.amount) \(flow.selected?.symbol ?? "")", flow.selected?.chain)
            hairline
            row("To", flow.destination, nil)
            hairline

            if let shortfall = flow.gasShortfall {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 16))
                    Text(shortfall)
                        .haffer(15, .regular)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 16)
            }

            Spacer()

            PillButton(title: "Send", disabled: !flow.canSend) { flow.send() }
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hairline: some View {
        Rectangle().fill(Color.hairline).frame(maxWidth: .infinity).frame(height: 1)
    }

    private func row(_ label: String, _ value: String, _ chain: String?) -> some View {
        HStack(alignment: .top) {
            Text(label).haffer(17, .regular)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .haffer(17)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let chain {
                    Text(chain.capitalized).haffer(13, .regular).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 18)
    }
}

struct SendStatusView: View {
    @Bindable var flow: SendFlow

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if flow.txHash == nil {
                ProgressView().controlSize(.large)
                Text("Sending.")
                    .haffer(22)
                    .padding(.top, 16)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.crtGlyph)
                Text("Sent.")
                    .haffer(22)
                    .padding(.top, 16)
            }

            if let hash = flow.txHash {
                Button {
                    Toast.copy(hash, label: "Transaction")
                } label: {
                    Text(hash)
                        .haffer(13, .regular)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
                .padding(.top, 12)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 44)
        .navigationBarTitleDisplayMode(.inline)
    }
}
