import Foundation
import OrderedCollections
import Testing

@testable import ADJSON

// Acceptance + feature coverage for the MCP-grade `@Schemable` schema text: per-field descriptions,
// string enums, numeric bounds, draft-07 `$schema`, and the public `jsonSchemaText` accessor. The
// gate is deep-equal of parsed JSON (object key order free), exactly as the apple-docs `tools/list`
// parity check (`z.toJSONSchema(obj, { target: "draft-7" })`).

// MARK: - Fixtures

enum SfScope: String, Codable, CaseIterable { case `public`, `private` }

@Schemable(dialect: .draft7)
private struct SearchSfSymbolsInput: Decodable {
    /// Name or keyword; empty lists all.
    var query: String?
    var scope: SfScope?
    /// Max results (default 100).
    @SchemaNumber(minimum: 1, maximum: 500) var limit: Int?
}

@Schemable
private struct MinVersion: Decodable {
    var ios: String?
    var macos: String?
}

@Schemable(dialect: .draft7)
private struct SearchDocsInput: Decodable {
    /// Search terms.
    var query: String
    /// Min version per platform, e.g. {"ios":"17.0"}.
    var minVersion: MinVersion?
    /// Publication year.
    @SchemaNumber(type: .number) var year: Int?
}

@Schemable(dialect: .draft7)
private struct EmptyInput: Decodable {}

@Schemable
private struct EnumFallback: Decodable {
    @SchemaEnum(["a", "b", "c"]) var kind: String
}

