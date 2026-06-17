import ADJSONCore

/// A compiled JSON Schema regular expression. The pattern is restricted to the RFC 9485 I-Regexp safe
/// subset (which JSON Schema also recommends) and compiled to the standard-library `Regex`, so an
/// attacker-supplied schema `pattern` cannot trigger catastrophic backtracking (ReDoS) and no ICU /
/// `NSRegularExpression` is involved. An unsafe or malformed pattern fails to compile (`init?` returns
/// nil) and that constraint is simply not enforced.
///
/// `@unchecked Sendable`: a `Regex` is immutable once compiled and matching never mutates it, so
/// concurrent read-only matching from the `Sendable` `SchemaNode` is safe — the same contract the
/// JSONPath `CompiledRegex` relies on.
struct SchemaPattern: @unchecked Sendable {
    let regex: Regex<AnyRegexOutput>

    init?(_ pattern: String) {
        guard IRegexp.rejectionReason(pattern) == nil, let compiled = try? Regex(IRegexp.toSwift(pattern))
        else { return nil }
        regex = compiled
    }

    /// JSON Schema `pattern` matches when the expression is found anywhere in the string (ECMA-262
    /// `RegExp.prototype.test` semantics) — an unanchored search.
    func matches(_ s: String) -> Bool { (try? regex.firstMatch(in: s)) != nil }
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
    var pattern: SchemaPattern?

    var minItems: Int?
    var maxItems: Int?
    var uniqueItems = false

    var minProperties: Int?
    var maxProperties: Int?
    var required: [String]?

    var properties: [String: Int]?
    var patternProperties: [(SchemaPattern, Int)]?
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
