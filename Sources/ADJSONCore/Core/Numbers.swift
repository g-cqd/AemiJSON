// Number materialization over a byte range.
public enum JSONNumber {
    // Exactly-representable powers of ten (10^0 … 10^22). 10^22 = 5^22 · 2^22 and 5^22 < 2^53, so
    // every entry is an exact `Double`; 10^23 is the first that is not, which fixes the fast-path
    // exponent bound below.
    static let pow10: [Double] = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
        1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
    ]

    // Parse a (scanner-validated) JSON number. The Clinger fast path handles the common case without
    // building a `String`; anything outside its provably-correct domain falls back to the
    // locale-independent `Double(_:)`.
    //
    // `Double(_:)` parses with fixed C-locale semantics, unlike libc `strtod`, which honours the
    // host `LC_NUMERIC` and would misread "1.5" as 1.0 under a comma-decimal locale. It only fails
    // on out-of-range magnitudes, which round to ±inf exactly as `strtod` did. Short numbers
    // (≤15 UTF-8 bytes) use the inline small-string buffer, so no heap allocation occurs.
    @inline(__always)
    public static func parseDouble(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Double {
        if let fast = parseDoubleFast(p, offset, length) { return fast }
        // The slow path also covers the JSON5-only spellings (Infinity / NaN / hex). The fast path
        // already returned for every strict/lenient number it can, so this never runs on their hot
        // path; only a long/extreme decimal reaches here and `parseJSON5Number` returns nil for it.
        if let json5 = parseJSON5Number(p, offset, length) { return json5 }
        let s = String(decoding: UnsafeBufferPointer(start: p + offset, count: length), as: UTF8.self)
        return Double(s) ?? .nan
    }

    // Parse the JSON5-only number spellings — `Infinity`, `NaN`, and hexadecimal (`0x…`) — returning
    // the value, or nil for an ordinary decimal (left to `Double(_:)`).
    @inline(__always)
    static func parseJSON5Number(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Double? {
        var idx = offset
        let end = offset + length
        guard idx < end else { return nil }
        var sign = 1.0
        if p[idx] == 0x2D {
            sign = -1
            idx += 1
        } else if p[idx] == 0x2B {
            idx += 1
        }
        guard idx < end else { return nil }
        switch p[idx] {
        case 0x49: return sign * .infinity  // 'I' Infinity
        case 0x4E: return .nan  // 'N' NaN
        case 0x30 where idx + 1 < end && (p[idx + 1] == 0x78 || p[idx + 1] == 0x58):  // 0x / 0X
            var value = 0.0
            var k = idx + 2
            while k < end, let d = hexDigitValue(p[k]) {
                value = value * 16 + Double(d)
                k += 1
            }
            return k > idx + 2 ? sign * value : nil
        default: return nil
        }
    }

    @inline(__always)
    static func hexDigitValue(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        default: return nil
        }
    }

    // Clinger fast path. When the decimal significand fits in 2^53 (so `Double(significand)` is
    // exact) and the net power of ten is within ±22 (so `pow10[..]` is exact), a single IEEE
    // multiply/divide is correctly rounded — bit-identical to `Double(_:)`. Returns `nil` (→ slow
    // path) for anything else: ≥20 significand digits, an out-of-range exponent, or any byte the
    // re-scan doesn't consume.
    @inline(__always)
    static func parseDoubleFast(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Double? {
        var i = offset
        let end = offset + length
        guard i < end else { return nil }
        var negative = false
        if p[i] == 0x2D {
            negative = true
            i += 1
        }
        var significand: UInt64 = 0
        var digits = 0
        var exponent = 0  // power of ten still to apply

        while i < end, p[i] >= 0x30, p[i] <= 0x39 {
            significand = significand &* 10 &+ UInt64(p[i] - 0x30)
            digits += 1
            i += 1
            if digits > 19 { return nil }  // would overflow UInt64 / exceed 2^53
        }
        if i < end, p[i] == 0x2E {
            i += 1
            while i < end, p[i] >= 0x30, p[i] <= 0x39 {
                significand = significand &* 10 &+ UInt64(p[i] - 0x30)
                digits += 1
                exponent -= 1
                i += 1
                if digits > 19 { return nil }
            }
        }
        if i < end, p[i] == 0x65 || p[i] == 0x45 {  // e / E
            i += 1
            var expNegative = false
            if i < end, p[i] == 0x2D {
                expNegative = true
                i += 1
            } else if i < end, p[i] == 0x2B {
                i += 1
            }
            var e = 0
            var sawExpDigit = false
            while i < end, p[i] >= 0x30, p[i] <= 0x39 {
                if e < 1_000_000 { e = e * 10 + Int(p[i] - 0x30) }
                sawExpDigit = true
                i += 1
            }
            guard sawExpDigit else { return nil }
            exponent += expNegative ? -e : e
        }
        // The re-scan must have consumed the whole (validated) number, the significand must be
        // exact, and the exponent must keep `pow10` exact.
        guard i == end, digits > 0, significand <= (1 << 53), exponent >= -22, exponent <= 22 else {
            return nil
        }
        var d = Double(significand)
        if exponent > 0 {
            d *= pow10[exponent]
        } else if exponent < 0 {
            d /= pow10[-exponent]
        }
        return negative ? -d : d
    }

    // Generic integer parse with correct overflow handling for any width, signed or
    // unsigned (negatives accumulate downward so Int.min and UInt.max both work).
    @inline(__always)
    public static func parseInteger<T: FixedWidthInteger>(
        _ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int, _ type: T.Type
    ) -> T? {
        var idx = offset
        let end = offset + length
        guard idx < end else { return nil }
        var neg = false
        if p[idx] == 0x2D {
            neg = true
            idx += 1
            if !T.isSigned { return nil }
        } else if p[idx] == 0x2B {
            idx += 1
        }
        guard idx < end else { return nil }
        // JSON5 hex literal `0x…` (only emitted in json5 mode — a strict/lenient integer token never
        // starts with `0x`, so this is a single predictable branch off the common decimal path).
        if p[idx] == 0x30, idx + 1 < end, p[idx + 1] == 0x78 || p[idx + 1] == 0x58 {
            return parseHexInteger(p, idx + 2, end, neg, T.self)
        }
        var v: T = 0
        let ten = T(10)
        while idx < end {
            let c = p[idx]
            guard c >= 0x30 && c <= 0x39 else { return nil }
            let d = T(truncatingIfNeeded: c - 0x30)
            let (m, o1) = v.multipliedReportingOverflow(by: ten)
            guard !o1 else { return nil }
            if neg {
                let (s, o2) = m.subtractingReportingOverflow(d)
                guard !o2 else { return nil }
                v = s
            } else {
                let (a, o2) = m.addingReportingOverflow(d)
                guard !o2 else { return nil }
                v = a
            }
            idx += 1
        }
        return v
    }

    // Parse a JSON5 hex integer body (the digits after `0x`) into any fixed-width type, with correct
    // overflow handling; a negative sign accumulates downward so `Int.min` magnitudes still fit.
    @inline(__always)
    static func parseHexInteger<T: FixedWidthInteger>(
        _ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ neg: Bool, _ type: T.Type
    ) -> T? {
        guard start < end else { return nil }
        var v: T = 0
        let sixteen = T(16)
        var idx = start
        while idx < end {
            guard let digit = hexDigitValue(p[idx]) else { return nil }
            let d = T(truncatingIfNeeded: digit)
            let (m, o1) = v.multipliedReportingOverflow(by: sixteen)
            guard !o1 else { return nil }
            if neg {
                let (s, o2) = m.subtractingReportingOverflow(d)
                guard !o2 else { return nil }
                v = s
            } else {
                let (a, o2) = m.addingReportingOverflow(d)
                guard !o2 else { return nil }
                v = a
            }
            idx += 1
        }
        return v
    }
}
