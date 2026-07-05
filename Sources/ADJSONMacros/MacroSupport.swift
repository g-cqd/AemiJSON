import ADFMacroSupport
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax

// Shared helpers for the ADJSON macros (`@JSONCodable`, `@Schemable`), grouped into two caseless-enum
// namespaces — the idiomatic Swift home for these small families of free functions: `JSONLiteral`
// (compile-time JSON text emission) and `SyntaxExtract` (SwiftSyntax inspection + diagnostics).

// Integer scalar type names. Mapped to the fast integer path (`@JSONCodable`) and to JSON
// `"integer"` (`@Schemable`).
let integerTypes: Set<String> = [
    "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64"
]

// MARK: - JSON literal emission

/// Compile-time JSON text emission — mirrors the runtime `JSONOutput` escaping so a description
/// escaped here is byte-identical to one escaped at runtime by `__adjsonJSONString`.
enum JSONLiteral {
    /// JSON string *content* (no surrounding quotes) with RFC 8259 minimal escaping. `/` is left
    /// unescaped.
    static func escaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
                case "\"": out += #"\""#
                case "\\": out += #"\\"#
                case "\n": out += #"\n"#
                case "\r": out += #"\r"#
                case "\t": out += #"\t"#
                case "\u{08}": out += #"\b"#
                case "\u{0C}": out += #"\f"#
                default:
                    if scalar.value < 0x20 {
                        out += "\\u00"
                        out.append(hexDigit(scalar.value >> 4))
                        out.append(hexDigit(scalar.value & 0xF))
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
            }
        }
        return out
    }

    /// A complete JSON string literal (quoted + escaped) ready to splice into emitted JSON text.
    static func string(_ s: String) -> String { "\"" + escaped(s) + "\"" }

    /// Wraps raw JSON text in a Swift raw-string literal, choosing enough `#` delimiters that the
    /// content (which may contain `"#`) cannot terminate the literal early. The JSON text never holds
    /// a literal newline (descriptions are escaped to `\n`), so a single-line raw literal is always
    /// valid.
    static func rawLiteral(_ s: String) -> String {
        var maxRun = 0
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\"" {
                var run = 0
                var j = i + 1
                while j < scalars.count, scalars[j] == "#" {
                    run += 1
                    j += 1
                }
                if run > maxRun { maxRun = run }
                i = j
            } else {
                i += 1
            }
        }
        let pounds = String(repeating: "#", count: maxRun + 1)
        return pounds + "\"" + s + "\"" + pounds
    }

    private static func hexDigit(_ v: UInt32) -> Character {
        // `v` is a nibble (0...15), so the code unit is '0'...'9' / 'a'...'f' — always ASCII, fitting
        // the non-failable `UnicodeScalar(UInt8)` initializer (no force-unwrap).
        Character(UnicodeScalar(UInt8(v < 10 ? 0x30 + v : 0x61 + (v &- 10))))
    }
}

// MARK: - SwiftSyntax extraction + diagnostics

/// SwiftSyntax inspection for the ADJSON macros: declaration classification, doc-comment and
/// attribute-argument extraction, and the shared diagnostic builder.
enum SyntaxExtract {
    /// True when the struct declares a custom `CodingKeys` enum. Both macros skip such types: a custom
    /// `CodingKeys` can remap JSON keys away from the property names the generated fast path assumes.
    static func declaresCodingKeys(_ decl: StructDeclSyntax) -> Bool {
        decl.memberBlock.members.contains { member in
            member.decl.as(EnumDeclSyntax.self)?.name.text == "CodingKeys"
        }
    }

    /// A binding is computed when it exposes a getter; `willSet`/`didSet` observers keep it stored.
    static func isComputed(_ accessor: AccessorBlockSyntax?) -> Bool {
        guard let accessor else { return false }
        switch accessor.accessors {
            case .getter:
                return true
            case .accessors(let list):
                return list.contains { $0.accessorSpecifier.tokenKind == .keyword(.get) }
        }
    }

