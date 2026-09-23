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

/// Every node of `root`, visited with an explicit stack.
private func allNodes(_ root: JSON) -> [JSON] {
    var nodes: [JSON] = []
    var pending = [root]
    while let node = pending.popLast() {
        nodes.append(node)
        node.forEachElement { pending.append($0) }
        node.forEachMember { _, value in pending.append(value) }
    }
    return nodes
}

// Every container's recorded span, looked up among many, holds exactly that container's text: the
// text parses back to the same value. JSON5 adds comments and trailing commas inside the spans.
@Test(arguments: [false, true])
func rawSubtreeBytesOfEveryContainerParseBackToTheSameValue(json5: Bool) throws {
    var parts: [String] = []
    for k in 0 ..< 60 {
        let members =
            json5
            ? #"{"id":\#(k), /* c */ "tags":[\#(k), [], {},], "o":{"n":{"k":[1,2,],},},}"#
            : #"{"id":\#(k),"tags":[\#(k),[],{}],"o":{"n":{"k":[1,2]}}}"#
        parts.append(members)
    }
    let text = "[" + parts.joined(separator: ",") + "]"
    var options: JSONParseOptions = json5 ? .json5 : .strict
    options.recordsContainerSpans = true
    let document = try AemiJSON.parse(text, options: options)
    var containers = 0
    for node in allNodes(document.root) where node.isObject || node.isArray {
        containers += 1
        let raw = try #require(node.withRawJSONBytes { [UInt8]($0) })
        #expect(try JSONValue(AemiJSON.parse(raw, options: json5 ? .json5 : .strict).root) == JSONValue(node))
    }
    #expect(containers == 1 + 60 * 7)  // the root, then seven per element
}
