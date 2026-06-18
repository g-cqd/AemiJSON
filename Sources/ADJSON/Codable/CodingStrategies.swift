import ADJSONCore
public import Foundation

// Foundation-parity coding strategies for `Date`, `Data`, and non-conforming floats. These live in
// the umbrella (Foundation) layer — the Foundation-free `ADJSONCore` engine can't reference `Date`
// or `Data` — and are threaded into the streaming `EncodeState` / `DecodeContext`, which intercept
// `Date`/`Data` by type at the central encode/decode dispatch. They mirror `Foundation.JSONEncoder`
// / `JSONDecoder`, including the defaults (`.deferredToDate`, `.base64`).

/// `CodingKey` for an array position — used only to build a `codingPath` for error contexts. Shared
/// by the `JSONValue` decoder and encoder so both report identical array-position paths.
struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "Index \(intValue ?? 0)" }
    init(_ index: Int) { intValue = index }
    init?(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { return nil }
}

extension ADJSON.JSONEncoder {
    /// How `Date` is encoded. Matches `Foundation.JSONEncoder.DateEncodingStrategy`.
    public enum DateEncodingStrategy {
        /// `Date`'s own `Codable` (a `Double` of `timeIntervalSinceReferenceDate`). The default.
        case deferredToDate
        case secondsSince1970
        case millisecondsSince1970
        /// ISO 8601 internet date-time (`withInternetDateTime`).
        case iso8601
        case formatted(DateFormatter)
        case custom((Date, any Encoder) throws -> Void)
    }

    /// How `Data` is encoded. Matches `Foundation.JSONEncoder.DataEncodingStrategy`.
    public enum DataEncodingStrategy {
        /// `Data`'s own `Codable` (an array of byte integers).
        case deferredToData
        /// A Base64 string. The default (matching Foundation).
        case base64
        case custom((Data, any Encoder) throws -> Void)
    }

    /// How `CodingKey`s are converted to JSON keys. Mirrors `Foundation.JSONEncoder.KeyEncodingStrategy`
    /// for `.useDefaultKeys` / `.convertToSnakeCase`; `.custom` here takes a `(String) -> String`
    /// transform applied to each key's `stringValue` (ADJSON does not expose Foundation's full
    /// `[CodingKey]` path — the streaming encoder tracks no coding path). Any non-default strategy
    /// routes encoding through the generic path so the transform applies uniformly (the `@JSONCodable`
    /// fast path writes keys verbatim).
    public enum KeyEncodingStrategy {
        case useDefaultKeys
        case convertToSnakeCase
        /// Transform each key's `stringValue` to its JSON form (e.g. uppercase, prefix, lookup).
        case custom(@Sendable (String) -> String)
    }
}

extension ADJSON.JSONDecoder {
    /// How `Date` is decoded. Matches `Foundation.JSONDecoder.DateDecodingStrategy`.
    public enum DateDecodingStrategy {
        case deferredToDate
        case secondsSince1970
        case millisecondsSince1970
        case iso8601
        case formatted(DateFormatter)
        case custom((any Decoder) throws -> Date)
    }

    /// How `Data` is decoded. Matches `Foundation.JSONDecoder.DataDecodingStrategy`.
    public enum DataDecodingStrategy {
        case deferredToData
        case base64
        case custom((any Decoder) throws -> Data)
    }

