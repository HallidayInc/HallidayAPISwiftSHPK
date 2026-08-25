import CryptoKit
import Foundation
import Observation
import SwiftDraw
import UIKit

@MainActor
@Observable
final class AssetStore {
    static let allowedSymbols: Set<String> = [
        "AAVE", "AERO", "ARB", "AVAX", "BNB", "BONK", "BTC", "ETH", "HYPE",
        "JUP", "LDO", "LINK", "LIT", "MEGA", "MON", "POL", "PROS", "PUSD", "SHIB",
        "SKY", "SOL", "TRX", "UNI", "USDC", "USDT", "USDT0", "WAVAX", "WBTC", "WETH",
        "WIF",
    ]

    static let allowedChains: Set<String> = [
        "arbitrum", "avalanche", "base", "bitcoin", "bsc", "ethereum",
        "hyperevm", "lighter", "megaeth", "monad", "optimism", "pharos",
        "polygon", "robinhood", "solana", "stable", "tron", "unichain", "world",
    ]

    static let symbolAliases: [String: String] = [
        "USDCE": "USDC",
        "USDT0": "USDT",
    ]

    var tokens: [Token] = []
    var groups: [TokenGroup] = []
    var chains: [String: ChainInfo] = [:]
    // The coin gas is paid in. Kept apart from tokens because a chain's gas coin is not
    // always in the symbol allowlist.
    var gasTokens: [String: Token] = [:]
    var icons: [URL: UIImage] = [:]

    func load() async {
        do {
            async let tokenList = Halliday.tokens()
            async let chainList = Halliday.chains()
            let (allTokens, allChains) = try await (tokenList, chainList)
            chains = allChains.filter { Self.allowedChains.contains($0.key) }
            tokens = allTokens.filter {
                chains[$0.chain]?.family != nil && Self.allowedSymbols.contains(Self.display($0).uppercased())
            }
            gasTokens = Dictionary(
                allTokens.filter { chains[$0.chain] != nil && $0.address.lowercased() == "0x" }
                    .map { ($0.chain, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            groups = Self.group(tokens)
        } catch {
            Toast.shared.report(error)
        }
        await loadIcons()
    }

    func groups(matching ids: Set<String>) -> [TokenGroup] {
        Self.group(tokens.filter { ids.contains($0.priceKey) })
    }

    func family(_ chain: String) -> ChainFamily? {
        chains[chain]?.family
    }

    private static func display(_ token: Token) -> String {
        symbolAliases[token.symbol.uppercased()] ?? token.symbol
    }

    private static func group(_ tokens: [Token]) -> [TokenGroup] {
        let groups = Dictionary(grouping: tokens, by: display)
            .map { symbol, matches in
                var byChain: [String: Token] = [:]
                for token in matches where byChain[token.chain] == nil || token.symbol == symbol {
                    byChain[token.chain] = token
                }
                let unique = byChain.values.sorted { $0.chain < $1.chain }
                let canonical = unique.first { $0.symbol == symbol } ?? unique.first
                return TokenGroup(symbol: symbol, imageURL: canonical?.imageURL, tokens: unique)
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
