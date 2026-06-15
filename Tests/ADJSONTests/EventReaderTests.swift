import Testing

@testable import ADJSON

private func events(_ s: String, options: JSONParseOptions = .strict) throws -> [JSONEvent] {
    var reader = JSONEventReader(s, options: options)
    var out: [JSONEvent] = []
    while let event = try reader.next() { out.append(event) }
    return out
}

@Suite("JSONEventReader (SAX)")
struct JSONEventReaderTests {
    @Test func emitsEventsInDocumentOrder() throws {
        let evs = try events(#"{"a":1,"b":[true,null,"x"],"c":{}}"#)
        #expect(
            evs == [
                .beginObject,
                .key("a"), .number(1),
                .key("b"), .beginArray, .bool(true), .null, .string("x"), .endArray,
                .key("c"), .beginObject, .endObject,
                .endObject,
            ])
    }

    @Test func rootScalarsAndEmptyContainers() throws {
        #expect(try events("42") == [.number(42)])
        #expect(try events(#""hi\n""#) == [.string("hi\n")])
        #expect(try events("true") == [.bool(true)])
        #expect(try events("false") == [.bool(false)])
        #expect(try events("null") == [.null])
        #expect(try events(" [] ") == [.beginArray, .endArray])
        #expect(try events("{}") == [.beginObject, .endObject])
    }

    @Test func validatesAndRejectsMalformed() {
        #expect(throws: JSONError.self) { _ = try events("{") }
        #expect(throws: JSONError.self) { _ = try events("[1,]") }  // trailing comma (strict)
        #expect(throws: JSONError.self) { _ = try events(#"{"a":1} x"#) }  // trailing data
        #expect(throws: JSONError.self) { _ = try events("01") }  // leading zero
        #expect(throws: JSONError.self) { _ = try events(#""\x""#) }  // invalid escape
        #expect(throws: JSONError.self) { _ = try events("") }  // empty
        #expect(throws: JSONError.self) { _ = try events(#"{"a" 1}"#) }  // missing colon
    }

    @Test func decodingMatchesTapeParser() throws {
        let evs = try events(#"{"n":-12.5,"e":1e3,"u":"café","big":9007199254740993}"#)
        #expect(evs.contains(.number(-12.5)))
        #expect(evs.contains(.number(1000)))
        #expect(evs.contains(.string("café")))
        // Multibyte CJK string content round-trips.
        #expect(try events(#"["日本語"]"#) == [.beginArray, .string("日本語"), .endArray])
    }

    @Test func deeplyNestedStreamsWithoutOverflow() throws {
        let depth = 10_000
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        var reader = JSONEventReader(nested, options: JSONParseOptions(maxDepth: depth + 1))
        var begins = 0
        var ends = 0
        while let event = try reader.next() {
            if event == .beginArray { begins += 1 } else if event == .endArray { ends += 1 }
        }
        #expect(begins == depth)
        #expect(ends == depth)
        // The default depth cap still rejects over-deep input cleanly.
        var capped = JSONEventReader(String(repeating: "[", count: 600))
        #expect(throws: JSONError.self) {
            while try capped.next() != nil {}
        }
    }

    @Test func returnsNilStablyAfterEnd() throws {
        var reader = JSONEventReader("[1]")
        #expect(try reader.next() == .beginArray)
        #expect(try reader.next() == .number(1))
        #expect(try reader.next() == .endArray)
        #expect(try reader.next() == nil)
        #expect(try reader.next() == nil)  // idempotent at EOF
    }
}

private func saxEvents(_ bytes: [UInt8]) throws -> [JSONEvent] {
    var reader = JSONEventReader(bytes)
    var out: [JSONEvent] = []
    while let event = try reader.next() { out.append(event) }
    return out
}

private func streamEvents(_ bytes: [UInt8], chunkSize: Int) throws -> [JSONEvent] {
    var reader = JSONEventStreamReader()
    var out: [JSONEvent] = []
    var idx = 0
    while idx < bytes.count {
        let end = min(idx + chunkSize, bytes.count)
        out += try reader.feed(Array(bytes[idx..<end]))
        idx = end
    }
    out += try reader.finish()
    return out
}

@Suite("JSONEventStreamReader (chunked)")
struct JSONEventStreamReaderTests {
    private let documents = [
        #"{"a":1,"b":[true,null,"x\n"],"c":{"d":-12.5e3},"u":"café"}"#,
        #"[1,2,3,[4,[5,6]],{"k":"v"}]"#,
        #"{"emoji":"🎉","big":9007199254740993,"neg":-0.5}"#,
        "  42  ",
        #""日本語のテキスト""#,
        "[]",
        "{}",
        #"{"nested":{"deep":{"value":[1,2,{"x":true}]}}}"#,
    ]

    @Test func chunkBoundaryInvarianceAcrossEveryChunkSize() throws {
        for document in documents {
            let bytes = Array(document.utf8)
            let reference = try saxEvents(bytes)
            // Feed the document in every fixed chunk size from 1 byte up to the whole document.
            for chunk in 1...bytes.count {
                #expect(try streamEvents(bytes, chunkSize: chunk) == reference, "chunk=\(chunk) doc=\(document)")
            }
        }
    }

    @Test func splitAtEveryOffsetIntoTwoChunks() throws {
        let bytes = Array(#"{"name":"a\tbé","vals":[1.5e-3,42,-7],"ok":true}"#.utf8)
        let reference = try saxEvents(bytes)
        for split in 0...bytes.count {
            var reader = JSONEventStreamReader()
            var out = try reader.feed(Array(bytes[0..<split]))
            out += try reader.feed(Array(bytes[split..<bytes.count]))
            out += try reader.finish()
            #expect(out == reference, "split at \(split)")
        }
    }

    @Test func rejectsTruncatedAndMalformed() {
        func runToFinish(_ chunks: [String]) throws {
            var reader = JSONEventStreamReader()
            for chunk in chunks { _ = try reader.feed(chunk) }
            _ = try reader.finish()
        }
        #expect(throws: JSONError.self) { try runToFinish([#"{"a":1"#]) }  // truncated object
        #expect(throws: JSONError.self) { try runToFinish(["[1,2,]"]) }  // trailing comma
        #expect(throws: JSONError.self) { try runToFinish(["tru"]) }  // truncated literal
        #expect(throws: JSONError.self) { try runToFinish(["{", "}", "x"]) }  // trailing data
        #expect(throws: JSONError.self) { try runToFinish([#"{"a" 1}"#]) }  // missing colon
    }

    @Test func incompleteStreamHoldsTokensUntilComplete() throws {
        // A number inside an array is held until its terminator arrives — it might still grow across
        // feeds ("123" → "12345"), so no premature `.number` event is emitted.
        var reader = JSONEventStreamReader()
        #expect(try reader.feed("[123") == [.beginArray])
        #expect(try reader.feed("45,67]") == [.number(12345), .number(67), .endArray])
        #expect(try reader.finish().isEmpty)

        // A string split mid-content and mid-escape is reassembled.
        var stream = JSONEventStreamReader()
        var events = try stream.feed(#"["ab\"#)  // ends on a lone backslash
        events += try stream.feed(#"tcd"]"#)
        events += try stream.finish()
        #expect(events == [.beginArray, .string("ab\tcd"), .endArray])
    }
}
