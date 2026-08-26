import Foundation

enum Units {
    // Minimal big-endian bytes, by long division, because 18-decimal values overflow UInt64.
    static func bytes(_ amount: String, decimals: Int) -> Data {
        var digits = whole(amount, decimals: decimals).compactMap(\.wholeNumberValue)
        var out: [UInt8] = []
        while digits.contains(where: { $0 != 0 }) {
            var remainder = 0
            var next: [Int] = []
            for digit in digits {
                let current = remainder * 10 + digit
                next.append(current / 256)
                remainder = current % 256
            }
            out.insert(UInt8(remainder), at: 0)
            while next.count > 1 && next.first == 0 { next.removeFirst() }
            digits = next
        }
        return out.isEmpty ? Data([0]) : Data(out)
    }

    static func integer(_ amount: String, decimals: Int) throws -> UInt64 {
        guard let value = UInt64(whole(amount, decimals: decimals)) else {
            throw SendError.signing("That amount is too large to send.")
        }
        return value
    }

    private static func whole(_ amount: String, decimals: Int) -> String {
        var scaled = (Decimal(string: amount) ?? 0) * Decimal(sign: .plus, exponent: decimals, significand: 1)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .down)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}