    /// How non-conforming floats (`±Infinity`, `NaN`, which JSON can't represent) are decoded.
    /// Matches `Foundation.JSONDecoder.NonConformingFloatDecodingStrategy`.
    public enum NonConformingFloatDecodingStrategy {
        case `throw`
        case convertFromString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// How JSON keys are converted before matching `CodingKey`s. Mirrors
    /// `Foundation.JSONDecoder.KeyDecodingStrategy` for `.useDefaultKeys` / `.convertFromSnakeCase`;
    /// `.custom` here takes a `(String) -> String` transform applied to each JSON key before it is
    /// matched against the type's `CodingKey`s (ADJSON does not expose Foundation's full `[CodingKey]`
    /// path). Any non-default strategy routes decoding through the generic container path.
    public enum KeyDecodingStrategy {
        case useDefaultKeys
        case convertFromSnakeCase
        /// Transform each JSON key before matching it to a `CodingKey` (e.g. lowercase, strip a prefix).
        case custom(@Sendable (String) -> String)
    }
}

// MARK: - Internal bundles threaded into the encode/decode engines

struct EncodeStrategies {
    var date: ADJSON.JSONEncoder.DateEncodingStrategy = .deferredToDate
    var data: ADJSON.JSONEncoder.DataEncodingStrategy = .base64
    var key: ADJSON.JSONEncoder.KeyEncodingStrategy = .useDefaultKeys
}

// `@usableFromInline` so it can appear in `DecodeContext`'s `@usableFromInline` initializer
// signature; the memberwise init stays internal (only non-inlinable code constructs it).
@usableFromInline struct DecodeStrategies {
    var date: ADJSON.JSONDecoder.DateDecodingStrategy = .deferredToDate
    var data: ADJSON.JSONDecoder.DataDecodingStrategy = .base64
    var nonConformingFloat: ADJSON.JSONDecoder.NonConformingFloatDecodingStrategy = .throw
    @usableFromInline var key: ADJSON.JSONDecoder.KeyDecodingStrategy = .useDefaultKeys
}

// MARK: - snake_case conversion (matches swift-foundation's JSONEncoder/JSONDecoder semantics)

/// `camelCase` → `snake_case`, e.g. `oneTwoThree` → `one_two_three`, `aURL` → `a_url`.
func convertToSnakeCase(_ key: String) -> String {
    guard !key.isEmpty else { return key }
    var words: [Range<String.Index>] = []
    var wordStart = key.startIndex
    var searchRange = key.index(after: wordStart)..<key.endIndex
    while let upper = key.rangeOfCharacter(from: .uppercaseLetters, options: [], range: searchRange) {
        words.append(wordStart..<upper.lowerBound)
        searchRange = upper.lowerBound..<searchRange.upperBound
        guard let lower = key.rangeOfCharacter(from: .lowercaseLetters, options: [], range: searchRange) else {
            wordStart = searchRange.lowerBound
            break
        }
        let afterCapital = key.index(after: upper.lowerBound)
        if lower.lowerBound == afterCapital {
            wordStart = upper.lowerBound
        } else {
            let beforeLower = key.index(before: lower.lowerBound)
            words.append(upper.lowerBound..<beforeLower)
            wordStart = beforeLower
        }
        searchRange = lower.upperBound..<searchRange.upperBound
    }
    words.append(wordStart..<searchRange.upperBound)
    return words.map { key[$0].lowercased() }.joined(separator: "_")
}

/// `snake_case` → `camelCase`, preserving leading/trailing underscores, e.g. `one_two` → `oneTwo`.
func convertFromSnakeCase(_ key: String) -> String {
    guard !key.isEmpty else { return key }
    guard let firstNonUnderscore = key.firstIndex(where: { $0 != "_" }) else { return key }
    var lastNonUnderscore = key.index(before: key.endIndex)
    while lastNonUnderscore > firstNonUnderscore, key[lastNonUnderscore] == "_" {
        lastNonUnderscore = key.index(before: lastNonUnderscore)
    }
    let keyRange = firstNonUnderscore...lastNonUnderscore
    let leading = key.startIndex..<firstNonUnderscore
    let trailing = key.index(after: lastNonUnderscore)..<key.endIndex
    let components = key[keyRange].split(separator: "_")
    let joined: String
    if components.count == 1 {
        joined = String(key[keyRange])
    } else {
        joined = ([components[0].lowercased()] + components[1...].map { $0.capitalized }).joined()
    }
    return String(key[leading]) + joined + String(key[trailing])
}

// MARK: - Decode-side strategy application (intercepted by type in `decodeValue`)

/// Shared `Date`/`Data` decoding semantics, so the tape decoder (`DecodeContext`) and the
/// already-materialized tree decoder (`JSONValueDecoderImpl`) parse identically and report the same
/// messages. Each path keeps its own primitive extraction and error `codingPath`; this pins the one
/// thing they must agree on — the parse choice and the canonical failure text — in a single place.
enum DateDataDecoding {
    static let iso8601Mismatch = "Expected an ISO8601 date string"
    static let formattedMismatch = "Date string does not match the expected format"
    static let invalidBase64 = "Invalid Base64 string"

    /// ISO 8601 internet date-time in UTC via the Sendable, value-type `Date.ISO8601FormatStyle`
    /// (byte-identical to Foundation's `.iso8601` strategy), or nil if `s` isn't valid ISO 8601.
    static func iso8601(_ s: String) -> Date? { try? Date(s, strategy: .iso8601) }

