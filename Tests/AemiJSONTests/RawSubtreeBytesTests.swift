import Foundation
import Testing

@testable import AemiJSON

private let spanOptions: JSONParseOptions = {
    var options = JSONParseOptions.strict
    options.recordsContainerSpans = true
    return options
}()

private func rawText(_ node: JSON) -> String? {
    node.withRawJSONBytes { String(decoding: $0, as: UTF8.self) }
}

@Test func rawSubtreeBytesReturnsUntouchedContainerText() throws {
    let source = #"{"id": 7, "result": {"contents": {"kind":"markdown", "value":"a\nb"},  "range": [1, 2]}}"#
    let doc = try AemiJSON.parse(Array(source.utf8), options: spanOptions)
    #expect(rawText(doc.root["result"]) == #"{"contents": {"kind":"markdown", "value":"a\nb"},  "range": [1, 2]}"#)
    #expect(rawText(doc.root["result"]["range"]) == "[1, 2]")
    #expect(rawText(doc.root) == source)
}

@Test func rawSubtreeBytesCoversScalarsIncludingEscapesAndQuotes() throws {
    let source = #"{"s": "aé\"b", "n": -12.5e2, "t": true, "z": null}"#
    let doc = try AemiJSON.parse(Array(source.utf8), options: spanOptions)
    #expect(rawText(doc.root["s"]) == #""aé\"b""#)  // raw text: escapes intact, quotes included
    #expect(rawText(doc.root["n"]) == "-12.5e2")
    #expect(rawText(doc.root["t"]) == "true")
    #expect(rawText(doc.root["z"]) == "null")
}

@Test func rawSubtreeBytesHandlesEmptyAndNestedContainers() throws {
    let source = "[[], {} , [ {\"k\": []} ]]"
    let doc = try AemiJSON.parse(Array(source.utf8), options: spanOptions)
    #expect(rawText(doc.root) == source)
    #expect(rawText(doc.root[index: 0]) == "[]")
    #expect(rawText(doc.root[index: 1]) == "{}")
    #expect(rawText(doc.root[index: 2]) == "[ {\"k\": []} ]")
    #expect(rawText(doc.root[index: 2][index: 0]["k"]) == "[]")
}

@Test func rawSubtreeBytesReturnsNilForMissingNodesAndUnrecordedContainers() throws {
    let source = #"{"a": [1]}"#
    let recorded = try AemiJSON.parse(Array(source.utf8), options: spanOptions)
    #expect(rawText(recorded.root["missing"]) == nil)

    // Default options: containers unrecorded (nil), scalars still available.
    let unrecorded = try AemiJSON.parse(Array(source.utf8))
    #expect(rawText(unrecorded.root["a"]) == nil)
    #expect(rawText(unrecorded.root["a"][index: 0]) == "1")
}

@Test func rawSubtreeBytesRoundTripsThroughATypedDecode() throws {
    struct Inner: Codable, Equatable {
        let kind: String
        let value: Int
    }
    let source = #"{"jsonrpc":"2.0","id":3,"result":{"kind":"x","value":42}}"#
    let doc = try AemiJSON.parse(Array(source.utf8), options: spanOptions)
    let raw = doc.root["result"].withRawJSONBytes { [UInt8]($0) }
    let decoded = try #require(raw.map { try AemiJSON.JSONDecoder().decode(Inner.self, from: Data($0)) })
    #expect(decoded == Inner(kind: "x", value: 42))
}
