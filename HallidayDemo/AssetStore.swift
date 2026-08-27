import CryptoKit
import Foundation
import Observation
import SwiftDraw
import UIKit

@MainActor
@Observable
final class AssetStore {
    static let allowedSymbols: Set<String> = [
        "AAVE", "AERO", "ARB", "AVAX", "BNB", "BONK", "CUSD", "ETH", "HYPE",
        "JUP", "LDO", "LINK", "LIT", "MEGA", "MON", "PATHUSD", "POL", "PROS", "PUSD",
        "SHIB", "SKY", "SOL", "STCUSD", "UNI", "USDC", "USDT", "USDT0", "WAVAX",
        "WBTC", "WETH", "WIF",
    ]

    static let allowedChains: Set<String> = [
        "arbitrum", "avalanche", "base", "bsc", "ethereum", "hyperevm",
        "megaeth", "monad", "optimism", "pharos", "polygon", "robinhood",
        "solana", "stable", "tempo", "unichain", "world",
    ]

    static let symbolAliases: [String: String] = [
        "USDC.E": "USDC",
        "USDCE": "USDC",
        "USDT0": "USDT",
    ]

    var tokens: [Token] = []
    // The same list before aliasing. Grouping needs the original spelling to tell which of
    // two tokens on one chain is the canonical one.
    private var rawTokens: [Token] = []
    // Canonical icon per display symbol. USDT0 ships its own logo, but a user who is told
    // the asset is USDT should see the USDT one.
    private var canonicalIcons: [String: URL] = [:]
    // Every asset Halliday knows, unfiltered. Withdrawal is only possible for these, so it
    // is a wider set than the tokens the app chooses to display.
    var assetIDs: Set<String> = []
    var groups: [TokenGroup] = []
    var chains: [String: ChainInfo] = [:]
    // The coin network fees are paid in. Kept apart from tokens because it is not always
    // in the symbol allowlist.
    var gasTokens: [String: Token] = [:]
    var icons: [URL: UIImage] = [:]

    func load() async {
        do {
            async let tokenList = Halliday.tokens()
            async let chainList = Halliday.chains()
            let (allTokens, allChains) = try await (tokenList, chainList)
            chains = allChains.filter { Self.allowedChains.contains($0.key) }
            assetIDs = Set(allTokens.map(\.priceKey))
            canonicalIcons = Dictionary(
                allTokens.compactMap { token in
                    let name = Self.display(symbol: token.symbol)
                    guard token.symbol.caseInsensitiveCompare(name) == .orderedSame,
                          let image = token.imageURL else { return nil }
                    return (name.uppercased(), image)
                },
                uniquingKeysWith: { first, _ in first }
            )
            rawTokens = allTokens.filter {
                chains[$0.chain]?.family != nil && Self.allowedSymbols.contains(Self.display($0).uppercased())
            }
            gasTokens = Dictionary(
                allTokens.filter { chains[$0.chain] != nil && Native.matches($0.address) }
                    .map { ($0.chain, canonical($0)) },
                uniquingKeysWith: { first, _ in first }
            )
            tokens = rawTokens.map(canonical)
            groups = group(rawTokens)
        } catch {
            Toast.shared.report(error)
        }
        await loadIcons()
    }

    func groups(matching ids: Set<String>) -> [TokenGroup] {
        group(rawTokens.filter { ids.contains($0.priceKey) })
    }

    func family(_ chain: String) -> ChainFamily? {
        chains[chain]?.family
    }

    // Halliday identifies assets as "chain:address". Fiat inputs carry no chain at all.
    func label(for asset: String) -> String {
        if let token = tokens.first(where: { $0.priceKey == asset.lowercased() }) { return token.symbol }
        let parts = asset.split(separator: ":")
        guard parts.count == 2 else { return asset.uppercased() }
        let address = String(parts[1])
        return address.count > 8 ? "\(address.prefix(6))…" : address
    }

    func decimals(for asset: String) -> Int? {
        tokens.first { $0.priceKey == asset.lowercased() }?.decimals
    }

    func chain(for asset: String) -> String? {
        let parts = asset.split(separator: ":")
        return parts.count == 2 ? String(parts[0]) : nil
    }

    // USDT0 and USDCe are the same asset to a user, so they are shown under the canonical
    // spelling wherever a symbol is displayed, balances included.
    static func display(symbol: String) -> String {
        symbolAliases[symbol.uppercased()] ?? symbol
    }

    private static func display(_ token: Token) -> String {
        display(symbol: token.symbol)
    }

    private func canonical(_ token: Token) -> Token {
        let name = Self.display(symbol: token.symbol)
        return Token(
            chain: token.chain,
            address: token.address,
            name: token.name,
            symbol: name,
            decimals: token.decimals,
            imageURL: canonicalIcons[name.uppercased()] ?? token.imageURL
        )
    }

    private func group(_ tokens: [Token]) -> [TokenGroup] {
        let groups = Dictionary(grouping: tokens, by: Self.display)
            .map { symbol, matches in
                var byChain: [String: Token] = [:]
                for token in matches where byChain[token.chain] == nil || token.symbol == symbol {
                    byChain[token.chain] = token
                }
                let unique = byChain.values.sorted { $0.chain < $1.chain }
                let preferred = unique.first { $0.symbol == symbol } ?? unique.first
                // Aliasing happens last so the choices above can still see USDT0 vs USDT.
                let icon = canonicalIcons[symbol.uppercased()] ?? preferred?.imageURL
                return TokenGroup(symbol: symbol, imageURL: icon, tokens: unique.map(canonical))
            }
        return Preferred.sort(groups, pinned: Preferred.tokens, by: \.symbol)
    }

    func cacheIcons(_ urls: [URL]) async {
        let missing = Set(urls).subtracting(icons.keys)
        guard !missing.isEmpty else { return }
        await withTaskGroup(of: (URL, UIImage?).self) { group in
            for url in missing {
                group.addTask { (url, await Self.fetch(url)) }
            }
            for await (url, image) in group where image != nil {
                icons[url] = image
            }
        }
    }

    private func loadIcons() async {
        await cacheIcons(tokens.compactMap(\.imageURL) + chains.values.compactMap(\.image))
    }

    // SwiftDraw resolves <use xlink:href> but not the SVG2 <use href> spelling, which makes it
    // reject the whole document. Rewrite that one attribute before parsing.
    nonisolated private static func linkedSVG(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("<use") else { return data }
        let pattern = try! NSRegularExpression(pattern: "(<use\\b[^>]*?)\\shref=")
        let range = NSRange(text.startIndex..., in: text)
        var patched = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1 xlink:href=")
        guard patched != text else { return data }
        if !patched.contains("xmlns:xlink") {
            patched = patched.replacingOccurrences(
                of: "<svg ",
                with: "<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\" "
            )
        }
        return Data(patched.utf8)
    }

    // Rasterised icons are cached on disk so later launches skip the network and the SVG parse.
    nonisolated private static func cacheFile(for url: URL) -> URL {
        let directory = URL.cachesDirectory.appending(path: "icons")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".png")
    }

    nonisolated private static func fetch(_ url: URL) async -> UIImage? {
        let file = cacheFile(for: url)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            return image
        }
        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        let image = url.pathExtension.lowercased() == "svg"
            ? SVG(data: linkedSVG(data))?.rasterize(size: CGSize(width: 64, height: 64))
            : UIImage(data: data)
        if let png = image?.pngData() {
            try? png.write(to: file)
        }
        return image
    }
}
