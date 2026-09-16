import SwiftSyntax
import SwiftSyntaxMacros

// The schema decorators (`@SchemaNumber`, `@SchemaString`, `@SchemaEnum`, `@SchemaInfo`) are marker
// macros: each introduces no peers and expands to nothing. Their arguments are read syntactically by
// `SchemableMacro` off the annotated property. Declaring them as no-op `PeerMacro`s is purely what
// makes `@SchemaNumber(...)` etc. valid attributes in user code.

struct SchemaNumberMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

struct SchemaStringMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

struct SchemaEnumMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

struct SchemaInfoMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

// MARK: - Decorator parsing (consumed by SchemableMacro)

// Constraints gathered from a property's decorator attributes. Numeric/length values are kept as
// verbatim literal text (so `1` stays `1`, never `1.0`); strings are kept as plain (unescaped) text.
struct SchemaDecorators {
    var description: String?
    var title: String?
    var enumValues: [String]?
    var numberType: String?  // "integer" | "number"
    var minimum: String?
    var maximum: String?
    var exclusiveMinimum: String?
    var exclusiveMaximum: String?
    var multipleOf: String?
    var minLength: String?
    var maxLength: String?
    var pattern: String?
    var format: String?
}

extension SchemaDecorators {
    /// Gather the constraints from a property's decorator attributes (`@SchemaInfo`, `@SchemaNumber`,
    /// `@SchemaString`, `@SchemaEnum`), consumed by `SchemableMacro`.
    static func parse(_ varDecl: VariableDeclSyntax) -> SchemaDecorators {
        var d = SchemaDecorators()
        for attr in varDecl.attributes {
            guard let a = attr.as(AttributeSyntax.self),
                let name = a.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            else { continue }
            let args = a.arguments?.as(LabeledExprListSyntax.self).map(Array.init) ?? []
            switch name {
                case "SchemaInfo":
                    for x in args {
                        switch x.label?.text {
                            case "description": d.description = SyntaxExtract.stringLiteralValue(x.expression)
                            case "title": d.title = SyntaxExtract.stringLiteralValue(x.expression)
                            default: break
                        }
                    }
                case "SchemaNumber":
                    for x in args {
                        guard let label = x.label?.text else {
                            // Positional argument: a range literal (`1...100`, `1..<100`, `1...`, `...100`, `..<100`).
                            let r = rangeBounds(x.expression)
                            if let v = r.minimum { d.minimum = v }
                            if let v = r.maximum { d.maximum = v }
                            if let v = r.exclusiveMaximum { d.exclusiveMaximum = v }
                            continue
                        }
                        switch label {
                            case "minimum": d.minimum = SyntaxExtract.numericLiteralText(x.expression)
                            case "maximum": d.maximum = SyntaxExtract.numericLiteralText(x.expression)
                            case "exclusiveMinimum": d.exclusiveMinimum = SyntaxExtract.numericLiteralText(x.expression)
                            case "exclusiveMaximum": d.exclusiveMaximum = SyntaxExtract.numericLiteralText(x.expression)
                            case "multipleOf": d.multipleOf = SyntaxExtract.numericLiteralText(x.expression)
                            case "type": d.numberType = SyntaxExtract.memberAccessName(x.expression)
                            default: break
                        }
                    }
                case "SchemaString":
                    for x in args {
                        switch x.label?.text {
                            case "minLength": d.minLength = SyntaxExtract.numericLiteralText(x.expression)
                            case "maxLength": d.maxLength = SyntaxExtract.numericLiteralText(x.expression)
                            case "pattern": d.pattern = SyntaxExtract.stringLiteralValue(x.expression)
                            case "format": d.format = SyntaxExtract.stringLiteralValue(x.expression)
                            default: break
                        }
                    }
                case "SchemaEnum":
                    if let arr = args.first?.expression.as(ArrayExprSyntax.self) {
                        d.enumValues = arr.elements.compactMap { SyntaxExtract.stringLiteralValue($0.expression) }
                    }
                default:
                    break
            }
        }
        return d
    }

    // Maps a range literal to numeric bounds, reading the bound *literals* verbatim. Attribute arguments
    // reach the macro unfolded, so `a...b` / `a..<b` arrive as a `SequenceExprSyntax` ([a, op, b]) and the
    // partial ranges as prefix/postfix operator expressions.
    private static func rangeBounds(
        _ expr: ExprSyntax
    ) -> (minimum: String?, maximum: String?, exclusiveMaximum: String?) {
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            if elems.count == 3 {
                let op = elems[1].trimmedDescription
                let lo = SyntaxExtract.numericLiteralText(elems[0])
                let hi = SyntaxExtract.numericLiteralText(elems[2])
                if op == "..." { return (lo, hi, nil) }
                if op == "..<" { return (lo, nil, hi) }
            }
        }
        if let pre = expr.as(PrefixOperatorExprSyntax.self) {
            let text = pre.trimmedDescription
            if text.hasPrefix("..<") { return (nil, nil, SyntaxExtract.numericLiteralText(pre.expression)) }
            if text.hasPrefix("...") { return (nil, SyntaxExtract.numericLiteralText(pre.expression), nil) }
        }
        if let post = expr.as(PostfixOperatorExprSyntax.self), post.trimmedDescription.hasSuffix("...") {
            return (SyntaxExtract.numericLiteralText(post.expression), nil, nil)
        }
        return (nil, nil, nil)
    }
}
