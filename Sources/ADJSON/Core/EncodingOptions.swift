/// Controls how values are serialized to JSON. The default (`.rfc8259`) emits strict
/// RFC 8259 / ECMA-404; the `.javaScript` preset matches JavaScript `JSON.stringify`
/// byte-for-byte. Read once when an encoder/writer is constructed, so the default path
/// stays branch-light.
public struct JSONEncodingOptions: Sendable {
    /// How non-finite numbers (NaN, ±Infinity — which JSON cannot represent) are emitted.
    public enum NonFiniteStrategy: Sendable, Equatable {
        /// Reject with `EncodingError.invalidValue` (RFC 8259, the default).
        case `throw`
        /// Emit `null` (matches `JSON.stringify`).
        case null
        /// Emit the given string literals (e.g. `"Infinity"`), as some lenient profiles do.
        case stringLiterals(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// How `Double`/`Float` values are rendered.
    public enum NumberFormat: Sendable, Equatable {
        /// Swift's shortest round-trippable form (`Double.description`, the default).
        case swiftShortest
        /// ECMA-262 `Number::toString` (what `JSON.stringify` emits: `5.0`→`5`, `1e-7`, `-0`→`0`).
        case ecma262
    }

    /// Object member ordering.
    public enum KeyOrder: Sendable, Equatable {
        /// Encodable field / dictionary iteration order (the default).
        case declaration
        /// Lexicographic by key (like Foundation's `.sortedKeys`).
        case sorted
    }

    /// How a `nil` optional member is emitted by the Codable path.
    public enum NilStrategy: Sendable, Equatable {
        /// Omit the member entirely (Foundation / JS `undefined`, the default).
        case omit
        /// Emit `"key":null`.
        case null
    }

    public var nonFinite: NonFiniteStrategy
    public var numberFormat: NumberFormat
    public var keyOrder: KeyOrder
    /// Escape `/` as `\/`. RFC 8259 and `JSON.stringify` both leave it unescaped (default `false`).
    public var escapeSlashes: Bool
    public var nilStrategy: NilStrategy

    public init(
        nonFinite: NonFiniteStrategy = .throw,
        numberFormat: NumberFormat = .swiftShortest,
        keyOrder: KeyOrder = .declaration,
        escapeSlashes: Bool = false,
        nilStrategy: NilStrategy = .omit
    ) {
        self.nonFinite = nonFinite
        self.numberFormat = numberFormat
        self.keyOrder = keyOrder
        self.escapeSlashes = escapeSlashes
        self.nilStrategy = nilStrategy
    }

    /// Strict RFC 8259 / ECMA-404: reject non-finite numbers, shortest numbers, declaration order.
    public static let rfc8259 = JSONEncodingOptions()

    /// Byte-for-byte JavaScript `JSON.stringify`: non-finite → `null`, ECMA-262 number formatting.
    public static let javaScript = JSONEncodingOptions(nonFinite: .null, numberFormat: .ecma262)
}
