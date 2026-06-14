import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// Generates `ADJSONSchemaProviding` conformance: a compile-time JSON Schema describing the struct's
// stored properties. The schema is produced as JSON *text* — scalars/arrays/dictionaries/optionals
// resolve to literal fragments, while nested custom types compose at runtime by referencing their
// own `__adjsonSchemaText`. This mirrors the runtime mapping in `SchemaInference.describeValue`.
struct SchemableMacro: ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(note(node, "Schemable", "@Schemable only supports structs; no schema generated"))
            return []
        }
        if declaresCodingKeys(structDecl) {
            context.diagnose(
                note(node, "Schemable", "@Schemable skips types with custom CodingKeys; no schema generated"))
            return []
        }
        guard let props = schemaProperties(structDecl) else {
            context.diagnose(note(node, "Schemable", "@Schemable needs explicit property types; no schema generated"))
            return []
        }

        let enclosing = type.trimmedDescription
        var selfRefs: [String] = []
        let body = schemaTextBody(props, enclosing: enclosing, selfRefs: &selfRefs)
        if !selfRefs.isEmpty {
            context.diagnose(
                note(
                    node, "Schemable",
                    "@Schemable does not yet support self-referential types; describing "
                        + "\(selfRefs.joined(separator: ", ")) as an open object"))
        }

        let ext = try ExtensionDeclSyntax(
            """
            extension \(raw: enclosing): ADJSONSchemaProviding {
                public static var __adjsonSchemaText: String { \(raw: body) }
                public static var jsonSchema: JSONSchema { __adjsonSchemaCompiled }
                private static let __adjsonSchemaCompiled: JSONSchema =
                    (try? JSONSchema(parsing: __adjsonSchemaText)) ?? .permitAll
            }
            """
        )
        return [ext]
    }
}

// MARK: - Property extraction

private func schemaProperties(_ decl: StructDeclSyntax) -> [(name: String, type: TypeSyntax)]? {
    var props: [(name: String, type: TypeSyntax)] = []
    for member in decl.memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        let modifiers = varDecl.modifiers.map(\.name.text)
        if modifiers.contains("static") || modifiers.contains("lazy") { continue }
        for binding in varDecl.bindings {
            if isComputed(binding.accessorBlock) { continue }
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            guard let type = binding.typeAnnotation?.type else { return nil }
            props.append((name, type))
        }
    }
    return props
}

// MARK: - Schema-text codegen

// A piece of the generated `__adjsonSchemaText` expression: either literal JSON characters, or a
// reference to a nested type whose `__adjsonSchemaText` is concatenated at runtime.
private enum Seg {
    case lit(String)
    case ref(String)
}

private func schemaTextBody(
    _ props: [(name: String, type: TypeSyntax)], enclosing: String, selfRefs: inout [String]
) -> String {
    let sorted = props.sorted { $0.name < $1.name }
    var segs: [Seg] = [.lit("{\"type\":\"object\"")]
    if !sorted.isEmpty {
        segs.append(.lit(",\"properties\":{"))
        for (index, p) in sorted.enumerated() {
            let prefix = index == 0 ? "" : ","
            segs.append(.lit(prefix + quoted(p.name) + ":"))
            segs.append(contentsOf: fragment(for: p.type, enclosing: enclosing, selfRefs: &selfRefs))
        }
        segs.append(.lit("}"))
        let required = sorted.filter { !isOptionalType($0.type) }.map(\.name).sorted()
        if !required.isEmpty {
            segs.append(.lit(",\"required\":[" + required.map(quoted).joined(separator: ",") + "]"))
        }
    }
    segs.append(.lit("}"))
    return emit(merge(segs))
}

private func fragment(for type: TypeSyntax, enclosing: String, selfRefs: inout [String]) -> [Seg] {
    if let wrapped = optionalWrapped(type) {
        return fragment(for: wrapped, enclosing: enclosing, selfRefs: &selfRefs)
    }
    if let array = type.as(ArrayTypeSyntax.self) {
        return [.lit("{\"type\":\"array\",\"items\":")]
            + fragment(for: array.element, enclosing: enclosing, selfRefs: &selfRefs) + [.lit("}")]
    }
    if let dict = type.as(DictionaryTypeSyntax.self) {
        return [.lit("{\"type\":\"object\",\"additionalProperties\":")]
            + fragment(for: dict.value, enclosing: enclosing, selfRefs: &selfRefs) + [.lit("}")]
    }
    if let id = type.as(IdentifierTypeSyntax.self) {
        let base = id.name.text
        if let generics = id.genericArgumentClause?.arguments.map(\.argument) {
            if base == "Array", let inner = generics.first {
                return [.lit("{\"type\":\"array\",\"items\":")]
                    + fragment(for: inner, enclosing: enclosing, selfRefs: &selfRefs) + [.lit("}")]
            }
            if base == "Dictionary", generics.count >= 2 {
                return [.lit("{\"type\":\"object\",\"additionalProperties\":")]
                    + fragment(for: generics[1], enclosing: enclosing, selfRefs: &selfRefs) + [.lit("}")]
            }
        }
        if base == "Bool" { return [.lit("{\"type\":\"boolean\"}")] }
        if integerTypes.contains(base) { return [.lit("{\"type\":\"integer\"}")] }
        if base == "Double" || base == "Float" { return [.lit("{\"type\":\"number\"}")] }
        if base == "String" { return [.lit("{\"type\":\"string\"}")] }
        if base == enclosing {
            selfRefs.append(base)
            return [.lit("{\"type\":\"object\"}")]
        }
        return [.ref(base)]
    }
    return [.lit("{\"type\":\"object\"}")]
}

// Optional<T> / T? -> T (one level). Spelled-out `Optional<T>` is handled alongside the `?` sugar.
private func optionalWrapped(_ type: TypeSyntax) -> TypeSyntax? {
    if let opt = type.as(OptionalTypeSyntax.self) { return opt.wrappedType }
    if let id = type.as(IdentifierTypeSyntax.self), id.name.text == "Optional" {
        return id.genericArgumentClause?.arguments.first?.argument
    }
    return nil
}

private func isOptionalType(_ type: TypeSyntax) -> Bool { optionalWrapped(type) != nil }

private func quoted(_ s: String) -> String { "\"\(s)\"" }

// Collapses adjacent literal segments so the emitted expression has fewer `+` operands.
private func merge(_ segs: [Seg]) -> [Seg] {
    var out: [Seg] = []
    for seg in segs {
        if case .lit(let a) = seg, let last = out.last, case .lit(let b) = last {
            out[out.count - 1] = .lit(b + a)
        } else {
            out.append(seg)
        }
    }
    return out
}

// Renders segments as a Swift expression: literals become raw string literals (`#"..."#`, so the
// JSON quotes need no escaping), type references become `T.__adjsonSchemaText`, joined with `+`.
private func emit(_ segs: [Seg]) -> String {
    let pieces = segs.map { seg -> String in
        switch seg {
        case .lit(let s): return "#\"" + s + "\"#"
        case .ref(let t): return t + ".__adjsonSchemaText"
        }
    }
    return pieces.isEmpty ? "#\"\"#" : pieces.joined(separator: " + ")
}
