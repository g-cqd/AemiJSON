import Foundation

/// Thread-safe wrapper around `NSRegularExpression` (immutable + safe for concurrent
/// matching). This is the only `@unchecked` in the schema layer.
struct SendableRegex: @unchecked Sendable {
    let regex: NSRegularExpression

    init?(_ pattern: String) {
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        regex = r
    }

    func matches(_ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

/// A compiled schema node. A value type: recursion is expressed as `Int` indices
/// into the schema's flat node table (like the JSON tape), so no inline self-storage
/// and no reference semantics. All fields are `Sendable`, so the node is `Sendable`.
struct SchemaNode: Sendable {
    var boolean: Bool?

    var types: [SchemaType]?
    var constValue: JSON?
    var enumValues: [JSON]?

    var minimum: Double?
    var maximum: Double?
    var exclusiveMinimum: Double?
    var exclusiveMaximum: Double?
    var multipleOf: Double?

    var minLength: Int?
    var maxLength: Int?
    var pattern: SendableRegex?

    var minItems: Int?
    var maxItems: Int?
    var uniqueItems = false

    var minProperties: Int?
    var maxProperties: Int?
    var required: [String]?

    var properties: [String: Int]?
    var patternProperties: [(SendableRegex, Int)]?
    var additionalProperties: Int?

    var prefixItems: [Int]?
    var items: Int?
    var contains: Int?
    var minContains: Int?
    var maxContains: Int?

    var allOf: [Int]?
    var anyOf: [Int]?
    var oneOf: [Int]?
    var not: Int?

    var ifSchema: Int?
    var thenSchema: Int?
    var elseSchema: Int?

    var dependentRequired: [String: [String]]?
    var dependentSchemas: [String: Int]?

    var ref: String?
}
