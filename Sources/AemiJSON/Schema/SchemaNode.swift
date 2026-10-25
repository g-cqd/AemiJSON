import AemiJSONCore
import AemiRegex

/// A compiled JSON Schema regular expression: an ECMA-262 pattern with the `u` flag (what Ajv compiles `pattern` to), run by AemiRegex's
/// budgeted backtracker. A catastrophic pattern cannot hang validation: the search runs out of budget and `test` says so. A malformed
/// pattern fails to compile (`init?` returns nil) and that constraint is simply not enforced.
///
/// A value type: a `BacktrackingPattern` is immutable and `Sendable`, so the `Sendable` `SchemaNode` can hold it.
struct SchemaPattern: Sendable {
    private let pattern: BacktrackingPattern

    /// What one match may cost: about a thirtieth of a second in the worst case. Validation runs once per string, so the default budget
    /// (a third of a second) would let a hostile instance cost far more than a hostile schema ever could.
    private static let budget = BacktrackingPattern.Budget(maxSteps: 1_000_000, maxStackEntries: 100_000)

    init?(_ pattern: String) {
        guard let compiled = try? BacktrackingPattern(pattern, dialect: .ecmaScript, budget: Self.budget) else {
            return nil
        }
        self.pattern = compiled
    }

    /// Whether the expression is found anywhere in `s` (ECMA-262 `RegExp.prototype.test`, an unanchored search).
    /// - Returns: `nil` when the match ran out of its budget, so the answer is not known.
    func test(_ s: String) -> Bool? { try? pattern.isMatch(in: s) }

    /// The answer when the budget ran out: not matched. A validator fails closed, so an input built to exhaust the budget is refused.
    func matches(_ s: String) -> Bool { test(s) ?? false }
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
