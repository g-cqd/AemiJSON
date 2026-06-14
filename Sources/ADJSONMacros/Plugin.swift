import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct ADJSONMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [JSONCodableMacro.self]
}

private struct Property {
    let name: String
    let type: String
    let isOptional: Bool
    let wrapped: String  // element type when optional, else == type
}

public struct JSONCodableMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(note(node, "@JSONCodable only supports structs; the type keeps standard Codable"))
            return []
        }
        if declaresCodingKeys(structDecl) {
            context.diagnose(note(node, "@JSONCodable skips types with custom CodingKeys; keeping standard Codable"))
            return []
        }
        guard let props = storedProperties(structDecl) else {
            context.diagnose(note(node, "@JSONCodable needs explicit property types; keeping standard Codable"))
            return []
        }

        let decodeBindings = props.map { "let \($0.name) = \(decodeExpr($0))" }.joined(separator: "\n        ")
        let ctorArgs = props.map { "\($0.name): \($0.name)" }.joined(separator: ", ")
        let encodeBody = makeEncodeBody(props)

        let ext = try ExtensionDeclSyntax(
            """
            extension \(raw: type.trimmedDescription): ADJSONFastDecodable, ADJSONFastEncodable {
                public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
                    \(raw: decodeBindings)
                    return Self(\(raw: ctorArgs))
                }
                public func __adjsonEncode(into w: _FastEncodeWriter) throws {
                    w.beginObject()
                    \(raw: encodeBody)
                    w.endObject()
                }
            }
            """
        )
        return [ext]
    }
}

// MARK: - Property extraction

private func declaresCodingKeys(_ decl: StructDeclSyntax) -> Bool {
    decl.memberBlock.members.contains { member in
        member.decl.as(EnumDeclSyntax.self)?.name.text == "CodingKeys"
    }
}

private func storedProperties(_ decl: StructDeclSyntax) -> [Property]? {
    var props: [Property] = []
    for member in decl.memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        let modifiers = varDecl.modifiers.map(\.name.text)
        if modifiers.contains("static") || modifiers.contains("lazy") { continue }
        for binding in varDecl.bindings {
            if isComputed(binding.accessorBlock) { continue }
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            guard let typeSyntax = binding.typeAnnotation?.type else { return nil }
            if let optional = typeSyntax.as(OptionalTypeSyntax.self) {
                props.append(
                    Property(
                        name: name, type: typeSyntax.trimmedDescription, isOptional: true,
                        wrapped: optional.wrappedType.trimmedDescription))
            } else {
                let full = typeSyntax.trimmedDescription
                props.append(Property(name: name, type: full, isOptional: false, wrapped: full))
            }
        }
    }
    return props
}

private func isComputed(_ accessor: AccessorBlockSyntax?) -> Bool {
    guard let accessor else { return false }
    switch accessor.accessors {
    case .getter:
        return true
    case .accessors(let list):
        // willSet/didSet are stored-with-observers; a get/_read marks it computed.
        return list.contains { $0.accessorSpecifier.tokenKind == .keyword(.get) }
    }
}

// MARK: - Codegen helpers

private let integerTypes: Set<String> = [
    "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
]

private func decodeExpr(_ p: Property) -> String {
    let key = "\"\(p.name)\""
    if p.isOptional {
        if integerTypes.contains(p.wrapped) { return "c.integerIfPresent(\(key), \(p.wrapped).self)" }
        switch p.wrapped {
        case "String": return "c.stringIfPresent(\(key))"
        case "Bool": return "c.boolIfPresent(\(key))"
        case "Double": return "c.doubleIfPresent(\(key))"
        default: return "try c.decodeIfPresent(\(p.wrapped).self, \(key))"
        }
    }
    if integerTypes.contains(p.wrapped) { return "try c.integer(\(key), \(p.wrapped).self)" }
    switch p.wrapped {
    case "String": return "try c.string(\(key))"
    case "Bool": return "try c.bool(\(key))"
    case "Double": return "try c.double(\(key))"
    default: return "try c.decode(\(p.type).self, \(key))"
    }
}

// Emits the object members. When the first property is required it is always present,
// so every later member can prefix a comma unconditionally (no separator state, no dead
// code). When the first property is optional we track membership with `__wrote`, which is
// set conditionally so the compiler can't constant-fold the comma check.
private func makeEncodeBody(_ props: [Property]) -> String {
    guard let first = props.first else { return "" }
    var lines: [String] = []
    if first.isOptional {
        lines.append("var __wrote = false")
        for (index, p) in props.enumerated() {
            let key = "\"\(p.name)\""
            let comma = index == 0 ? "" : "if __wrote { w.comma() }; "
            if p.isOptional {
                lines.append(
                    "if let __v = self.\(p.name) { \(comma)w.key(\(key)); \(writeValue("__v", p.wrapped)); __wrote = true }"
                )
            } else {
                lines.append("\(comma)w.key(\(key)); \(writeValue("self.\(p.name)", p.wrapped)); __wrote = true")
            }
        }
    } else {
        for (index, p) in props.enumerated() {
            let key = "\"\(p.name)\""
            if index == 0 {
                lines.append("w.key(\(key)); \(writeValue("self.\(p.name)", p.wrapped))")
            } else if p.isOptional {
                lines.append(
                    "if let __v = self.\(p.name) { w.comma(); w.key(\(key)); \(writeValue("__v", p.wrapped)) }")
            } else {
                lines.append("w.comma(); w.key(\(key)); \(writeValue("self.\(p.name)", p.wrapped))")
            }
        }
    }
    return lines.joined(separator: "\n        ")
}

private func writeValue(_ expr: String, _ wrapped: String) -> String {
    if integerTypes.contains(wrapped) { return "w.integer(\(expr))" }
    switch wrapped {
    case "String": return "w.string(\(expr))"
    case "Bool": return "w.bool(\(expr))"
    case "Double": return "try w.double(\(expr))"
    default: return "try w.encode(\(expr))"
    }
}

private func note(_ node: AttributeSyntax, _ message: String) -> Diagnostic {
    Diagnostic(
        node: node,
        message: SimpleDiagnostic(
            message: message, diagnosticID: MessageID(domain: "ADJSON", id: "JSONCodable"), severity: .warning))
}

private struct SimpleDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
}
