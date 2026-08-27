import SwiftUI
import WalletCore

@MainActor
@Observable
final class RecentAddresses {
    static let shared = RecentAddresses()
    private static let key = "recentAddresses"
    private static let limit = 20

    private(set) var all: [String]

    private init() {
        all = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func remember(_ address: String) {
        all.removeAll { $0.caseInsensitiveCompare(address) == .orderedSame }
        all.insert(address, at: 0)
        if all.count > Self.limit { all.removeLast(all.count - Self.limit) }
        UserDefaults.standard.set(all, forKey: Self.key)
    }

    // Only addresses the destination chain could actually accept.
    func valid(for family: ChainFamily) -> [String] {
        all.filter { AnyAddress.isValid(string: $0, coin: family.coin) }
    }
}

struct AddressView: View {
    @Bindable var flow: DepositFlow
    @State private var typed = ""
    @State private var picked: String?
    private let recents = RecentAddresses.shared

    private var family: ChainFamily? { flow.outputFamily }

    private var typedIsValid: Bool {
        guard let family, !typed.isEmpty else { return false }
        return AnyAddress.isValid(string: typed, coin: family.coin)
    }

    private var chosen: String? {
        if let picked { return picked }
        return typedIsValid ? typed : nil
    }

    private var placeholder: String {
        switch family {
        case .evm: "0x..."
        case .solana: "Solana address"
        case nil: "Address"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Input an address to withdraw to.")
                .haffer(30)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            Text("This address will receive \(flow.output?.symbol ?? "") on \(flow.output?.chain.capitalized ?? "").")
                .haffer(17, .regular)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .padding(.bottom, 32)

            HStack(spacing: 8) {
                TextField(placeholder, text: $typed)
                    .haffer(15, .regular)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: typed) { _, new in
                        // The two inputs are mutually exclusive.
                        if !new.isEmpty { picked = nil }
                    }
                Button("Paste") {
                    typed = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                .haffer(15, .regular)
                .tint(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color.card, in: .capsule)

            if !typed.isEmpty && !typedIsValid {
                Text("Not a valid \(family?.rawValue ?? "") address.")
                    .haffer(13, .regular)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .padding(.leading, 4)
            }

            let addresses = family.map(recents.valid(for:)) ?? []
            if !addresses.isEmpty {
                Text("RECENT ADDRESSES")
                    .haffer(12, .regular)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
                    .padding(.leading, 4)
                    .padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(addresses, id: \.self) { address in
                            Button {
                                picked = picked == address ? nil : address
                                typed = ""
                            } label: {
                                HStack(spacing: 12) {
                                    Text(address)
                                        .haffer(14, .regular)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: picked == address ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(picked == address ? Color.crtGlyph : Color.secondary)
                                }
                                .padding(.vertical, 14)
                            }
                            .tint(.primary)
                            Rectangle()
                                .fill(Color.hairline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 1)
                        }
                    }
                }
            }

            Spacer(minLength: 16)

            PillButton(title: "Continue", disabled: chosen == nil) {
                guard let chosen else { return }
                flow.destinationAddress = chosen
                recents.remember(chosen)
                flow.fetchQuote()
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .navigationBarTitleDisplayMode(.inline)
    }
}
