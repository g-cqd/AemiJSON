import Foundation

/// A single validation failure, located by JSON Pointer into the instance.
public struct ValidationError: Sendable, Equatable {
    public let instanceLocation: String
    public let message: String
}

public struct ValidationResult: Sendable {
    public let isValid: Bool
    public let errors: [ValidationError]
}

/// A compiled JSON Schema (Draft 2020-12 subset). Compiled once into a flat,
/// value-type node table; `Sendable`, so one schema validates concurrently.
/// Validation runs against the lazy `JSON` value with no instance materialization.
///
/// Supported: type, enum, const, numeric bounds, multipleOf, string length/pattern,
/// items/prefixItems/contains, array/object size, required, properties,
/// patternProperties, additionalProperties, dependentRequired/Schemas,
/// allOf/anyOf/oneOf/not, if/then/else, and local `$ref`/`$defs`.
/// Not yet: `$dynamicRef`/`$dynamicAnchor`, `unevaluated*`, `$anchor`, remote `$ref`,
/// `$id` base-URI resolution, `propertyNames`, format-assertion.
public struct JSONSchema: Sendable {
    let nodes: [SchemaNode]
    let rootIndex: Int
    let registry: [String: Int]
    let document: JSONDocument

    public init(_ schema: JSON) {
        let compiler = SchemaCompiler()
        self.rootIndex = compiler.compile(schema, at: "")
        self.nodes = compiler.nodes
        self.registry = compiler.registry
        self.document = schema.doc
    }

    public init(_ data: Data) throws {
        self.init(try ADJSON.parse(data).root)
    }

    public init(parsing string: String) throws {
        self.init(try ADJSON.parse(string).root)
    }

    public func validate(_ instance: JSON) -> ValidationResult {
        var errors = [ValidationError]()
        let validator = SchemaValidator(nodes: nodes, registry: registry)
        _ = validator.validate(rootIndex, instance, "", &errors)
        return ValidationResult(isValid: errors.isEmpty, errors: errors)
    }

    public func validate(_ data: Data) throws -> ValidationResult {
        validate(try ADJSON.parse(data).root)
    }

    public func isValid(_ instance: JSON) -> Bool {
        validate(instance).isValid
    }
}