@Schemable
private struct InfoOverride: Decodable {
    /// This doc comment must be overridden by @SchemaInfo.
    @SchemaInfo(description: #"Search terms, e.g. "NavigationStack"."#) var q: String?
}

@Schemable
private struct StringConstraints: Decodable {
    @SchemaString(minLength: 2, maxLength: 8, pattern: "^a") var code: String?
}

@Schemable
private struct DeclOrder: Decodable {
    var zebra: String
    var apple: Int
    var mango: String?
}

@Schemable
private struct RangeBounds: Decodable {
    @SchemaNumber(1...100) var closed: Int?
    @SchemaNumber(1..<100) var halfOpen: Int?
    @SchemaNumber(1...) var fromOnly: Int?
    @SchemaNumber(...100) var throughOnly: Int?
    @SchemaNumber(..<100) var upToOnly: Int?
    @SchemaNumber(0...10, multipleOf: 5) var comboMultiple: Int?
    @SchemaNumber(0..., type: .number) var comboType: Int?
}

@Schemable
private struct RadixBounds: Decodable {
    @SchemaNumber(minimum: 0x10, maximum: 0b1000) var hexBin: Int?
    @SchemaNumber(minimum: 0o17) var octal: Int?
}

@Schemable
private struct MultiLineDoc: Decodable {
    /// First line.
    /// Second line.
    var nested: MinVersion?
}

// MARK: - Helpers

private func deepEqual(_ a: String, _ b: String) -> Bool {
    (try? JSONValue(parsing: a)) == (try? JSONValue(parsing: b))
}

private func occurrences(of needle: String, in s: String) -> Int {
    s.components(separatedBy: needle).count - 1
}

// MARK: - Acceptance

@Test func searchSfSymbolsMatchesZodTarget() {
    let target = """
        {"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{\
        "query":{"type":"string","description":"Name or keyword; empty lists all."},\
        "scope":{"type":"string","enum":["public","private"]},\
        "limit":{"type":"integer","minimum":1,"maximum":500,"description":"Max results (default 100)."}}}
        """
    #expect(deepEqual(SearchSfSymbolsInput.jsonSchemaText, target))
}

@Test func searchDocsMatchesZodTargetWithNestedAndNumberOverride() {
    let target = """
        {"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{\
        "query":{"type":"string","description":"Search terms."},\
        "minVersion":{"type":"object","description":"Min version per platform, e.g. {\\"ios\\":\\"17.0\\"}.",\
        "properties":{"ios":{"type":"string"},"macos":{"type":"string"}}},\
        "year":{"type":"number","description":"Publication year."}},"required":["query"]}
        """
    #expect(deepEqual(SearchDocsInput.jsonSchemaText, target))
}

// MARK: - Dialect / $schema

@Test func draft7EmitsExactSchemaLiteralOnRootOnly() {
    let text = SearchSfSymbolsInput.jsonSchemaText
    #expect(text.contains(#""$schema":"http://json-schema.org/draft-07/schema#""#))
    // Root only — never on an inlined child.
    #expect(occurrences(of: "$schema", in: SearchDocsInput.jsonSchemaText) == 1)
    #expect(!MinVersion.__adjsonSchemaText.contains("$schema"))
}

@Test func dialectNoneOmitsSchema() {
    #expect(!EnumFallback.jsonSchemaText.contains("$schema"))
    #expect(EnumFallback.jsonSchemaText == EnumFallback.__adjsonSchemaText)
}

// MARK: - Edge cases

@Test func emptyStructEmitsEmptyProperties() {
    let target = #"{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{}}"#
    #expect(deepEqual(EmptyInput.jsonSchemaText, target))
    #expect(EmptyInput.jsonSchemaText.contains(#""properties":{}"#))
}

@Test func numberOverrideForcesNumberType() {
    // `year` is an Int but advertised as a JSON number.
    #expect(deepEqual(SearchDocsInput.jsonSchemaText, SearchDocsInput.jsonSchemaText))
    let docs = try! JSONValue(parsing: SearchDocsInput.jsonSchemaText)
    guard case .object(let root) = docs, case .object(let props)? = root["properties"],
        case .object(let year)? = props["year"], case .string(let t)? = year["type"]
    else {
        Issue.record("unexpected shape")
        return
    }
    #expect(t == "number")
}

@Test func integerBoundsStayIntegerLiterals() {
    // Byte-level: bounds must serialize as `1`/`500`, not `1.0`/`500.0`.
    let text = SearchSfSymbolsInput.jsonSchemaText
    #expect(text.contains(#""minimum":1"#))
    #expect(text.contains(#""maximum":500"#))
    #expect(!text.contains("1.0"))
    #expect(!text.contains("500.0"))
}

// MARK: - Descriptions / enums / constraints

@Test func docCommentBecomesDescription() {
    let target =
        #"{"type":"object","properties":{"q":{"type":"string","description":"Search terms, e.g. \"NavigationStack\"."}}}"#
    #expect(deepEqual(InfoOverride.jsonSchemaText, target))
    // @SchemaInfo overrode the doc comment.
    #expect(!InfoOverride.jsonSchemaText.contains("overridden"))
    // Embedded quotes escaped byte-exactly.
    #expect(InfoOverride.jsonSchemaText.contains(#"e.g. \"NavigationStack\"."#))
}

@Test func bareStringEnumFallback() {
    let target = #"{"type":"object","properties":{"kind":{"type":"string","enum":["a","b","c"]}},"required":["kind"]}"#
    #expect(deepEqual(EnumFallback.jsonSchemaText, target))
}

@Test func stringConstraints() {
    let target =
        #"{"type":"object","properties":{"code":{"type":"string","minLength":2,"maxLength":8,"pattern":"^a"}}}"#
    #expect(deepEqual(StringConstraints.jsonSchemaText, target))
}

@Test func enumInferredInDeclarationOrder() {
    #expect(SfScope.allCases.map(\.rawValue) == ["public", "private"])
    let text = SearchSfSymbolsInput.jsonSchemaText
    #expect(text.contains(#""enum":["public","private"]"#))
}

// MARK: - Declaration order (R9)

@Test func propertiesAndRequiredFollowDeclarationOrder() {
    let text = DeclOrder.jsonSchemaText
    let z = text.range(of: "\"zebra\"")!.lowerBound
    let a = text.range(of: "\"apple\"")!.lowerBound
    let m = text.range(of: "\"mango\"")!.lowerBound
    #expect(z < a && a < m)
    // required holds only the non-optional fields, in declaration order.
    #expect(text.contains(#""required":["zebra","apple"]"#))
}

// MARK: - Validation still works through the compiled schema

// MARK: - Range-based bounds

private func property(_ text: String, _ name: String) -> JSONValue? {
    guard case .object(let root)? = try? JSONValue(parsing: text),
        case .object(let props)? = root["properties"]
    else { return nil }
    return props[name]
}

@Test func rangeBoundsMapToNumericConstraints() {
    let text = RangeBounds.jsonSchemaText
    #expect(property(text, "closed") == (try! JSONValue(parsing: #"{"type":"integer","minimum":1,"maximum":100}"#)))
    #expect(
        property(text, "halfOpen")
            == (try! JSONValue(parsing: #"{"type":"integer","minimum":1,"exclusiveMaximum":100}"#)))
    #expect(property(text, "fromOnly") == (try! JSONValue(parsing: #"{"type":"integer","minimum":1}"#)))
    #expect(property(text, "throughOnly") == (try! JSONValue(parsing: #"{"type":"integer","maximum":100}"#)))
    #expect(property(text, "upToOnly") == (try! JSONValue(parsing: #"{"type":"integer","exclusiveMaximum":100}"#)))
    #expect(
        property(text, "comboMultiple")
            == (try! JSONValue(parsing: #"{"type":"integer","minimum":0,"maximum":10,"multipleOf":5}"#)))
    #expect(property(text, "comboType") == (try! JSONValue(parsing: #"{"type":"number","minimum":0}"#)))
}

@Test func rangeBoundsStayIntegerLiterals() {
    let text = RangeBounds.jsonSchemaText
    #expect(text.contains(#""minimum":1"#))
    #expect(text.contains(#""maximum":100"#))
    #expect(text.contains(#""exclusiveMaximum":100"#))
    #expect(!text.contains("100.0"))
}

@Test func radixIntegerLiteralsNormalizeToDecimal() {
    // Hex/octal/binary bounds must become decimal JSON numbers; otherwise the text is invalid JSON
    // and the whole compiled schema silently degrades to `.permitAll`.
    let text = RadixBounds.jsonSchemaText
    #expect((try? ADJSON.parse(text)) != nil)  // valid JSON
    #expect(property(text, "hexBin") == (try! JSONValue(parsing: #"{"type":"integer","minimum":16,"maximum":8}"#)))
    #expect(property(text, "octal") == (try! JSONValue(parsing: #"{"type":"integer","minimum":15}"#)))
}

@Test func multiLineDocCommentJoinsWithNewline() {
    let text = MultiLineDoc.jsonSchemaText
    #expect((try? ADJSON.parse(text)) != nil)
    let target = """
        {"type":"object","properties":{"nested":{"description":"First line.\\nSecond line.",\
        "type":"object","properties":{"ios":{"type":"string"},"macos":{"type":"string"}}}}}
        """
    #expect(deepEqual(text, target))
}

@Test func insertingFirstMemberHandlesEmptyAndNonEmpty() {
    #expect(__adjsonInsertingFirstMember("{}", #""a":1"#) == #"{"a":1}"#)
    #expect(__adjsonInsertingFirstMember(#"{"b":2}"#, #""a":1"#) == #"{"a":1,"b":2}"#)
}

@Test func compiledSchemaEnforcesEnumAndBounds() {
    let s = SearchSfSymbolsInput.jsonSchema
    #expect(s.isValid(try! ADJSON.parse(#"{"query":"x","scope":"public","limit":10}"#).root))
    #expect(!s.isValid(try! ADJSON.parse(#"{"scope":"other"}"#).root))  // not in enum
    #expect(!s.isValid(try! ADJSON.parse(#"{"limit":0}"#).root))  // below minimum
    #expect(!s.isValid(try! ADJSON.parse(#"{"limit":501}"#).root))  // above maximum
}