    /// Base64 → `Data`, or nil if `s` isn't valid Base64.
    static func base64(_ s: String) -> Data? { Data(base64Encoded: s) }
}

extension DecodeContext {
    /// `double`, plus the nonConformingFloat fallback: a configured string literal (`"Infinity"`,
    /// etc.) decodes to ±Infinity / NaN. The choke point for every generic `Double`/`Float` decode.
    func decodeFloatingPoint(_ index: Int) -> Double? {
        if let d = double(index) { return d }
        guard case let .convertFromString(pos, neg, nan) = strategies.nonConformingFloat,
            let s = string(index)
        else { return nil }
        if s == pos { return .infinity }
        if s == neg { return -.infinity }
        if s == nan { return .nan }
        return nil
    }

    func decodeDate(at index: Int) throws -> Date {
        switch strategies.date {
        case .deferredToDate:
            return try Date(from: TapeDecoder(ctx: self, index: index, codingPath: []))
        case .secondsSince1970:
            guard let d = double(index) else { throw dateMismatch() }
            return Date(timeIntervalSince1970: d)
        case .millisecondsSince1970:
            guard let d = double(index) else { throw dateMismatch() }
            return Date(timeIntervalSince1970: d / 1000)
        case .iso8601:
            guard let s = string(index) else { throw dateMismatch() }
            guard let date = DateDataDecoding.iso8601(s) else {
                throw dateCorrupted(DateDataDecoding.iso8601Mismatch)
            }
            return date
        case .formatted(let formatter):
            guard let s = string(index) else { throw dateMismatch() }
            guard let date = formatter.date(from: s) else {
                throw dateCorrupted(DateDataDecoding.formattedMismatch)
            }
            return date
        case .custom(let body):
            return try body(TapeDecoder(ctx: self, index: index, codingPath: []))
        }
    }

    func decodeData(at index: Int) throws -> Data {
        switch strategies.data {
        case .deferredToData:
            return try Data(from: TapeDecoder(ctx: self, index: index, codingPath: []))
        case .base64:
            guard let s = string(index) else {
                throw DecodingError.typeMismatch(
                    Data.self, .init(codingPath: [], debugDescription: "Expected a Base64 string"))
            }
            guard let data = DateDataDecoding.base64(s) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: DateDataDecoding.invalidBase64))
            }
            return data
        case .custom(let body):
            return try body(TapeDecoder(ctx: self, index: index, codingPath: []))
        }
    }

    /// Decode a `Decimal` from the number's raw source lexeme, so a value with more precision than
    /// `Double` (large integers, exact decimal fractions) is preserved — matching `Foundation`'s
    /// `JSONDecoder`, which special-cases `Decimal` rather than routing it through its (keyed) `Codable`
    /// conformance. A non-number node is a type mismatch; a number outside `Decimal`'s range is corrupt.
    func decodeDecimal(at index: Int) throws -> Decimal {
        let raw = slot(index)
        guard Slot.tag(raw) == JSONKind.number.rawValue else {
            throw DecodingError.typeMismatch(
                Decimal.self, .init(codingPath: [], debugDescription: "Expected a number for Decimal"))
        }
        let off = Slot.low(raw), len = Slot.length(raw)
        assertBytes(off, len)
        let buffer = UnsafeBufferPointer(start: bytes + off, count: len)
        // Fast byte path — no `String`, no Foundation locale scanner. Falls back to `Decimal(string:)`
        // (identical result) only for >38 significant digits or an out-of-range exponent.
        if let value = fastDecimal(buffer) { return value }
        guard let value = Decimal(string: String(decoding: buffer, as: UTF8.self), locale: ADJSONDecimal.posixLocale)
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Number is out of Decimal's representable range"))
        }
        return value
    }

    /// True when JSON keys must be converted before matching `CodingKey`s (disables the byte-compare
    /// fast path in `memberValueIndex` and the `@JSONCodable` fast decode).
    @usableFromInline var keyConversionActive: Bool {
        if case .useDefaultKeys = strategies.key { return false }
        return true
    }

    /// Convert a JSON key to its `CodingKey` form under the active key-decoding strategy.
    func applyKeyDecoding(_ key: String) -> String {
        switch strategies.key {
        case .useDefaultKeys: return key
        case .convertFromSnakeCase: return convertFromSnakeCase(key)
        case .custom(let transform): return transform(key)
        }
    }

    private func dateMismatch() -> DecodingError {
        DecodingError.typeMismatch(Date.self, .init(codingPath: [], debugDescription: "Expected a date value"))
    }
    private func dateCorrupted(_ message: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: message))
    }
}
