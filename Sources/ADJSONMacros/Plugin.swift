import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct ADJSONMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        JSONCodableMacro.self, SchemableMacro.self,
        SchemaNumberMacro.self, SchemaStringMacro.self, SchemaEnumMacro.self, SchemaInfoMacro.self,
    ]
}

private struct Property {
    let name: String
    let type: String
    let isOptional: Bool
    let wrapped: String  // element type when optional, else == type
}

struct JSONCodableMacro: ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(
                note(node, "JSONCodable", "@JSONCodable only supports structs; the type keeps standard Codable"))
            return []
        }
        if declaresCodingKeys(structDecl) {
            context.diagnose(
                note(node, "JSONCodable", "@JSONCodable skips types with custom CodingKeys; keeping standard Codable"))
            return []
        }
        guard let props = storedProperties(structDecl) else {
            context.diagnose(
                note(node, "JSONCodable", "@JSONCodable needs explicit property types; keeping standard Codable"))
            return []
        }

        let decodeBody = makeDecodeBody(props)
        let encodeBody = makeEncodeBody(props)

        let ext = try ExtensionDeclSyntax(
            """
            extension \(raw: type.trimmedDescription): ADJSONFastDecodable, ADJSONFastEncodable {
                public static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
                    \(raw: decodeBody)
                }
                public func __adjsonEncode(into w: inout _JSONByteWriter) throws {
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

// MARK: - Codegen helpers

// Single-pass decode: resolve every field's value index in one `forEachMember` walk, then decode
// each field from its index — O(K) instead of O(fields × K) repeated key scans. Last-value-wins is
// preserved because a later duplicate key overwrites the stored index.
private func makeDecodeBody(_ props: [Property]) -> String {
    let ctorArgs = props.map { "\($0.name): \($0.name)" }.joined(separator: ", ")
    if props.isEmpty { return "return Self(\(ctorArgs))" }
    var lines = props.map { "var __vi_\($0.name) = -1" }
    let dispatch = props.enumerated().map { index, p in
        "\(index == 0 ? "if" : "else if") __k.matches(\"\(p.name)\") { __vi_\(p.name) = __v }"
    }.joined(separator: " ")
    lines.append("c.forEachMember { __k, __v in \(dispatch) }")
    lines.append(contentsOf: props.map { "let \($0.name) = \(decodeAtExpr($0))" })
    lines.append("return Self(\(ctorArgs))")
    return lines.joined(separator: "\n        ")
}

private func decodeAtExpr(_ p: Property) -> String {
    let vi = "__vi_\(p.name)"
    let key = "\"\(p.name)\""
    if p.isOptional {
        if integerTypes.contains(p.wrapped) { return "c.integerIfPresentAt(\(vi), \(p.wrapped).self)" }
        switch p.wrapped {
        case "String": return "c.stringIfPresentAt(\(vi))"
        case "Bool": return "c.boolIfPresentAt(\(vi))"
        case "Double": return "c.doubleIfPresentAt(\(vi))"
        default: return "try c.decodeIfPresentAt(\(p.wrapped).self, \(vi))"
        }
    }
    if integerTypes.contains(p.wrapped) { return "try c.integerAt(\(vi), \(key), \(p.wrapped).self)" }
    switch p.wrapped {
    case "String": return "try c.stringAt(\(vi), \(key))"
    case "Bool": return "try c.boolAt(\(vi), \(key))"
    case "Double": return "try c.doubleAt(\(vi), \(key))"
    default: return "try c.decodeAt(\(p.type).self, \(vi), \(key))"
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
