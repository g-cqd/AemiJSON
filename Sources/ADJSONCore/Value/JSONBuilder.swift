import OrderedCollections

// Ergonomic construction for `JSONValue` trees. Two complementary spellings:
//
//   • Literals (`ExpressibleBy*Literal`) for the terse, static shape — `["id": 42, "tags": ["a"]]`.
//   • Result builders (`JSONValue.makeObject`/`makeArray`) for construction that needs control flow —
//     `if`, `for`, `switch` — which a literal cannot express.
//
// Both are additive: existing case construction (`.object(...)`, `.array(...)`) is unchanged. The
// builders are iterative (a flat fold of components), so no nesting depth can overflow the stack.

// MARK: - Literal conformances

extension JSONValue: ExpressibleByNilLiteral {
    /// `nil` denotes JSON `null`.
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    /// An integer literal is held losslessly as ``int(_:)`` (see the `JSONValue` precision note).
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    /// Order is preserved as written; a repeated key keeps its first position and takes the last value
    /// (matching the engine's default `.useLast` duplicate-key policy).
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var members = OrderedDictionary<String, JSONValue>(minimumCapacity: elements.count)
        for (key, value) in elements { members[key] = value }
        self = .object(members)
    }
}

// MARK: - Result builders

/// Builds the elements of a JSON array, allowing `if` / `for` / `switch` between elements. Each
/// statement is a ``JSONValue`` (scalars come for free via the literal conformances above).
@resultBuilder
public enum JSONArrayBuilder {
    public static func buildExpression(_ value: JSONValue) -> [JSONValue] { [value] }
    public static func buildBlock(_ parts: [JSONValue]...) -> [JSONValue] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [JSONValue]?) -> [JSONValue] { part ?? [] }
    public static func buildEither(first part: [JSONValue]) -> [JSONValue] { part }
    public static func buildEither(second part: [JSONValue]) -> [JSONValue] { part }
    public static func buildArray(_ parts: [[JSONValue]]) -> [JSONValue] { parts.flatMap { $0 } }
    public static func buildLimitedAvailability(_ part: [JSONValue]) -> [JSONValue] { part }
}

/// Builds the members of a JSON object, allowing `if` / `for` / `switch` between members. Each
/// statement is a `(String, JSONValue)` pair, e.g. `("id", 42)`.
@resultBuilder
public enum JSONObjectBuilder {
    public static func buildExpression(_ member: (String, JSONValue)) -> [(String, JSONValue)] { [member] }
    public static func buildBlock(_ parts: [(String, JSONValue)]...) -> [(String, JSONValue)] {
        parts.flatMap { $0 }
    }
    public static func buildOptional(_ part: [(String, JSONValue)]?) -> [(String, JSONValue)] { part ?? [] }
    public static func buildEither(first part: [(String, JSONValue)]) -> [(String, JSONValue)] { part }
    public static func buildEither(second part: [(String, JSONValue)]) -> [(String, JSONValue)] { part }
    public static func buildArray(_ parts: [[(String, JSONValue)]]) -> [(String, JSONValue)] { parts.flatMap { $0 } }
    public static func buildLimitedAvailability(_ part: [(String, JSONValue)]) -> [(String, JSONValue)] { part }
}

extension JSONValue {
    /// Build a JSON array from a result-builder body — use when construction needs control flow that a
    /// `[…]` literal cannot express:
    /// ```swift
    /// let tags = JSONValue.makeArray {
    ///     "swift"
    ///     for extra in extras { JSONValue.string(extra) }
    ///     if verbose { "debug" }
    /// }
    /// ```
    public static func makeArray(@JSONArrayBuilder _ build: () -> [JSONValue]) -> JSONValue {
        .array(build())
    }

    /// Build a JSON object from a result-builder body — use when construction needs control flow:
    /// ```swift
    /// let user = JSONValue.makeObject {
    ///     ("id", 42)
    ///     ("name", "Ada")
    ///     ("tags", .makeArray { "swift"; "json" })
    ///     if let email { ("email", JSONValue.string(email)) }
    /// }
    /// ```
    /// Member order follows the body; a repeated key keeps its first position and takes the last value
    /// (the engine's default `.useLast` policy).
    public static func makeObject(@JSONObjectBuilder _ build: () -> [(String, JSONValue)]) -> JSONValue {
        let members = build()
        var object = OrderedDictionary<String, JSONValue>(minimumCapacity: members.count)
        for (key, value) in members { object[key] = value }
        return .object(object)
    }
}
