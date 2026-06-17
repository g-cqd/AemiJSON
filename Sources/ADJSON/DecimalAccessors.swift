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

extension JSON {
    /// The number node parsed as a `Decimal` (base-10, ~38 significant digits), read from the original
    /// source lexeme so it preserves exact decimal values and integers beyond `Double`'s 2^53 — where
    /// `double` would round. Returns nil for a non-number node or a value outside `Decimal`'s range.
    public var decimal: Decimal? {
        guard let lexeme = numberLexeme else { return nil }
        return Decimal(string: lexeme, locale: ADJSONDecimal.posixLocale)
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
        case .number(let value):
            guard value.isFinite else { return nil }
            return Decimal(string: value.description, locale: ADJSONDecimal.posixLocale)
        default: return nil
        }
    }
}
