// Rewrites a plain decimal too long for `Double(_:)` / `Float(_:)` into a short one they round exactly.
//
// Only reached when the standard library returned nil for the original text: it rejects a decimal tens of
// thousands of digits long, on Linux and for some inputs on macOS, though that is still a valid JSON number
// and must not come back as NaN.
enum LongDecimal {
    // The most significant digits a decimal needs to round to the right `Double` or `Float`: a binary64
    // value is decided by its first 767 digits, so 768 plus a sticky digit for anything nonzero beyond
    // them rounds exactly as the full decimal would.
    static let maxSignificantDigits = 768

    // The digits of a decimal without its leading zeros, cut to `maxSignificantDigits`, and the power of ten
    // they stand for.
    private struct Mantissa {
        var kept: [UInt8] = []
        var seen = 0  // significant digits seen, kept or not
        var droppedNonzero = false
        var exponent = 0
    }

    // `<digits>e<exponent>` with at most `maxSignificantDigits` significant digits and a trailing sticky `1`
    // when a nonzero digit was dropped (or, when none was, with its trailing zeros folded into the exponent).
    // The exponent saturates, so a huge one still reads as overflow or underflow. Returns nil for anything
    // that is not a plain decimal.
    @inline(never)
    static func normalized(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> String? {
        var i = offset
        let end = offset + length
        var negative = false
        if i < end, unsafe p[i] == 0x2D {
            negative = true
            i += 1
        }
        guard var mantissa = unsafe scanMantissa(p, &i, end), let exponent = unsafe scanExponent(p, &i, end),
            i == end
        else { return nil }
        let sign = negative ? "-" : ""
        if mantissa.kept.isEmpty { return sign + "0" }
        mantissa.exponent += exponent + mantissa.seen - mantissa.kept.count  // dropped digits scale the value up
        if mantissa.droppedNonzero {
            mantissa.kept.append(0x31)
            mantissa.exponent -= 1
        } else {
            // Nothing nonzero was dropped, so trailing zeros only pad: trim them into the exponent and hand the
            // standard library a short string, which it rounds exactly.
            while mantissa.kept.count > 1, mantissa.kept[mantissa.kept.count - 1] == 0x30 {
                mantissa.kept.removeLast()
                mantissa.exponent += 1
            }
        }
        return sign + String(decoding: mantissa.kept, as: UTF8.self) + "e" + String(mantissa.exponent)
    }

    // The integer and fraction digits from `i`, leaving `i` at the first byte that is neither. Nil when there
    // is no digit at all.
    private static func scanMantissa(_ p: UnsafePointer<UInt8>, _ i: inout Int, _ end: Int) -> Mantissa? {
        var mantissa = Mantissa()
        var sawDigit = false
        var inFraction = false
        while i < end {
            let c = unsafe p[i]
            if c == 0x2E, !inFraction {
                inFraction = true
                i += 1
                continue
            }
            guard c >= 0x30, c <= 0x39 else { break }
            sawDigit = true
            i += 1
            if inFraction { mantissa.exponent -= 1 }
            if c == 0x30, mantissa.seen == 0 { continue }
            mantissa.seen += 1
            if mantissa.kept.count < maxSignificantDigits {
                mantissa.kept.append(c)
            } else if c != 0x30 {
                mantissa.droppedNonzero = true
            }
        }
        return sawDigit ? mantissa : nil
    }

    // The signed value of an `e` / `E` part at `i`, saturating at 2^40; zero when there is none. Nil when the
    // part has no digit.
    private static func scanExponent(_ p: UnsafePointer<UInt8>, _ i: inout Int, _ end: Int) -> Int? {
        guard i < end, unsafe p[i] == 0x65 || p[i] == 0x45 else { return 0 }
        i += 1
        var negative = false
        if i < end, unsafe p[i] == 0x2D {
            negative = true
            i += 1
        } else if i < end, unsafe p[i] == 0x2B {
            i += 1
        }
        var value = 0
        var sawDigit = false
        while i < end, unsafe p[i] >= 0x30, unsafe p[i] <= 0x39 {
            if value < 1 << 40 { value = value * 10 + Int(unsafe p[i] - 0x30) }
            sawDigit = true
            i += 1
        }
        guard sawDigit else { return nil }
        return negative ? -value : value
    }
}
