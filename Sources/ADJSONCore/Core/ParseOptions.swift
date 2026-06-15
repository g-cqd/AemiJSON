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
        /// JSON5 (json5.org): a superset of JSON that also accepts line (`//`) and block (`/* */`)
        /// comments, single-quoted and unquoted (identifier) object keys, single-quoted strings,
        /// trailing commas, leading `+`, leading/trailing decimal points (`.5`, `5.`), hexadecimal
        /// numbers (`0xFF`), and `Infinity` / `-Infinity` / `NaN`. UTF-8 is validated as in strict
        /// mode. Matches `Foundation.JSONDecoder.allowsJSON5`.
        case json5
    }

    public enum DuplicateKeyStrategy: Sendable {
        /// Keep the last value for a repeated object key (matches JS / Foundation).
        case useLast
        /// Reject objects containing duplicate keys (RFC 7493 I-JSON).
        case throwError
    }

    public var validation: Validation
    public var duplicateKeys: DuplicateKeyStrategy
    /// Restrict numbers to the IEEE-754 double domain (RFC 7493 I-JSON §2.2): an integer literal
    /// whose magnitude exceeds 2^53−1 is rejected (it can't survive a round-trip through a double),
    /// and any number whose value overflows to ±∞ (e.g. `1e400`) is rejected. Off for strict /
    /// lenient, which accept the full RFC 8259 number grammar; enabled by the `.iJSON` preset.
    public var restrictsNumbersToIEEE754: Bool
    /// Assume the top level of the input is an object even when it isn't wrapped in braces, so
    /// `"a":1,"b":2` parses as `{"a":1,"b":2}` (Foundation's `JSONDecoder.assumesTopLevelDictionary`;
    /// an extension to JSON5). Input that already starts with `{` is parsed unchanged — so a single
    /// unmatched brace (`{…` or `…}`) is still rejected. Off by default.
    public var assumesTopLevelDictionary: Bool
    /// Maximum container nesting accepted while parsing. The tape parser, lazy navigation,
    /// ``JSONValue`` materialization/serialization, and JSONPath evaluation are all iterative, so
    /// they stay safe at any depth. It still bounds the remaining *native-stack* recursive
    /// consumers — `Codable` decoding (the protocol mandates recursion) and schema validation — so
    /// the default (512) keeps them safe. Raising it for untrusted input risks a stack overflow in
    /// those paths when the input is deeply nested; keep it modest unless the source is trusted.
    public var maxDepth: Int

    public init(
        validation: Validation = .strict,
        duplicateKeys: DuplicateKeyStrategy = .useLast,
        maxDepth: Int = 512,
        restrictsNumbersToIEEE754: Bool = false,
        assumesTopLevelDictionary: Bool = false
    ) {
        self.validation = validation
        self.duplicateKeys = duplicateKeys
        self.maxDepth = maxDepth
        self.restrictsNumbersToIEEE754 = restrictsNumbersToIEEE754
        self.assumesTopLevelDictionary = assumesTopLevelDictionary
    }

    /// RFC 8259 strict syntax, duplicate keys keep the last value. The default.
    public static let strict = JSONParseOptions(validation: .strict, duplicateKeys: .useLast)

    /// Permissive scanning for inputs that bend the grammar.
    public static let lenient = JSONParseOptions(validation: .lenient, duplicateKeys: .useLast)

    /// JSON5 (json5.org): comments, unquoted/single-quoted keys, single-quoted strings, trailing
    /// commas, and the extended number grammar. UTF-8 is still validated.
    public static let json5 = JSONParseOptions(validation: .json5, duplicateKeys: .useLast)

    /// RFC 7493 I-JSON profile: strict syntax, duplicate object keys rejected, and numbers
    /// restricted to the IEEE-754 double domain (integers within ±(2^53−1), no ±∞).
    public static let iJSON = JSONParseOptions(
        validation: .strict, duplicateKeys: .throwError, restrictsNumbersToIEEE754: true)

    @inline(__always) var isStrict: Bool { if case .strict = validation { return true } else { return false } }
    @inline(__always) var isJSON5: Bool { if case .json5 = validation { return true } else { return false } }
}
