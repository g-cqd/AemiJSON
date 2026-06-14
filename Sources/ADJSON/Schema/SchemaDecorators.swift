// Property decorators read by `@Schemable` to augment a field's generated JSON Schema. Each is a
// marker macro: it introduces no peers and expands to nothing on its own. `@Schemable` reads the
// attribute syntactically off the property and folds the constraints into the schema fragment, so
// these annotate without changing the stored property or its `Codable` behavior.

/// Forces the JSON Schema scalar type for a numeric property, overriding the default mapping
/// (`Int…` → `integer`, `Double`/`Float` → `number`). Use `.number` on an `Int` field whose wire
/// contract is an unconstrained JSON number.
public enum SchemaScalarKind: Sendable {
    case integer
    case number
}

/// Attaches numeric constraints (`minimum`/`maximum`/`exclusiveMinimum`/`exclusiveMaximum`/
/// `multipleOf`) and, optionally, a forced scalar `type` to a numeric property.
@attached(peer)
public macro SchemaNumber(
    minimum: Double? = nil,
    maximum: Double? = nil,
    exclusiveMinimum: Double? = nil,
    exclusiveMaximum: Double? = nil,
    multipleOf: Double? = nil,
    type: SchemaScalarKind? = nil
) = #externalMacro(module: "ADJSONMacros", type: "SchemaNumberMacro")

/// Attaches numeric bounds expressed as a Swift range — the idiomatic spelling. The bound
/// *literals* are read from source, so integers stay integers in the schema:
///
/// | Range                       | JSON Schema                          |
/// | --------------------------- | ------------------------------------ |
/// | `1...100`  (`ClosedRange`)  | `minimum: 1, maximum: 100`           |
/// | `1..<100`  (`Range`)        | `minimum: 1, exclusiveMaximum: 100`  |
/// | `1...`     (`PartialRangeFrom`)    | `minimum: 1`                  |
/// | `...100`   (`PartialRangeThrough`) | `maximum: 100`                |
/// | `..<100`   (`PartialRangeUpTo`)    | `exclusiveMaximum: 100`       |
///
/// Swift has no exclusive-lower range operator, so `exclusiveMinimum` is only available on the
/// labeled overload. `multipleOf` and `type` may still be supplied alongside the range.
@attached(peer)
public macro SchemaNumber<R: RangeExpression>(
    _ bounds: R,
    multipleOf: Double? = nil,
    type: SchemaScalarKind? = nil
) = #externalMacro(module: "ADJSONMacros", type: "SchemaNumberMacro")

/// Attaches string constraints to a `String` property. `minLength`/`maxLength`/`pattern` are
/// enforced by the validator; `format` is emitted as an annotation (JSON Schema's default).
@attached(peer)
public macro SchemaString(
    minLength: Int? = nil,
    maxLength: Int? = nil,
    pattern: String? = nil,
    format: String? = nil
) = #externalMacro(module: "ADJSONMacros", type: "SchemaStringMacro")

/// Advertises a closed set of string values for a property whose Swift type is a bare `String`.
/// For a `String`-`RawRepresentable`, `CaseIterable` enum the values are inferred from the type, so
/// this decorator is unnecessary.
@attached(peer)
public macro SchemaEnum(_ values: [String]) =
    #externalMacro(module: "ADJSONMacros", type: "SchemaEnumMacro")

/// Overrides or supplies metadata for a property. `description` takes precedence over the field's
/// `///` doc comment; `title` is passed through.
@attached(peer)
public macro SchemaInfo(description: String? = nil, title: String? = nil) =
    #externalMacro(module: "ADJSONMacros", type: "SchemaInfoMacro")
