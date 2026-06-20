import ADJSONCore
public import Foundation

// `Decimal` accessors layered on the Foundation-free engine. The tape keeps each number's raw source
// lexeme (see `JSON.numberLexeme`), so a number can be read as an exact base-10 `Decimal` (~38
// significant digits) — preserving values that `Double` would round: integers beyond 2^53 and decimal
// fractions such as 0.1. These live in the umbrella because `Decimal` is a Foundation type; the engine
// stays Foundation-free.

// Parse number lexemes with a fixed POSIX convention (`.` decimal separator) regardless of the process
// locale — the same locale-independence the core's `Double` parser guarantees.
enum ADJSONDecimal {
    static let posixLocale = Locale(identifier: "en_US_POSIX")
}

// Build a `Decimal` from a validated JSON number lexeme WITHOUT Foundation's locale-aware
// `Decimal(string:)` scanner, which is the bottleneck (measured ~1.4× faster on 31-digit values, ~2×
// on short ones). The significand accumulates into a `UInt128` — covering `Decimal`'s full ~38-digit
// capacity, i.e. the high-precision values `Decimal` exists for, not just `Double`-sized ones — and the
// net base-10 exponent is tracked from the bytes; the result is `significand × 10^exponent` via
// `Decimal(sign:exponent:significand:)`. Returns nil — so the caller falls back to `Decimal(string:)`
// for an identical result — only for >38 significant digits (beyond `Decimal`'s exact range anyway) or
// an exponent outside `Decimal`'s range. `UInt128` is `SwiftStdlib 6.0` (macOS 15 / iOS 18), exactly the
// package's deployment floor, so no availability shim is needed.

// 10^38: one past `Decimal`'s exact 38-significant-digit capacity. A significand at or above this can't
// be represented exactly, so hand it to the string parser rather than risk a divergent rounding.
private let decimalSignificandCeiling: UInt128 = {
    var value: UInt128 = 1
    for _ in 0 ..< 38 { value &*= 10 }
    return value
}()
// 2^64, to fold the significand's high/low 64-bit halves into a `Decimal` exactly.
private let twoToThe64: Decimal = Decimal(UInt64.max) + 1

/// Parses an optional `[eE][+-]?digits` exponent suffix starting at `p[i]`, advancing
/// `i`. Returns the signed exponent (0 when absent), or nil on a malformed/absurd one.
private func parseDecimalExponent(_ p: UnsafePointer<UInt8>, _ i: inout Int, _ n: Int) -> Int? {
    guard i < n, p[i] == 0x65 || p[i] == 0x45 else { return 0 }
    i += 1
    var expNegative = false
    if i < n, p[i] == 0x2B || p[i] == 0x2D {
        expNegative = p[i] == 0x2D
        i += 1
    }
    var value = 0
    var sawExpDigit = false
    while i < n {
        let b = p[i]
        guard b >= 0x30, b <= 0x39 else { return nil }
        sawExpDigit = true
        value = value &* 10 &+ Int(b - 0x30)
        if value > 1000 { return nil }  // absurd exponent → fall back
        i += 1
    }
    guard sawExpDigit else { return nil }
    return expNegative ? -value : value
}

func fastDecimal(_ buffer: UnsafeBufferPointer<UInt8>) -> Decimal? {
    let n = buffer.count
    guard n > 0, let p = buffer.baseAddress else { return nil }
    var i = 0
    var negative = false
    if p[0] == 0x2D {  // '-'
        negative = true
        i = 1
    }
    var significand: UInt128 = 0
    var fractionExponent = 0
    var sawDigit = false
    var seenDot = false
    while i < n {
        let b = p[i]
        if b == 0x2E {  // '.'
            if seenDot { return nil }
            seenDot = true
            i += 1
            continue
        }
        if b == 0x65 || b == 0x45 { break }  // 'e' / 'E'
        guard b >= 0x30, b <= 0x39 else { return nil }
        sawDigit = true
        let (m, mo) = significand.multipliedReportingOverflow(by: 10)
        if mo { return nil }
        let (a, ao) = m.addingReportingOverflow(UInt128(b - 0x30))
        if ao { return nil }
        significand = a
        if significand >= decimalSignificandCeiling { return nil }  // > 38 digits → beyond exact range
        if seenDot { fractionExponent -= 1 }
        i += 1
    }
    guard sawDigit else { return nil }
    guard let literalExponent = parseDecimalExponent(p, &i, n) else { return nil }
    guard i == n else { return nil }  // trailing bytes → fall back
    let exponent = fractionExponent + literalExponent
    guard exponent >= -128, exponent <= 127 else { return nil }  // outside Decimal's exponent range
    // `Decimal` has no UInt128 init: fold the significand's 64-bit halves (exact — the value is < 10^38).
    let high = UInt64(truncatingIfNeeded: significand >> 64)
    let low = UInt64(truncatingIfNeeded: significand)
    let significandDecimal = high == 0 ? Decimal(low) : Decimal(high) * twoToThe64 + Decimal(low)
    return Decimal(sign: negative ? .minus : .plus, exponent: exponent, significand: significandDecimal)
}

// Convenience over a `String` lexeme (small JSON numbers are inline, so no heap): the byte fast path,
// else Foundation's parser.
func decimalFromLexeme(_ lexeme: String) -> Decimal? {
    if let fast = lexeme.utf8.withContiguousStorageIfAvailable({ fastDecimal($0) }), let value = fast {
        return value
    }
    return Decimal(string: lexeme, locale: ADJSONDecimal.posixLocale)
}

// A `Decimal` carrying only the precision a `Double` retains — its shortest round-trippable decimal
// text. Used where the source lexeme is gone (a materialized `JSONValue` holds `Double`, not the raw
// digits); read ``JSON/decimal`` on the parsed document for full source precision. nil for non-finite.
func decimalFromDouble(_ value: Double) -> Decimal? {
    guard value.isFinite else { return nil }
    return decimalFromLexeme(value.description)
}

extension JSON {
    /// The number node parsed as a `Decimal` (base-10, ~38 significant digits), read from the original
    /// source lexeme so it preserves exact decimal values and integers beyond `Double`'s 2^53 — where
    /// `double` would round. Returns nil for a non-number node or a value outside `Decimal`'s range.
    public var decimal: Decimal? {
        guard let lexeme = numberLexeme else { return nil }
        return decimalFromLexeme(lexeme)
    }
}

extension JSONValue {
    /// The number value as a `Decimal`. A `JSONValue` already stores numbers as `Int64` / `Double`, so
    /// this carries only the precision retained at materialization: `int` is exact, while `number`
    /// reflects its `Double` (~15–17 significant digits). For full *source* precision read
    /// ``JSON/decimal`` on the parsed document **before** materializing a tree.
    public var decimal: Decimal? {
        switch self {
            case .int(let value): return Decimal(value)
            case .number(let value): return decimalFromDouble(value)
            default: return nil
        }
    }
}
