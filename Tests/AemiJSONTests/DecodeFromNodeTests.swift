import AemiJSON
import Foundation
import Testing

// `AemiJSON.JSONDecoder.decode(_:from: JSON)` decodes one node of a parsed document, such as the
// `result` of a JSON-RPC envelope, from the tape the parse already built: no re-encoding of the node
// and no second parse.

private struct Position: Codable, Equatable {
    let line: Int
    let character: Int
}

private struct Hover: Codable, Equatable {
    let contents: String
    let range: [Position]?
}

@JSONCodable
private struct FastHover: Codable, Equatable {
    var contents: String
    var line: Int
}

/// Reads the tag the decoder's `userInfo` carries, to show the decoder's configuration reaches the node.
private struct Tagged: Decodable, Equatable {
    let value: Int
    let tag: String?
    init(value: Int, tag: String?) {
        self.value = value
        self.tag = tag
    }
    init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(Int.self)
        tag = CodingUserInfoKey(rawValue: "tag").flatMap { decoder.userInfo[$0] as? String }
    }
}

private let envelope = #"""
    {"jsonrpc":"2.0","id":7,"result":{"contents":"a \"quoted\"\nline","range":[{"line":1,"character":2}]},
     "meta":{"created_at":"2026-09-23T10:00:00Z","nested_value":{"deep_key":5}},"nothing":null,"n":3}
    """#

struct DecodeFromNodeTests {
    @Test func decodesAMemberOfAnEnvelopeLikeItsOwnBytes() throws {
        let document = try AemiJSON.parse(envelope)
        let node = document.root["result"]
        let decoder = AemiJSON.JSONDecoder()
        let fromNode = try decoder.decode(Hover.self, from: node)
        let raw = try #require(
            try AemiJSON.parse(envelope, options: JSONParseOptions(recordsContainerSpans: true)).root["result"]
                .withRawJSONBytes { Data($0) })
        #expect(fromNode == (try decoder.decode(Hover.self, from: raw)))
        #expect(fromNode == Hover(contents: "a \"quoted\"\nline", range: [Position(line: 1, character: 2)]))
        #expect(try decoder.decode(Position.self, from: node["range"][index: 0]) == Position(line: 1, character: 2))
        #expect(try decoder.decode(Int.self, from: document.root["n"]) == 3)
    }

    @Test func appliesTheDecoderConfigurationFromTheNode() throws {
        struct Meta: Decodable {
            let createdAt: Date
            let nestedValue: [String: Int]
        }
        var decoder = AemiJSON.JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[try #require(CodingUserInfoKey(rawValue: "tag"))] = "configured"
        let document = try AemiJSON.parse(envelope)
        let meta = try decoder.decode(Meta.self, from: document.root["meta"])
        #expect(meta.createdAt == Date(timeIntervalSince1970: 1_790_157_600))
        #expect(meta.nestedValue == ["deepKey": 5])
        #expect(try decoder.decode(Tagged.self, from: document.root["id"]) == Tagged(value: 7, tag: "configured"))
    }

    @Test func takesTheFastPathForAMacroType() throws {
        let document = try AemiJSON.parse(#"{"result":{"contents":"x","line":4}}"#)
        #expect(
            try AemiJSON.JSONDecoder().decode(FastHover.self, from: document.root["result"])
                == FastHover(contents: "x", line: 4))
    }

    @Test func countsTheDepthLimitFromTheNode() throws {
        // The node sits ten objects down, and decoding it takes four levels of its own: the value and
        // its three arrays. Counted from the root, no cap under fourteen would let it through.
        let deep = String(repeating: #"{"a":"#, count: 10) + "[[[1]]]" + String(repeating: "}", count: 10)
        let document = try AemiJSON.parse(deep)
        var node = document.root
        for _ in 0 ..< 10 { node = node["a"] }
        var decoder = AemiJSON.JSONDecoder()
        decoder.maxDecodingDepth = 4
        #expect(try decoder.decode([[[Int]]].self, from: node) == [[[1]]])
        decoder.maxDecodingDepth = 3
        #expect(throws: DecodingError.self) { try decoder.decode([[[Int]]].self, from: node) }
    }

    @Test func aMissingNodeThrowsValueNotFoundAndANullNodeDecodesAsNull() throws {
        let document = try AemiJSON.parse(envelope)
        let decoder = AemiJSON.JSONDecoder()
        let missing = #expect(throws: DecodingError.self) {
            try decoder.decode(Hover.self, from: document.root["absent"])
        }
        guard case .valueNotFound? = missing else {
            Issue.record("expected valueNotFound, got \(String(describing: missing))")
            return
        }
        #expect(try decoder.decode(Hover?.self, from: document.root["nothing"]) == nil)
    }

    @Test func decodesANodeOfADocumentReadInPlace() throws {
        func parseInPlace<Source: ByteSource & Sendable>(_ source: Source) throws -> JSONDocument {
            try AemiJSON.parse(source)
        }
        let document = try parseInPlace(Data(envelope.utf8))
        #expect(
            try AemiJSON.JSONDecoder().decode(Position.self, from: document.root["result"]["range"][index: 0])
                == Position(line: 1, character: 2))
    }
}
