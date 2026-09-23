import AemiJSON
import Foundation
import Testing

// Every parse entry point — `[UInt8]`, `String`, `Data`, a `ByteSource` read in place, and a borrowed
// raw buffer — must accept the same inputs: a leading UTF-8 byte-order mark, which Foundation's
// decoder accepts, and `assumesTopLevelDictionary`, which the in-place entry points used to ignore.

private let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

private func parseInPlace<Source: ByteSource & Sendable>(
    _ source: Source, options: JSONParseOptions
) throws -> JSONDocument {
    try AemiJSON.parse(source, options: options)
}

/// Parses `bytes` through each entry point and returns the materialized roots, in the order
/// `[UInt8]`, `String`, `Data`, in-place `Data`, borrowed raw buffer.
private func parseEverywhere(_ bytes: [UInt8], options: JSONParseOptions = .strict) throws -> [JSONValue] {
    let data = Data(bytes)
    let viaRawBuffer = try bytes.withUnsafeBytes { raw in JSONValue(try AemiJSON.parse(raw, options: options).root) }
    return [
        JSONValue(try AemiJSON.parse(bytes, options: options).root),
        JSONValue(try AemiJSON.parse(String(decoding: bytes, as: UTF8.self), options: options).root),
        JSONValue(try AemiJSON.parse(data, options: options).root),
        JSONValue(try parseInPlace(data, options: options).root),
        viaRawBuffer
    ]
}

struct ParseEntryPointTests {
    // Before, every entry point threw `unexpectedCharacter(239, at: 0)` on the mark.
    @Test func everyEntryPointSkipsALeadingByteOrderMark() throws {
        let roots = try parseEverywhere(byteOrderMark + Array(#"{"a":[1,"é"]}"#.utf8))
        #expect(roots == Array(repeating: JSONValue.object(["a": .array([.int(1), .string("é")])]), count: 5))
    }

    @Test func theDecoderAcceptsALeadingByteOrderMarkLikeFoundation() throws {
        struct Payload: Codable, Equatable { let a: Int }
        let data = Data(byteOrderMark + Array(#"{"a":1}"#.utf8))
        #expect(try Foundation.JSONDecoder().decode(Payload.self, from: data) == Payload(a: 1))
        #expect(try AemiJSON.JSONDecoder().decode(Payload.self, from: data) == Payload(a: 1))
    }

    @Test func onlyALeadingCompleteByteOrderMarkIsSkipped() {
        #expect(throws: JSONError.unexpectedEndOfInput) { try AemiJSON.parse(byteOrderMark) }
        #expect(throws: JSONError.self) { try AemiJSON.parse([0xEF, 0xBB] + Array("{}".utf8)) }
        #expect(throws: JSONError.self) { try AemiJSON.parse(Array(" ".utf8) + byteOrderMark + Array("{}".utf8)) }
        #expect(throws: JSONError.self) { try AemiJSON.parse(byteOrderMark + byteOrderMark + Array("{}".utf8)) }
    }

    @Test func offsetsStayRelativeToTheBufferAfterAByteOrderMark() throws {
        let bytes = byteOrderMark + Array(#"{"k":[1, 2]}"#.utf8)
        let document = try AemiJSON.parse(bytes, options: JSONParseOptions(recordsContainerSpans: true))
        #expect(document.root["k"].withRawJSONBytes { String(decoding: $0, as: UTF8.self) } == "[1, 2]")
        #expect(throws: JSONError.trailingData(at: 6)) { try AemiJSON.parse(byteOrderMark + Array("{} x".utf8)) }
    }

    // Before, the in-place and raw-buffer entry points ignored the option and threw `trailingData(at: 3)`.
    @Test func everyEntryPointHonorsAssumesTopLevelDictionary() throws {
        let options = JSONParseOptions(assumesTopLevelDictionary: true)
        let expected = JSONValue.object(["a": .int(1), "b": .bool(true)])
        #expect(
            try parseEverywhere(Array(#""a":1,"b":true"#.utf8), options: options)
                == Array(repeating: expected, count: 5))
        // An already-braced input is parsed as is, and the mark is stripped before any wrapping.
        #expect(
            try parseEverywhere(Array(#"{"a":1,"b":true}"#.utf8), options: options)
                == Array(repeating: expected, count: 5))
        #expect(
            try parseEverywhere(byteOrderMark + Array(#""a":1,"b":true"#.utf8), options: options)
                == Array(repeating: expected, count: 5))
        #expect(
            try parseEverywhere(byteOrderMark + Array(#" {"a":1,"b":true}"#.utf8), options: options)
                == Array(repeating: expected, count: 5))
    }
}
