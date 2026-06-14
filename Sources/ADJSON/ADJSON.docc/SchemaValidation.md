# Schema Validation

Validate, infer, and describe JSON with a JSON Schema (Draft 2020-12) subset.

## Compile once, validate many

A ``JSONSchema`` compiles its source into a flat, value-type node table and is `Sendable`, so
one compiled schema can validate concurrently across tasks. Validation runs against the lazy
``JSON`` value with no instance materialization.

```swift
let schema = try JSONSchema(parsing: schemaText)

let result = schema.validate(data)        // ValidationResult
if !result.isValid {
    for e in result.errors {              // each ValidationError is located by JSON Pointer
        print("\(e.instanceLocation): \(e.message)")
    }
}

// Or a quick boolean against a lazy view:
let ok = schema.isValid(doc.root)
```

## Supported keywords

`type`, `enum`, `const`; numeric bounds (`minimum`/`maximum`/`exclusive*`, `multipleOf`);
string `minLength`/`maxLength`/`pattern`; `items`/`prefixItems`/`contains` (with
`minContains`/`maxContains`); array/object size; `required`, `properties`,
`patternProperties`, `additionalProperties`; `dependentRequired`/`dependentSchemas`;
`allOf`/`anyOf`/`oneOf`/`not`; `if`/`then`/`else`; and local `$ref`/`$defs` (with cycle
detection).

Not yet implemented: `$dynamicRef`/`$dynamicAnchor`, `unevaluated*`, `$anchor`, remote
`$ref`, `$id` base-URI resolution, `propertyNames`, and format-assertion. The
``JSONSchema`` symbol documentation lists the current set.

> Note: numbers are compared as `Double`, so bounds near or beyond 2^53 are subject to
> floating-point precision.

## Generating a schema from a type with `@Schemable`

Attach ``Schemable(dialect:)`` to a `struct` to generate its JSON Schema at compile time — no
instance and no reflection. The type gains ``ADJSONSchemaProviding/jsonSchema`` (a compiled
``JSONSchema``) and ``ADJSONSchemaProviding/jsonSchemaText`` (the schema as a JSON document, ready to
embed elsewhere — e.g. an MCP `tools/list` payload).

```swift
@Schemable(dialect: .draft7)
struct SearchInput: Decodable {
    /// Name or keyword; empty lists all.        ← becomes "description"
    var query: String?
    var scope: Scope?                            // String enum → "enum":["public","private"]
    @SchemaNumber(1...500) var limit: Int?       // → "minimum":1,"maximum":500
}

enum Scope: String, Codable, CaseIterable { case `public`, `private` }

let text = SearchInput.jsonSchemaText            // draft-07 JSON document
let ok = SearchInput.jsonSchema.isValid(doc.root)
```

The schema is built from two layers — **inference** (the Swift type maps to a JSON type; a `///` doc
comment becomes a `description`; a `String` & `CaseIterable` enum becomes a string `enum`) and
**property decorators** for anything the type can't express:

| Decorator | Adds |
| --- | --- |
| ``SchemaNumber(minimum:maximum:exclusiveMinimum:exclusiveMaximum:multipleOf:type:)`` | numeric bounds; `type:` forces `integer`/`number` |
| ``SchemaNumber(_:multipleOf:type:)`` | bounds from a range: `1...100`, `1..<100`, `1...`, `...100`, `..<100` |
| ``SchemaString(minLength:maxLength:pattern:format:)`` | string constraints |
| ``SchemaEnum(_:)`` | a closed string set for a bare `String` |
| ``SchemaInfo(description:title:)`` | a `description` (overriding the doc comment) and `title` |

Ranges are the idiomatic spelling for bounds: `ClosedRange` → `minimum`/`maximum`, `Range` →
`minimum`/`exclusiveMaximum`, and the partial ranges map to a single bound. Swift has no
exclusive-lower range operator, so `exclusiveMinimum` is only on the labeled overload.

The dialect's `$schema` is emitted on the **root only** — nested `@Schemable` types are inlined
without it. The default, ``SchemaDialect/none``, omits `$schema` entirely. Nested custom types must
also be `@Schemable`; types with custom `CodingKeys`, and directly self-referential types, are left
undescribed (a warning is emitted).

## Inferring a schema from samples

Generate schema text from one or more instances. `required` is the set of keys present in
every object sample; array element shapes are merged; `integer` widens to `number` if any
non-integral value is seen.

```swift
let schemaText = JSONSchema.infer(from: samples)            // [JSON] -> String
let schemaText = try JSONSchema.infer(fromJSONTexts: blobs) // [String] -> String
let compiled   = try JSONSchema.inferred(from: samples)     // -> JSONSchema
```

## Describing a Swift value

Generate schema text from a Swift value via reflection — optional properties become
non-required; nested structs and arrays recurse.

```swift
let schemaText = JSONSchema.describe(myModel)
```

The rendered schema reuses the library's canonical string escaper, so its text escapes
identically to everything else ADJSON emits.
