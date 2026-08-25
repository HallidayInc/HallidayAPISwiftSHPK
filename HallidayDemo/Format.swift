import Foundation

enum Format {
    static let tolerance = Decimal(string: "0.01")!

    static func amount(_ value: Decimal, price: Decimal?, rounding: NSDecimalNumber.RoundingMode = .plain) -> String {
        let digits = fractionDigits(price: price)
        var rounded = Decimal()
        var input = value
        NSDecimalRound(&rounded, &input, digits, rounding)
        return rounded.formatted(.number.precision(.fractionLength(0...digits)))
    }

    // Keeps a field to a single well-formed decimal, whatever the keyboard or a paste supplies.
    static func sanitize(_ text: String, decimals: Int) -> String {
        var out = ""
        var hasSeparator = false
        for character in text {
            if character.isNumber {
                out.append(character)
            } else if (character == "." || character == ",") && !hasSeparator {
                out.append(".")
                hasSeparator = true
            }
        }
        if let dot = out.firstIndex(of: ".") {
            let fraction = out[out.index(after: dot)...]
            if fraction.count > decimals {
                out = String(out[..<dot]) + (decimals == 0 ? "" : "." + fraction.prefix(decimals))
            }
        }
        while out.count > 1 && out.hasPrefix("0") && !out.hasPrefix("0.") {
            out.removeFirst()
        }
        return out
    }

    static func usd(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD"))
    }

    // Smallest number of decimals where one unit in the last place is worth <= $0.01,
    // so a rounded amount never drifts far enough to underfund a deposit.
    static func fractionDigits(price: Decimal?) -> Int {
        guard let price, price > 0 else { return 8 }
        var digits = 2
        while digits < 18 {
            if price * Decimal(sign: .plus, exponent: -digits, significand: 1) <= tolerance { break }
            digits += 1
        }
        return digits
    }
}
