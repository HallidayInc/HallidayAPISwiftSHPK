import SwiftUI

// Rendered in content rather than as a navigationTitle: SwiftUI installs its own bar
// appearance per screen, which intermittently overrode the Haffer font on the title.
struct PickerTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .haffer(22)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
    }
}

struct TokenIcon: View {
    @Environment(AssetStore.self) private var assets
    let url: URL?
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(.white)
            if let url, let image = assets.icons[url] {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Circle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

struct ChainBadge: View {
    @Environment(AssetStore.self) private var assets
    @Environment(\.colorScheme) private var colorScheme
    let chain: String
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Color.white
            if let url = assets.chains[chain]?.image, let image = assets.icons[url] {
                Image(uiImage: image).resizable().scaledToFit().padding(3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 5))
        .overlay {
            // The white plate vanishes against a light background without an outline.
            // strokeBorder keeps the line fully inside the shape so its width stays uniform;
            // stroke() straddles the edge and gets clipped unevenly.
            if colorScheme == .light {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.black, lineWidth: 1)
            }
        }
    }
}

struct NetworkIcons: View {
    @Environment(AssetStore.self) private var assets
    let tokens: [Token]
    private let limit = 6
    private let size: CGFloat = 20

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tokens.sorted { $0.chain < $1.chain }.prefix(limit)) { token in
                ChainBadge(chain: token.chain, size: size)
            }
            if tokens.count > limit {
                Text("+\(tokens.count - limit)")
                    .haffer(11, .regular)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
    }
}

struct TokenPicker: View {
    let title: String
    var subtitle: String? = nil
    let groups: [TokenGroup]
    let onSelect: (TokenGroup) -> Void
    @State private var search = ""

    private var filtered: [TokenGroup] {
        guard !search.isEmpty else { return groups }
        return groups.filter {
            $0.symbol.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PickerTitle(title)

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
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            List {
            if let subtitle {
                Text(subtitle)
                    .haffer(15, .regular)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(filtered) { group in
                Button {
                    onSelect(group)
                } label: {
                    HStack(spacing: 12) {
                        TokenIcon(url: group.imageURL)
                        Text(group.symbol).haffer(16)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        NetworkIcons(tokens: group.tokens)
                    }
                }
                .tint(.primary)
            }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NetworkPicker: View {
    @Environment(AssetStore.self) private var assets
    let title: String
    let subtitle: String?
    let tokens: [Token]
    let onSelect: (Token) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PickerTitle(title)

            List {
            if let subtitle {
                Text(subtitle)
                    .haffer(15, .regular)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(tokens.sorted { $0.chain < $1.chain }) { token in
                Button {
                    onSelect(token)
                } label: {
                    HStack(spacing: 12) {
                        TokenIcon(url: assets.chains[token.chain]?.image)
                        Text(token.chain.capitalized).haffer(16)
                        Spacer()
                    }
                }
                .tint(.primary)
            }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
