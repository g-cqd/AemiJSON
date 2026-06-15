import ADJSONCore
public import Foundation

// Foundation-parity coding strategies for `Date`, `Data`, and non-conforming floats. These live in
// the umbrella (Foundation) layer — the Foundation-free `ADJSONCore` engine can't reference `Date`
// or `Data` — and are threaded into the streaming `EncodeState` / `DecodeContext`, which intercept
// `Date`/`Data` by type at the central encode/decode dispatch. They mirror `Foundation.JSONEncoder`
// / `JSONDecoder`, including the defaults (`.deferredToDate`, `.base64`).

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

    /// How `CodingKey`s are converted to JSON keys. A subset of
    /// `Foundation.JSONEncoder.KeyEncodingStrategy` (`.custom` is not yet supported — this encoder
    /// does not track the full coding path). Setting `.convertToSnakeCase` routes encoding through
    /// the generic path so the transform applies uniformly (the fast path writes keys verbatim).
    public enum KeyEncodingStrategy {
        case useDefaultKeys
        case convertToSnakeCase
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

    /// How JSON keys are converted before matching `CodingKey`s. A subset of
    /// `Foundation.JSONDecoder.KeyDecodingStrategy` (`.custom` is not yet supported).
    public enum KeyDecodingStrategy {
        case useDefaultKeys
        case convertFromSnakeCase
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
    var key: ADJSON.JSONDecoder.KeyDecodingStrategy = .useDefaultKeys
}

// MARK: - snake_case conversion (ported from swift-foundation's JSONEncoder/JSONDecoder)

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
            // `Date.ISO8601FormatStyle` (Sendable, value-type, allocation-free) replaces the
            // non-Sendable `ISO8601DateFormatter` cache; its default is internet date-time in UTC,
            // byte-identical to Foundation's `.iso8601` strategy.
            guard let date = try? Date(s, strategy: .iso8601) else {
                throw dateCorrupted("Expected an ISO8601 date string")
            }
            return date
        case .formatted(let formatter):
            guard let s = string(index) else { throw dateMismatch() }
            guard let date = formatter.date(from: s) else {
                throw dateCorrupted("Date string does not match the expected format")
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
            guard let data = Data(base64Encoded: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid Base64 string"))
            }
            return data
        case .custom(let body):
            return try body(TapeDecoder(ctx: self, index: index, codingPath: []))
        }
    }

    /// True when JSON keys must be converted before matching `CodingKey`s (disables the byte-compare
    /// fast path in `memberValueIndex`).
    var keyConversionActive: Bool {
        if case .useDefaultKeys = strategies.key { return false }
        return true
    }

    /// Convert a JSON key to its `CodingKey` form under the active key-decoding strategy.
    func applyKeyDecoding(_ key: String) -> String {
        switch strategies.key {
        case .useDefaultKeys: return key
        case .convertFromSnakeCase: return convertFromSnakeCase(key)
        }
    }

    private func dateMismatch() -> DecodingError {
        DecodingError.typeMismatch(Date.self, .init(codingPath: [], debugDescription: "Expected a date value"))
    }
    private func dateCorrupted(_ message: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: message))
    }
}
