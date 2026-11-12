import AemiJSON
import Testing

// Where each node sits in its source (for an editor that changes one value and keeps the rest of
// the file as written: comments, trailing commas, key style). A node's range is its complete text
// (a string's quotes included, a container's brackets); a key's range includes its quotes when it
// has them, and is the bare name when it has none.

private func parsed(_ text: String) throws -> (JSONDocument, [UInt8]) {
    let bytes = Array(text.utf8)
    var options = JSONParseOptions.json5
    options.recordsContainerSpans = true
    return (try AemiJSON.parse(bytes, options: options), bytes)
}

private func slice(_ bytes: [UInt8], _ range: Range<Int>?) -> String? {
    range.map { String(decoding: bytes[$0], as: UTF8.self) }
}

struct SourceRangeTests {
    @Test func everyKindOfValueHasItsCompleteText() throws {
        let text = #"{ "a": 1.5e3, 'b': 'it\'s', c: [true, null, -Infinity], "d": { "e": "x\"y" }, }"#
        let (document, bytes) = try parsed(text)
        let root = document.root
        #expect(slice(bytes, root["a"].sourceRange) == "1.5e3")
        #expect(slice(bytes, root["b"].sourceRange) == #"'it\'s'"#)
        #expect(slice(bytes, root["c"].sourceRange) == "[true, null, -Infinity]")
        #expect(slice(bytes, root["c"][index: 1].sourceRange) == "null")
        #expect(slice(bytes, root["d"]["e"].sourceRange) == #""x\"y""#)
        #expect(slice(bytes, root.sourceRange) == text)
        #expect(root["missing"].sourceRange == nil)
    }

    @Test func keysAreFoundQuotedOrBareInDocumentOrder() throws {
        let (document, bytes) = try parsed(#"{"one": 1, 'two': 2, three: 3, /* a note */ "fo\u0075r": 4}"#)
        var seen: [(String, String?, String?)] = []
        document.root.forEachMemberWithKeyRange { key, keyRange, value in
            seen.append((key, slice(bytes, keyRange), slice(bytes, value.sourceRange)))
        }
        #expect(seen.map(\.0) == ["one", "two", "three", "four"])
        #expect(seen.map(\.1) == [#""one""#, "'two'", "three", #""fo\u0075r""#])
        #expect(seen.map(\.2) == ["1", "2", "3", "4"])
    }

    @Test func aContainerHasNoRangeWhenSpansWereNotRecorded() throws {
        let document = try AemiJSON.parse(Array(#"{"a": [1]}"#.utf8), options: .json5)
        #expect(document.root["a"].sourceRange == nil)
        #expect(document.root["a"][index: 0].sourceRange == 7 ..< 8, "a scalar's slot always has its place")
    }
}
