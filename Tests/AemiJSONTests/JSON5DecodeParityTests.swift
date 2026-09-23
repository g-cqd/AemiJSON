import AemiJSON
import Foundation
import Testing

private enum JSON5Expected: Sendable {
    case string(String)
    case integer(Int)
    case integerArray([Int])
    case number(Double)
}

private struct JSON5Case: Sendable {
    let name: String
    let source: String
    let expected: JSON5Expected
    let foundationSupports: Bool

    init(name: String, source: String, expected: JSON5Expected, foundationSupports: Bool = true) {
        self.name = name
        self.source = source
        self.expected = expected
        self.foundationSupports = foundationSupports
    }
}

private let json5Cases: [JSON5Case] = [
    .init(name: "hex escape", source: #"{value:'a\x41B'}"#, expected: .string("aAB")),
    .init(name: "non-ASCII hex escape", source: #"{value:'a\xE9b'}"#, expected: .string("aéb")),
    .init(name: "Unicode escape", source: #"{value:'a\u00E9b'}"#, expected: .string("aéb")),
    .init(name: "Unicode surrogate pair", source: #"{value:'\uD83D\uDE00'}"#, expected: .string("😀")),
    .init(name: "apostrophe escape", source: #"{value:'it\'s'}"#, expected: .string("it's")),
    // Foundation preserves CR/LF continuations and rejects Unicode line continuations.
    .init(name: "LF continuation", source: "{value:'a\\\nb'}", expected: .string("ab"), foundationSupports: false),
    .init(name: "CRLF continuation", source: "{value:'a\\\r\nb'}", expected: .string("ab"), foundationSupports: false),
    .init(name: "CR continuation", source: "{value:'a\\\rb'}", expected: .string("ab"), foundationSupports: false),
    .init(
        name: "Unicode line continuation", source: "{value:'a\\\u{2028}b'}", expected: .string("ab"),
        foundationSupports: false),
    .init(
        name: "Unicode paragraph continuation", source: "{value:'a\\\u{2029}b'}", expected: .string("ab"),
        foundationSupports: false),
    // Foundation rejects these JSON5 escapes as invalid escape sequences.
    .init(name: "NUL escape", source: #"{value:'a\0b'}"#, expected: .string("a\0b"), foundationSupports: false),
    .init(
        name: "vertical tab escape", source: #"{value:'a\vb'}"#, expected: .string("a\u{0B}b"),
        foundationSupports: false),
    .init(name: "identity escape", source: #"{value:'a\qb'}"#, expected: .string("aqb"), foundationSupports: false),
    .init(
        name: "multibyte identity escape", source: "{value:'a\\éb'}", expected: .string("aéb"),
        foundationSupports: false),
    .init(name: "single-quoted string", source: "{\"value\":'text'}", expected: .string("text")),
    .init(name: "single-quoted key", source: "{'value':'text'}", expected: .string("text")),
    .init(name: "unquoted identifier key", source: "{value:\"text\"}", expected: .string("text")),
    .init(name: "escaped single-quoted key", source: #"{'val\x75e':'text'}"#, expected: .string("text")),
    .init(
        name: "continued single-quoted key", source: "{'val\\\nue':'text'}", expected: .string("text"),
        foundationSupports: false),
    .init(name: "hex integer", source: "{value:0x2A}", expected: .integer(42)),
    .init(name: "leading decimal point", source: "{value:.5}", expected: .number(0.5)),
    .init(name: "trailing decimal point", source: "{value:5.}", expected: .number(5)),
    .init(name: "plus sign", source: "{value:+5}", expected: .integer(5)),
    .init(name: "Infinity", source: "{value:Infinity}", expected: .number(.infinity)),
    .init(name: "NaN", source: "{value:NaN}", expected: .number(.nan)),
    .init(name: "line comment", source: "{// comment\nvalue:7}", expected: .integer(7)),
    .init(name: "block comment", source: "{/* comment */value:7}", expected: .integer(7)),
    .init(name: "object trailing comma", source: "{value:7,}", expected: .integer(7)),
    .init(name: "array trailing comma", source: "{value:[7,]}", expected: .integerArray([7]))
]

private struct StringValue: Decodable { let value: String }
private struct IntegerValue: Decodable { let value: Int }
private struct IntegerArrayValue: Decodable { let value: [Int] }
private struct NumberValue: Decodable { let value: Double }

@JSONCodable
private struct FastStringValue: Codable { var value: String }

private func checkString(_ expected: String, _ data: Data, _ lazy: JSON, _ name: String, _ foundationSupports: Bool)
    throws
{
    #expect(lazy.string == expected, "\(name): lazy read")
    var decoder = AemiJSON.JSONDecoder()
    decoder.allowsJSON5 = true
    #expect(try decoder.decode(StringValue.self, from: data).value == expected, "\(name): Codable")
    #expect(try decoder.decode(FastStringValue.self, from: data).value == expected, "\(name): macro Codable")
    if foundationSupports {
        let foundation = Foundation.JSONDecoder()
        foundation.allowsJSON5 = true
        #expect(try foundation.decode(StringValue.self, from: data).value == expected, "\(name): Foundation")
    }
}

private func checkInteger(_ expected: Int, _ data: Data, _ lazy: JSON, _ name: String, _ foundationSupports: Bool)
    throws
{
    #expect(lazy.int == expected, "\(name): lazy read")
    var decoder = AemiJSON.JSONDecoder()
    decoder.allowsJSON5 = true
    #expect(try decoder.decode(IntegerValue.self, from: data).value == expected, "\(name): Codable")
    if foundationSupports {
        let foundation = Foundation.JSONDecoder()
        foundation.allowsJSON5 = true
        #expect(try foundation.decode(IntegerValue.self, from: data).value == expected, "\(name): Foundation")
    }
}

private func checkIntegerArray(
    _ expected: [Int], _ data: Data, _ lazy: JSON, _ name: String, _ foundationSupports: Bool
)
    throws
{
    #expect(lazy.arrayValue.compactMap(\.int) == expected, "\(name): lazy read")
    var decoder = AemiJSON.JSONDecoder()
    decoder.allowsJSON5 = true
    #expect(try decoder.decode(IntegerArrayValue.self, from: data).value == expected, "\(name): Codable")
    if foundationSupports {
        let foundation = Foundation.JSONDecoder()
        foundation.allowsJSON5 = true
        #expect(try foundation.decode(IntegerArrayValue.self, from: data).value == expected, "\(name): Foundation")
    }
}

private func checkNumber(_ expected: Double, _ data: Data, _ lazy: JSON, _ name: String, _ foundationSupports: Bool)
    throws
{
    let lazyValue = try #require(lazy.double, "\(name): lazy read")
    var decoder = AemiJSON.JSONDecoder()
    decoder.allowsJSON5 = true
    let decoded = try decoder.decode(NumberValue.self, from: data).value
    #expect(expected.isNaN ? lazyValue.isNaN : lazyValue == expected)
    #expect(expected.isNaN ? decoded.isNaN : decoded == expected, "\(name): Codable")
    if foundationSupports {
        let foundation = Foundation.JSONDecoder()
        foundation.allowsJSON5 = true
        let foundationValue = try foundation.decode(NumberValue.self, from: data).value
        #expect(expected.isNaN ? foundationValue.isNaN : foundationValue == expected)
    }
}

@Test(arguments: json5Cases)
private func `JSON5 features decode the same through lazy and Codable paths`(testCase: JSON5Case) throws {
    let data = Data(testCase.source.utf8)
    let lazy = try AemiJSON.parse(data, options: .json5).root["value"]
    switch testCase.expected {
        case .string(let expected):
            try checkString(expected, data, lazy, testCase.name, testCase.foundationSupports)
        case .integer(let expected):
            try checkInteger(expected, data, lazy, testCase.name, testCase.foundationSupports)
        case .integerArray(let expected):
            try checkIntegerArray(expected, data, lazy, testCase.name, testCase.foundationSupports)
        case .number(let expected):
            try checkNumber(expected, data, lazy, testCase.name, testCase.foundationSupports)
    }
}
