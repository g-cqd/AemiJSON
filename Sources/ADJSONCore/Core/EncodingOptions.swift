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
        /// Swift's shortest round-trippable form (`Double.description`, the default). The Codable
        /// encoder renders a value typed `Double` faithfully, so `Double(2)` becomes `2.0`; the
        /// `JSONValue` model instead collapses integral magnitudes to `2` to preserve integer
        /// round-trips (it stores only `Double`). Neither matches Foundation byte-for-byte — use
        /// `.ecma262` for `JSON.stringify` parity.
        case swiftShortest
        /// ECMA-262 `Number::toString` (what `JSON.stringify` emits: `5.0`→`5`, `1e-7`, `-0`→`0`).
        case ecma262
        /// SQLite's `%!.15g` — byte-for-byte with `sqlite3`'s `json()` / `json_quote()`: 15 significant
        /// figures, `%g` fixed-or-exponential selection, a fractional digit always kept so a real stays
        /// a real (`5.0`, `1.0e+20`, `123456789012345.0`), and `-0.0` → `0.0`. Only affects `Double`
        /// (`.number`); integers keep their exact decimal form. Lets a consumer (e.g. ADSQL) make ADJSON
        /// the single owner of SQLite-dialect JSON serialization.
        case sqlitePrintfG
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
    /// Emit human-readable output: a newline after each `{`/`[`/`,`, two-space indentation per
    /// nesting level, and a `" : "` key separator — matching `Foundation`'s `.prettyPrinted`
    /// (default `false`). Empty containers stay on one line (`[]` / `{}`).
    public var prettyPrinted: Bool

    public init(
        nonFinite: NonFiniteStrategy = .throw,
        numberFormat: NumberFormat = .swiftShortest,
        keyOrder: KeyOrder = .declaration,
        escapeSlashes: Bool = false,
        nilStrategy: NilStrategy = .omit,
        prettyPrinted: Bool = false
    ) {
        self.nonFinite = nonFinite
        self.numberFormat = numberFormat
        self.keyOrder = keyOrder
        self.escapeSlashes = escapeSlashes
        self.nilStrategy = nilStrategy
        self.prettyPrinted = prettyPrinted
    }

    /// Strict RFC 8259 / ECMA-404: reject non-finite numbers, shortest numbers, declaration order.
    public static let rfc8259 = JSONEncodingOptions()

    /// Byte-for-byte JavaScript `JSON.stringify`: non-finite → `null`, ECMA-262 number formatting.
    public static let javaScript = JSONEncodingOptions(nonFinite: .null, numberFormat: .ecma262)

    /// SQLite's JSON text: `%!.15g` reals, unescaped slashes, declaration order, minified — matches
    /// `sqlite3`'s `json()` / `json_quote()` output for the value model.
    public static let sqlite = JSONEncodingOptions(numberFormat: .sqlitePrintfG)
}
