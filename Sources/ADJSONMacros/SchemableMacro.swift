import ADFMacroSupport
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// Generates `ADJSONSchemaProviding` conformance: a compile-time JSON Schema describing the struct's
// stored properties. The schema is produced as JSON *text* — scalars/arrays/dictionaries/optionals
// resolve to literal fragments, while nested custom types and `String` enums compose at runtime via
// `__adjsonSchemaFragment`. This mirrors the runtime mapping in `SchemaInference.describeValue`.
//
// Two layers feed the text: inference (the Swift type → JSON type; a `///` doc comment →
// `description`; a `String`/`CaseIterable` enum type → `enum`) and the property decorators
// (`@SchemaNumber`/`@SchemaString`/`@SchemaEnum`/`@SchemaInfo`). `@Schemable(dialect:)` adds a root
// `$schema`; the bare `__adjsonSchemaText` never carries one so inlined children stay dialect-free.
//
// LIMITATION — type matching is purely SYNTACTIC (the macro sees the written type, not its resolved
// declaration). A scalar spelled unusually defeats the mapping: a typealias (`typealias UserId =
// Int`) is treated as a nested type (resolved at runtime, falling back to an open object if it isn't
// `@Schemable`), and a qualified name (`Swift.Int`) or any non-identifier type is described as an
// open object. Spell scalar property types plainly (`Int`, not `Swift.Int` or an alias), or pin the
// shape with a decorator (`@SchemaNumber`/`@SchemaString`/`@SchemaEnum`). The macro emits a warning
// for each property it can only describe as an open object.
struct SchemableMacro: ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(
                SyntaxExtract.note(node, "Schemable", "@Schemable only supports structs; no schema generated"))
            return []
        }
        if SyntaxExtract.declaresCodingKeys(structDecl) {
            context.diagnose(
                SyntaxExtract.note(
                    node, "Schemable", "@Schemable skips types with custom CodingKeys; no schema generated"))
            return []
        }
        guard let props = schemaProperties(structDecl) else {
            context.diagnose(
                SyntaxExtract.note(node, "Schemable", "@Schemable needs explicit property types; no schema generated"))
            return []
        }

        let enclosing = type.trimmedDescription
        var selfRefs: [String] = []
        var unresolved: [String] = []
        let body = schemaTextBody(props, enclosing: enclosing, selfRefs: &selfRefs, unresolved: &unresolved)
        if !selfRefs.isEmpty {
            context.diagnose(
                SyntaxExtract.note(
                    node, "Schemable",
                    "@Schemable does not yet support self-referential types; describing "
                        + "\(selfRefs.joined(separator: ", ")) as an open object"))
        }
        if !unresolved.isEmpty {
            context.diagnose(
                SyntaxExtract.note(
                    node, "Schemable",
                    "@Schemable can't resolve \(unresolved.joined(separator: ", ")) to a JSON type "
                        + "(type matching is syntactic) — describing as an open object. Spell scalar types "
                        + "plainly (e.g. `Int`, not `Swift.Int` or a typealias) or use a @Schema… decorator."))
        }

        // The rooted document differs from the bare fragment only by a leading `$schema` member,
        // spliced in at runtime so the dialect literal stays byte-exact.
        let rootText: String
        if let url = dialectSchemaURL(node) {
            let member = JSONLiteral.string("$schema") + ":" + JSONLiteral.string(url)
            rootText = "__adjsonInsertingFirstMember(__adjsonSchemaText, \(JSONLiteral.rawLiteral(member)))"
        } else {
            rootText = "__adjsonSchemaText"
        }

        let ext = try ExtensionDeclSyntax(
            """
            extension \(raw: enclosing): ADJSONSchemaProviding {
                public static var __adjsonSchemaText: String { \(raw: body) }
                public static var jsonSchemaText: String { \(raw: rootText) }
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

private struct SchemaProperty {
    let name: String
    let type: TypeSyntax
    let doc: String?
    let decorators: SchemaDecorators
}

private func schemaProperties(_ decl: StructDeclSyntax) -> [SchemaProperty]? {
    var props: [SchemaProperty] = []
    for member in decl.memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        let modifiers = varDecl.modifiers.map(\.name.text)
        if modifiers.contains("static") || modifiers.contains("lazy") { continue }
        let doc = SyntaxExtract.docComment(varDecl)
        let decorators = SchemaDecorators.parse(varDecl)
        for binding in varDecl.bindings {
            if SyntaxExtract.isComputed(binding.accessorBlock) { continue }
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            guard let type = binding.typeAnnotation?.type else { return nil }
            props.append(SchemaProperty(name: name, type: type, doc: doc, decorators: decorators))
        }
    }
    return props
}

// MARK: - Schema-text codegen

// A piece of the generated `__adjsonSchemaText` expression: literal JSON characters, or a runtime
// call composing a nested type / `String` enum (with an optional `description` spliced in).
private enum Seg {
    case lit(String)
    case refCall(type: String, desc: String?, title: String?)
}

private func schemaTextBody(
    _ props: [SchemaProperty], enclosing: String, selfRefs: inout [String], unresolved: inout [String]
) -> String {
    // `properties` is always present (even when empty) to match zod's `tools/list` output for
    // no-argument tools. Properties and `required` follow declaration order.
    var segs: [Seg] = [.lit("{\"type\":\"object\",\"properties\":{")]
    for (index, p) in props.enumerated() {
        let prefix = index == 0 ? "" : ","
        segs.append(.lit(prefix + JSONLiteral.string(p.name) + ":"))
        segs.append(contentsOf: propertyFragment(p, enclosing: enclosing, selfRefs: &selfRefs, unresolved: &unresolved))
    }
    segs.append(.lit("}"))
    let required = props.filter { !isOptionalType($0.type) }.map(\.name)
    if !required.isEmpty {
        segs.append(.lit(",\"required\":[" + required.map(JSONLiteral.string).joined(separator: ",") + "]"))
    }
    segs.append(.lit("}"))
    return emit(merge(segs))
}

private func propertyFragment(
    _ p: SchemaProperty, enclosing: String, selfRefs: inout [String], unresolved: inout [String]
) -> [Seg] {
    // `@SchemaInfo(description:)` wins over the `///` doc comment; `@SchemaInfo(title:)` adds a title.
    let desc = p.decorators.description ?? p.doc
    return fragment(
        for: p.type, meta: SchemaMeta(desc: desc, title: p.decorators.title), dec: p.decorators,
        enclosing: enclosing, selfRefs: &selfRefs, unresolved: &unresolved)
}

/// The optional `description` / `title` annotations a schema fragment carries.
private struct SchemaMeta {
    let desc: String?
    let title: String?
    static let none = SchemaMeta(desc: nil, title: nil)
}

private func fragment(
    for type: TypeSyntax, meta: SchemaMeta, dec: SchemaDecorators,
    enclosing: String, selfRefs: inout [String], unresolved: inout [String]
) -> [Seg] {
    let desc = meta.desc
    let title = meta.title
    // `@SchemaEnum` forces a closed `String` set regardless of the declared type (covers bare `String`).
    if let values = dec.enumValues {
        let body =
            "{" + annotationPrefix(desc: desc, title: title) + "\"type\":\"string\",\"enum\":["
            + values.map(JSONLiteral.string).joined(separator: ",") + "]" + stringConstraints(dec) + "}"
        return [.lit(body)]
    }

    if let wrapped = optionalWrapped(type) {
        return fragment(
            for: wrapped, meta: SchemaMeta(desc: desc, title: title), dec: dec, enclosing: enclosing,
            selfRefs: &selfRefs, unresolved: &unresolved)
    }
    if let array = type.as(ArrayTypeSyntax.self) {
        return arrayFragment(
            element: array.element, desc: desc, title: title, enclosing: enclosing, selfRefs: &selfRefs,
            unresolved: &unresolved)
    }
    if let dict = type.as(DictionaryTypeSyntax.self) {
        return dictFragment(
            value: dict.value, desc: desc, title: title, enclosing: enclosing, selfRefs: &selfRefs,
            unresolved: &unresolved)
    }
    if let id = type.as(IdentifierTypeSyntax.self) {
        let base = id.name.text
        if let generics = id.genericArgumentClause?.arguments.compactMap({ $0.argument.as(TypeSyntax.self) }) {
            if base == "Array", let inner = generics.first {
                return arrayFragment(
                    element: inner, desc: desc, title: title, enclosing: enclosing, selfRefs: &selfRefs,
                    unresolved: &unresolved)
            }
            if base == "Dictionary", generics.count >= 2 {
                return dictFragment(
                    value: generics[1], desc: desc, title: title, enclosing: enclosing, selfRefs: &selfRefs,
                    unresolved: &unresolved)
            }
        }
        if base == "Bool" {
            return [.lit("{" + annotationPrefix(desc: desc, title: title) + "\"type\":\"boolean\"}")]
        }
        if integerTypes.contains(base) {
            return [
                .lit(
                    scalarObject(
                        forcedNumberType(dec) ?? "integer", desc: desc, title: title,
                        constraints: numberConstraints(dec)))
            ]
        }
        if base == "Double" || base == "Float" {
            return [
                .lit(
                    scalarObject(
                        forcedNumberType(dec) ?? "number", desc: desc, title: title,
                        constraints: numberConstraints(dec)))
            ]
        }
        if base == "String" {
            return [.lit(scalarObject("string", desc: desc, title: title, constraints: stringConstraints(dec)))]
        }
        if base == enclosing {
            selfRefs.append(base)
            return [.lit("{" + annotationPrefix(desc: desc, title: title) + "\"type\":\"object\"}")]
        }
        // Nested `@Schemable` object or a `String`-`CaseIterable` enum: resolved at runtime by the
        // overloaded `__adjsonSchemaFragment`.
        return [.refCall(type: type.trimmedDescription, desc: desc, title: title)]
    }
    // A type the syntactic matcher can't map to a JSON kind (a qualified name like `Swift.Int`, a
    // tuple, a closure, …): described as an open object, and flagged so the author can fix it.
    unresolved.append(type.trimmedDescription)
    return [.lit("{" + annotationPrefix(desc: desc, title: title) + "\"type\":\"object\"}")]
}

private func arrayFragment(
    element: TypeSyntax, desc: String?, title: String?, enclosing: String, selfRefs: inout [String],
    unresolved: inout [String]
) -> [Seg] {
    [.lit("{" + annotationPrefix(desc: desc, title: title) + "\"type\":\"array\",\"items\":")]
        + fragment(
            for: element, meta: .none, dec: SchemaDecorators(), enclosing: enclosing,
            selfRefs: &selfRefs, unresolved: &unresolved)
        + [.lit("}")]
}

private func dictFragment(
    value: TypeSyntax, desc: String?, title: String?, enclosing: String, selfRefs: inout [String],
    unresolved: inout [String]
) -> [Seg] {
    [.lit("{" + annotationPrefix(desc: desc, title: title) + "\"type\":\"object\",\"additionalProperties\":")]
        + fragment(
            for: value, meta: .none, dec: SchemaDecorators(), enclosing: enclosing,
            selfRefs: &selfRefs, unresolved: &unresolved)
        + [.lit("}")]
}

// MARK: - Fragment building blocks

private func scalarObject(_ type: String, desc: String?, title: String?, constraints: String) -> String {
    "{" + annotationPrefix(desc: desc, title: title) + "\"type\":\"" + type + "\"" + constraints + "}"
}

private func annotationPrefix(desc: String?, title: String?) -> String {
    var s = ""
    if let title { s += "\"title\":" + JSONLiteral.string(title) + "," }
    if let desc { s += "\"description\":" + JSONLiteral.string(desc) + "," }
    return s
}

private func forcedNumberType(_ d: SchemaDecorators) -> String? {
    switch d.numberType {
        case "integer": return "integer"
        case "number": return "number"
        default: return nil
    }
}

private func numberConstraints(_ d: SchemaDecorators) -> String {
    var s = ""
    if let v = d.minimum { s += ",\"minimum\":" + v }
    if let v = d.maximum { s += ",\"maximum\":" + v }
    if let v = d.exclusiveMinimum { s += ",\"exclusiveMinimum\":" + v }
    if let v = d.exclusiveMaximum { s += ",\"exclusiveMaximum\":" + v }
    if let v = d.multipleOf { s += ",\"multipleOf\":" + v }
    return s
}

private func stringConstraints(_ d: SchemaDecorators) -> String {
    var s = ""
    if let v = d.minLength { s += ",\"minLength\":" + v }
    if let v = d.maxLength { s += ",\"maxLength\":" + v }
    if let v = d.pattern { s += ",\"pattern\":" + JSONLiteral.string(v) }
    if let v = d.format { s += ",\"format\":" + JSONLiteral.string(v) }
    return s
}

private func dialectSchemaURL(_ node: AttributeSyntax) -> String? {
    guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for arg in args where arg.label?.text == "dialect" {
        switch SyntaxExtract.memberAccessName(arg.expression) {
            case "draft7": return "http://json-schema.org/draft-07/schema#"
            case "draft2020_12": return "https://json-schema.org/draft/2020-12/schema"
            default: return nil
        }
    }
    return nil
}

// MARK: - Type helpers

// Optional<T> / T? -> T (one level). Spelled-out `Optional<T>` is handled alongside the `?` sugar.
private func optionalWrapped(_ type: TypeSyntax) -> TypeSyntax? {
    if let opt = type.as(OptionalTypeSyntax.self) { return opt.wrappedType }
    if let id = type.as(IdentifierTypeSyntax.self), id.name.text == "Optional" {
        return id.genericArgumentClause?.arguments.first?.argument.as(TypeSyntax.self)
    }
    return nil
}

private func isOptionalType(_ type: TypeSyntax) -> Bool { optionalWrapped(type) != nil }

// MARK: - Expression assembly

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

// Renders segments as a Swift expression: literals become raw string literals (adaptive `#`
// delimiters so embedded `"#`/escaped quotes are safe); refs become `__adjsonSchemaFragment` calls.
private func emit(_ segs: [Seg]) -> String {
    let pieces = segs.map { seg -> String in
        switch seg {
            case .lit(let s):
                return JSONLiteral.rawLiteral(s)
            case .refCall(let type, let desc, let title):
                let d = desc.map(SwiftSource.stringLiteral) ?? "nil"
                let t = title.map(SwiftSource.stringLiteral) ?? "nil"
                return "__adjsonSchemaFragment(for: \(type).self, description: \(d), title: \(t))"
        }
    }
    return pieces.isEmpty ? "#\"\"#" : pieces.joined(separator: " + ")
}
