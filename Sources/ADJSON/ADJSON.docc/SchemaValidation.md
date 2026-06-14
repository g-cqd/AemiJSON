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