    /// A `.warning` anchored on the macro attribute, in the shared "ADJSON" diagnostic domain. Both
    /// macros degrade gracefully (return no extension) rather than erroring, so warnings — not errors —
    /// are emitted. (Backed by ADFMacroSupport's shared `SimpleDiagnostic` + builder.)
    static func note(_ node: AttributeSyntax, _ id: String, _ message: String) -> Diagnostic {
        MacroDiagnostics.make(node, domain: "ADJSON", id: id, message)
    }

    /// The `///` (or `/** */`) doc comment immediately preceding a property, as plain text. Multiple
    /// `///` lines join with newlines. Returns nil when there is no doc comment.
    static func docComment(_ decl: VariableDeclSyntax) -> String? {
        var lines: [String] = []
        for piece in decl.leadingTrivia {
            switch piece {
                case .docLineComment(let text):
                    var t = Substring(text)
                    if t.hasPrefix("///") { t = t.dropFirst(3) }
                    lines.append(trimWhitespace(String(t)))
                case .docBlockComment(let text):
                    var t = Substring(text)
                    if t.hasPrefix("/**") { t = t.dropFirst(3) }
                    if t.hasSuffix("*/") { t = t.dropLast(2) }
                    for line in t.split(separator: "\n", omittingEmptySubsequences: false) {
                        var l = trimWhitespace(String(line))
                        if l.hasPrefix("*") { l = trimWhitespace(String(l.dropFirst())) }
                        if !l.isEmpty { lines.append(l) }
                    }
                default:
                    continue
            }
        }
        let joined = trimWhitespace(lines.joined(separator: "\n"))
        return joined.isEmpty ? nil : joined
    }

    /// The compile-time value of a static string literal (handles raw strings); nil for interpolation.
    static func stringLiteralValue(_ expr: ExprSyntax) -> String? {
        expr.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }

    /// The member name of a `.case` expression, e.g. `.number` → "number".
    static func memberAccessName(_ expr: ExprSyntax) -> String? {
        expr.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    /// A numeric literal rendered as a valid JSON number, or nil when it can't be (so the constraint is
    /// omitted rather than emitted as invalid JSON, which would collapse the whole compiled schema to
    /// `.permitAll`). Underscores are stripped; hex/octal/binary integer literals are normalized to
    /// decimal; hex floats are rejected; a leading `-` is kept and a redundant `+` dropped (JSON forbids
    /// a leading `+`).
    static func numericLiteralText(_ expr: ExprSyntax) -> String? {
        if let i = expr.as(IntegerLiteralExprSyntax.self) { return jsonIntegerLiteral(i.literal.text) }
        if let f = expr.as(FloatLiteralExprSyntax.self) { return jsonFloatLiteral(f.literal.text) }
        if let p = expr.as(PrefixOperatorExprSyntax.self), let inner = numericLiteralText(p.expression) {
            let text = p.trimmedDescription
            if text.hasPrefix("-") { return "-" + inner }
            if text.hasPrefix("+") { return inner }
        }
        return nil
    }

    private static func trimWhitespace(_ s: String) -> String {
        func isWS(_ u: UnicodeScalar) -> Bool { u == " " || u == "\t" || u == "\n" || u == "\r" }
        let scalars = Array(s.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, isWS(scalars[start]) { start += 1 }
        while end > start, isWS(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start ..< end]))
    }

    private static func jsonIntegerLiteral(_ raw: String) -> String? {
        let t = String(raw.filter { $0 != "_" })
        let lower = t.lowercased()
        if lower.hasPrefix("0x") { return UInt64(t.dropFirst(2), radix: 16).map(String.init) }
        if lower.hasPrefix("0o") { return UInt64(t.dropFirst(2), radix: 8).map(String.init) }
        if lower.hasPrefix("0b") { return UInt64(t.dropFirst(2), radix: 2).map(String.init) }
        return !t.isEmpty && t.allSatisfy { ("0" ... "9").contains($0) } ? t : nil
    }

    private static func jsonFloatLiteral(_ raw: String) -> String? {
        let t = String(raw.filter { $0 != "_" })
        // Hex floats (`0x1p4`) are valid Swift but not JSON; decimal/exponent forms are valid as written.
        let lower = t.lowercased()
        return lower.contains("x") || lower.contains("p") ? nil : t
    }
}
