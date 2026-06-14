/// Controls how strictly input is validated and how edge cases are handled.
/// The default (`.strict`) conforms to RFC 8259 / ECMA-404 / ISO-IEC 21778.
public struct JSONParseOptions: Sendable {
    public enum Validation: Sendable {
        /// RFC 8259 grammar: strict numbers, validated escapes, well-formed UTF-8.
        case strict
        /// Permissive scanning (faster, accepts some malformed input). Strings are not re-validated,
        /// so escape sequences may pass through without RFC-conformant decoding — lenient string
        /// output can therefore differ from strict decoding. It remains memory-safe.
        case lenient
    }

    public enum DuplicateKeyStrategy: Sendable {
        /// Keep the last value for a repeated object key (matches JS / Foundation).
        case useLast
        /// Reject objects containing duplicate keys (RFC 7493 I-JSON).
        case throwError
    }

    public var validation: Validation
    public var duplicateKeys: DuplicateKeyStrategy
    /// Maximum container nesting accepted while parsing. It also bounds the *native-stack* recursion
    /// of the recursive consumers — `Codable` decoding, ``JSONValue`` materialization, and schema
    /// validation — so the default (512) keeps them safe. Raising it for untrusted input risks a
    /// stack overflow when that input is deeply nested; keep it modest unless the source is trusted.
    public var maxDepth: Int

    public init(
        validation: Validation = .strict,
        duplicateKeys: DuplicateKeyStrategy = .useLast,
        maxDepth: Int = 512
    ) {
        self.validation = validation
        self.duplicateKeys = duplicateKeys
        self.maxDepth = maxDepth
    }

    /// RFC 8259 strict syntax, duplicate keys keep the last value. The default.
    public static let strict = JSONParseOptions(validation: .strict, duplicateKeys: .useLast)

    /// Permissive scanning for inputs that bend the grammar.
    public static let lenient = JSONParseOptions(validation: .lenient, duplicateKeys: .useLast)

    /// RFC 7493 I-JSON profile: strict syntax and duplicate object keys are rejected.
    /// (Number-range restriction to IEEE-754 is not yet enforced.)
    public static let iJSON = JSONParseOptions(validation: .strict, duplicateKeys: .throwError)

    @inline(__always) var isStrict: Bool { if case .strict = validation { return true } else { return false } }
}
