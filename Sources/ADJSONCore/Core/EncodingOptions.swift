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
        /// The shortest round-trippable decimal in a canonical form (the default). A `Double`/`Float`
        /// always keeps a fractional part (`Double(2)` → `2.0`) or an exponent, so it never reads as a
        /// bare integer — only the `.int` case / integer-typed values render bare digits, and this holds
        /// uniformly across compact, pretty, sorted, the `JSONValue` tree, and the lazy cursor. The
        /// significant digits come from Swift's `Double.description`, but ADJSON owns the placement —
        /// fixed notation for a scientific exponent in `-4...15`, otherwise scientific (`e±NN`, ≥2
        /// exponent digits). That keeps output stable across Swift toolchains and removes
        /// `description`'s value-dependent fixed/scientific flip near 2^53. Not Foundation byte-for-byte
        /// (Foundation drops the trailing `.0`) — use `.ecma262` for `JSON.stringify` parity.
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

    /// The `key`/`value` separator emitted in pretty-printed output (ignored when compact, which
    /// always uses a bare `:`).
    public enum KeySeparator: Sendable, Equatable {
        /// `" : "` — space-colon-space, matching `Foundation`'s `.prettyPrinted` (the default).
        case foundation
        /// `": "` — colon-space, matching JavaScript `JSON.stringify(value, null, indent)`.
        case javaScript
    }

    /// The indentation unit emitted once per nesting level in pretty-printed output (ignored when
    /// `prettyPrinted` is false). Mirrors the two forms of `JSON.stringify`'s `space` argument.
    public enum Indent: Sendable, Equatable {
        /// `count` spaces per level (negatives treated as `0`). Two spaces — `Foundation`'s
        /// `.prettyPrinted` and the conventional `JSON.stringify` indent — is the default.
        case spaces(Int)
        /// An arbitrary literal indent unit per level, e.g. `"\t"` for tabs — the string form of
        /// `JSON.stringify`'s `space`.
        case string(String)

        /// The UTF-8 bytes emitted for one nesting level.
        package var unitBytes: [UInt8] {
            switch self {
                case .spaces(let count): Array(repeating: 0x20, count: max(0, count))
                case .string(let unit): Array(unit.utf8)
            }
        }
    }

    public var nonFinite: NonFiniteStrategy
    public var numberFormat: NumberFormat
    public var keyOrder: KeyOrder
    /// Escape `/` as `\/`. RFC 8259 and `JSON.stringify` both leave it unescaped (default `false`).
    public var escapeSlashes: Bool
    /// Escape characters unsafe to embed directly in HTML / `<script>`: `<`, `>`, `&`, and the JS
    /// line/paragraph separators U+2028 / U+2029. Off by default (output stays minimal RFC 8259).
    public var escapeHTMLUnsafe: Bool
    public var nilStrategy: NilStrategy
    /// Emit human-readable output: a newline after each `{`/`[`/`,`, `indent` per nesting level,
    /// and the `prettyKeySeparator` between keys and values (default `false`). Empty containers stay
    /// on one line (`[]` / `{}`).
    public var prettyPrinted: Bool
    /// The key/value separator used when `prettyPrinted` is set. Defaults to `.foundation` (`" : "`,
    /// matching `Foundation`'s `.prettyPrinted`); use `.javaScript` (`": "`) for `JSON.stringify`
    /// parity. No effect on compact output.
    public var prettyKeySeparator: KeySeparator
    /// The indentation unit per nesting level when `prettyPrinted` is set. Defaults to `.spaces(2)`
    /// (`Foundation`'s `.prettyPrinted` width). No effect on compact output.
    public var indent: Indent

    public init(
        nonFinite: NonFiniteStrategy = .throw,
        numberFormat: NumberFormat = .swiftShortest,
        keyOrder: KeyOrder = .declaration,
        escapeSlashes: Bool = false,
        nilStrategy: NilStrategy = .omit,
        prettyPrinted: Bool = false,
        prettyKeySeparator: KeySeparator = .foundation,
        indent: Indent = .spaces(2),
        escapeHTMLUnsafe: Bool = false
    ) {
        self.nonFinite = nonFinite
        self.numberFormat = numberFormat
        self.keyOrder = keyOrder
        self.escapeSlashes = escapeSlashes
        self.nilStrategy = nilStrategy
        self.prettyPrinted = prettyPrinted
        self.prettyKeySeparator = prettyKeySeparator
        self.indent = indent
        self.escapeHTMLUnsafe = escapeHTMLUnsafe
    }

    /// Strict RFC 8259 / ECMA-404: reject non-finite numbers, shortest numbers, declaration order.
    public static let rfc8259 = JSONEncodingOptions()

    /// Byte-for-byte JavaScript `JSON.stringify(value)` — compact: non-finite → `null`, ECMA-262
    /// number formatting. For the indented forms (`JSON.stringify(value, null, space)`), use the
    /// `javaScript(space:)` / `javaScript(indent:)` factories.
    public static let javaScript = JSONEncodingOptions(
        nonFinite: .null, numberFormat: .ecma262, prettyKeySeparator: .javaScript)

    /// JavaScript `JSON.stringify(value, null, space)` with a numeric `space`: indent each nesting
    /// level by `space` spaces, clamped to `0...10` exactly as the spec does (`Math.min(10, space)`,
    /// negatives treated as `0`). `space <= 0` yields the compact form (equivalent to `.javaScript`);
    /// `space > 0` pretty-prints with a `": "` separator. Non-finite → `null`, ECMA-262 numbers.
    public static func javaScript(space: Int) -> JSONEncodingOptions {
        let width = min(10, max(0, space))
        return JSONEncodingOptions(
            nonFinite: .null, numberFormat: .ecma262, prettyPrinted: width > 0,
            prettyKeySeparator: .javaScript, indent: .spaces(width))
    }

    /// JavaScript `JSON.stringify(value, null, space)` with a string `space`: indent each nesting
    /// level by `indent`, truncated to its first 10 characters as the spec does. An empty string
    /// yields the compact form (equivalent to `.javaScript`). Non-finite → `null`, ECMA-262 numbers.
    public static func javaScript(indent: String) -> JSONEncodingOptions {
        let unit = String(indent.prefix(10))
        return JSONEncodingOptions(
            nonFinite: .null, numberFormat: .ecma262, prettyPrinted: !unit.isEmpty,
            prettyKeySeparator: .javaScript, indent: .string(unit))
    }

    /// SQLite's JSON text: `%!.15g` reals, unescaped slashes, declaration order, minified — matches
    /// `sqlite3`'s `json()` / `json_quote()` output for the value model.
    public static let sqlite = JSONEncodingOptions(numberFormat: .sqlitePrintfG)
}
