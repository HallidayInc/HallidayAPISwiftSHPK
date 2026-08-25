import Foundation

// Pinned entries sort to the top in the order listed; everything else stays alphabetical.
enum Preferred {
    static let tokens = ["USDC", "USDT", "ETH", "SOL"]
    static let currencies = ["USD"]
    static let methods = ["DEBIT_CARD"]

    static func rank(_ value: String, in pinned: [String]) -> Int {
        pinned.firstIndex(of: value.uppercased()) ?? pinned.count
    }

    static func sort<T>(_ items: [T], pinned: [String], by key: (T) -> String) -> [T] {
        items.sorted { (rank(key($0), in: pinned), key($0)) < (rank(key($1), in: pinned), key($1)) }
    }

    // Pin on the raw value, but order the rest by how the label reads.
    static func sort<T>(_ items: [T], pinned: [String], by key: (T) -> String, label: (T) -> String) -> [T] {
        items.sorted { (rank(key($0), in: pinned), label($0)) < (rank(key($1), in: pinned), label($1)) }
    }
}
