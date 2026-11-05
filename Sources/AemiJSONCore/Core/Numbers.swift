import AemiKernel

// Number materialization over a byte range.
public enum JSONNumber {
    // The decimal scan, the fast paths and the long-decimal slow path are aemi's (`DecimalScanner`,
    // `DecimalFloat`, aemi ADR 0031), promoted from this file: one implementation for JSON, TOML and
    // YAML. What stays here is JSON's own: the JSON5 spellings, integers, and the hexadecimal forms.
    //
    // Parse a (scanner-validated) JSON number. A plain decimal goes through aemi's scanner (eight digits
    // at a time, zeros that only pad costing nothing) and Clinger, Eisel-Lemire, or the locale-independent
    // `Double(_:)` on a short rewrite of a very long decimal; never libc `strtod`, which honours the host
    // `LC_NUMERIC` and would misread "1.5" as 1.0 under a comma-decimal locale.
    @inline(__always)
    public static func parseDouble(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Double {
        // Caller owns `p[offset ..< offset + length]` for this call; `p` is read-only and never escapes.
        let (buffer, literal) = unsafe decimal(p, offset, length)
        if let literal { return unsafe DecimalFloat.double(literal, in: buffer) }
        // The JSON5 spellings (Infinity / NaN / hex), then what `Double(_:)` reads that the scanner does not
        // (a JSON5 `.5` or `5.`).
        if let json5 = unsafe parseJSON5Number(p, offset, length) { return json5 }
        return unsafe Double(String(decoding: buffer, as: UTF8.self)) ?? .nan
    }

    // Parse a (scanner-validated) JSON number to `Float`, **correctly rounded to the nearest Float**.
    //
    // This must NOT be `Float(parseDouble(...))`: parsing the decimal to `Double` and then narrowing
    // to `Float` rounds twice (decimal→Double, then Double→Float), which for some short decimals lands
    // on a different `Float` bit pattern than rounding the decimal straight to the nearest `Float`
    // (double-rounding error). The encoder emits the shortest `Float` decimal (`Float.description`), so
    // decode must invert it at `Float` width to round-trip the exact bit pattern: aemi's
    // `DecimalFloat.float(_:in:)` rounds once.
    @inline(__always)
    public static func parseFloat(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Float {
        let (buffer, literal) = unsafe decimal(p, offset, length)
        if let literal { return unsafe DecimalFloat.float(literal, in: buffer) }
        if let json5 = unsafe parseJSON5Float(p, offset, length) { return json5 }
        return unsafe Float(String(decoding: buffer, as: UTF8.self)) ?? .nan
    }

    // The number's bytes, and aemi's literal when the whole range is one plain decimal.
    @inline(__always)
    static func decimal(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int)
        -> (UnsafeBufferPointer<UInt8>, DecimalLiteral?)
    {
        assert(offset >= 0 && length >= 0, "a number needs a non-negative byte range")
        let buffer = unsafe UnsafeBufferPointer(start: p + offset, count: length)
        guard let literal = unsafe DecimalScanner.scan(buffer, from: 0), literal.end == length else {
            return unsafe (buffer, nil)
        }
        return unsafe (buffer, literal)
    }

    // The fast paths alone (for the tests that hold them to padded decimals): the value when Clinger or
    // Eisel-Lemire proves it, else nil. A literal whose digits are only padding past the nineteen keeps them.
    static func parseDoubleFast(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Double? {
        unsafe decimal(p, offset, length).1.flatMap(DecimalFloat.fastDouble)
    }

    static func parseFloatFast(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Float? {
        guard let literal = unsafe decimal(p, offset, length).1?.trimmed, !literal.truncated,
            literal.significand <= 1 << 24
        else { return nil }
        return DecimalFloat.float(
            significand: UInt32(truncatingIfNeeded: literal.significand),
            exponent: literal.exponent,
            negative: literal.negative
        )
    }

    // `parseJSON5Number`, but accumulating the hexadecimal body into `Float` directly so a large hex
    // literal is correctly rounded to `Float` (not rounded to `Double` first, then narrowed). Returns
    // nil for an ordinary decimal (left to the `Float(_:)` slow path). Inf/NaN are exact at any width.
    @inline(__always)
    static func parseJSON5Float(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Float? {
        var idx = offset
        let end = offset + length
        guard idx < end else { return nil }
        var sign: Float = 1
        if unsafe p[idx] == 0x2D {
            sign = -1
            idx += 1
        } else if unsafe p[idx] == 0x2B {
            idx += 1
        }
        guard idx < end else { return nil }
        switch unsafe p[idx] {
            case 0x49: return sign * .infinity  // 'I' Infinity
            case 0x4E: return .nan  // 'N' NaN
            case 0x30 where unsafe idx + 1 < end && (p[idx + 1] == 0x78 || p[idx + 1] == 0x58):  // 0x / 0X
                var value: Float = 0
                var k = idx + 2
                while k < end, let d = unsafe Hex.value(p[k]) {
                    value = value * 16 + Float(d)
                    k += 1
                }
                return k > idx + 2 ? sign * value : nil
            default: return nil
        }
    }

    // Parse the JSON5-only number spellings — `Infinity`, `NaN`, and hexadecimal (`0x…`) — returning
    // the value, or nil for an ordinary decimal (left to `Double(_:)`).
    @inline(__always)
    static func parseJSON5Number(_ p: UnsafePointer<UInt8>, _ offset: Int, _ length: Int) -> Double? {
        var idx = offset
        let end = offset + length
        guard idx < end else { return nil }
        var sign = 1.0
        if unsafe p[idx] == 0x2D {
            sign = -1
            idx += 1
        } else if unsafe p[idx] == 0x2B {
            idx += 1
        }
        guard idx < end else { return nil }
        switch unsafe p[idx] {
            case 0x49: return sign * .infinity  // 'I' Infinity
            case 0x4E: return .nan  // 'N' NaN
            case 0x30 where unsafe idx + 1 < end && (p[idx + 1] == 0x78 || p[idx + 1] == 0x58):  // 0x / 0X
                var value = 0.0
                var k = idx + 2
                while k < end, let d = unsafe Hex.value(p[k]) {
                    value = value * 16 + Double(d)
                    k += 1
                }
                return k > idx + 2 ? sign * value : nil
            default: return nil
        }
    }

    // Generic integer parse with correct overflow handling for any width, signed or
    // unsigned (negatives accumulate downward so Int.min and UInt.max both work).
    @inline(__always)
    public static func parseInteger<T: FixedWidthInteger>(
        _ p: UnsafePointer<UInt8>,
        _ offset: Int,
        _ length: Int,
        _ type: T.Type
    ) -> T? {
        // Caller owns `p[offset ..< offset + length]` for this call; `p` is read-only and never escapes.
        assert(offset >= 0 && length >= 0, "parseInteger requires a non-negative byte range")
        var idx = offset
        let end = offset + length
        guard idx < end else { return nil }
        var neg = false
        if unsafe p[idx] == 0x2D {
            neg = true
            idx += 1
            if !T.isSigned { return nil }
        } else if unsafe p[idx] == 0x2B {
            idx += 1
        }
        guard idx < end else { return nil }
        // JSON5 hex literal `0x…` (only emitted in json5 mode — a strict/lenient integer token never
        // starts with `0x`, so this is a single predictable branch off the common decimal path).
        if unsafe p[idx] == 0x30, idx + 1 < end, unsafe p[idx + 1] == 0x78 || p[idx + 1] == 0x58 {
            return unsafe parseHexInteger(p, idx + 2, end, neg, T.self)
        }
        var v: T = 0
        let ten = T(10)
        while idx < end {
            let c = unsafe p[idx]
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
        _ p: UnsafePointer<UInt8>,
        _ start: Int,
        _ end: Int,
        _ neg: Bool,
        _ type: T.Type
    ) -> T? {
        guard start < end else { return nil }
        var v: T = 0
        let sixteen = T(16)
        var idx = start
        while idx < end {
            guard let digit = unsafe Hex.value(p[idx]) else { return nil }
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
