import ADJSONCore

// ============================================================================
// SCHEMA MACRO RUNTIME — SPI (not API). The public-underscored symbols here exist
// only for code emitted by `@Schemable`. A macro cannot inject an `@_spi` import
// into the user's file, so public-underscored is the idiomatic way to expose a
// macro runtime. Treat as unstable; use the generated `jsonSchemaText` /
// `jsonSchema` instead.
//
// A `@Schemable` type's `__adjsonSchemaText` is a *bare* schema fragment (an object
// that never carries `$schema`), built by concatenating compile-time JSON literals
// with the fragments of nested types. These helpers supply the runtime pieces of
// that concatenation: composing nested objects and `String`-enums, and splicing in
// `description` / `$schema` as an object's first member.
// ============================================================================

// Fragment for a property whose declared type is a nested `@Schemable` object.
// `description` (plain, unescaped text) is spliced in as the object's first member.
public func __adjsonSchemaFragment<T: ADJSONSchemaProviding>(
    for _: T.Type, description: String? = nil
) -> String {
    __adjsonApplyingDescription(T.__adjsonSchemaText, description)
}

// Fragment for a `String`-`RawRepresentable`, `CaseIterable` enum property:
// `{"type":"string","enum":[…]}` with cases in declaration order. Any
// `enum E: String, CaseIterable` satisfies this with no extra conformance. Since `@Schemable`
// only generates `ADJSONSchemaProviding` for structs, an inferred enum never conforms to both
// protocols, so the two overloads stay unambiguous. (A type *manually* conforming to both would
// make the generated call ambiguous — a loud compile error rather than wrong output.)
public func __adjsonSchemaFragment<T: CaseIterable & RawRepresentable>(
    for _: T.Type, description: String? = nil
) -> String where T.RawValue == String {
    var s = "{"
    if let description { s += "\"description\":" + __adjsonJSONString(description) + "," }
    s += "\"type\":\"string\",\"enum\":["
    var first = true
    for c in T.allCases {
        if !first { s += "," }
        s += __adjsonJSONString(c.rawValue)
        first = false
    }
    s += "]}"
    return s
}

// Inserts `member` (a raw `"key":value` JSON fragment) as the first member of `object`. `object` is
// always a fragment produced by this file or the macro, so it begins with exactly `{` and has no
// leading whitespace. The empty-object case is guarded so the result stays well-formed
// (`{member}`, not `{member,}`).
public func __adjsonInsertingFirstMember(_ object: String, _ member: String) -> String {
    object == "{}" ? "{" + member + "}" : "{" + member + "," + object.dropFirst()
}

// Canonical JSON string (quoted, RFC 8259 minimal escaping). Reuses the single
// byte-emission source so runtime escaping matches the encoder and the macro-side
// escaper exactly.
public func __adjsonJSONString(_ s: String) -> String {
    var bytes = [UInt8]()
    JSONOutput.appendString(s, to: &bytes)
    return String(decoding: bytes, as: UTF8.self)
}

private func __adjsonApplyingDescription(_ object: String, _ description: String?) -> String {
    guard let description else { return object }
    return __adjsonInsertingFirstMember(object, "\"description\":" + __adjsonJSONString(description))
}
