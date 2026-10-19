import Testing

@testable import AemiJSON

// RFC 8259 §8.1 lets a parser ignore a leading UTF-8 byte-order mark, and the tape parser, `JSONDecoder` and
// Foundation all do. The pull and push readers did not, so the same bytes were a document to one scanner and
// `unexpectedCharacter(239)` to the others. The libFuzzer differential oracle (tape == pull on accept/reject)
// found it on the first JSONTestSuite seed, `i_structure_UTF-8_BOM_empty_object.json`.

private let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

private let oneInA: JSONValue = .object(["a": .int(1)])

struct ReaderByteOrderMarkTests {
    @Test(arguments: [JSONParseOptions.strict, .lenient, .json5])
    func everyRouteSkipsALeadingByteOrderMark(_ options: JSONParseOptions) {
        expectEveryRoute(byteOrderMark + Array(#"{"a":1}"#.utf8), options: options, reads: oneInA)
        expectEveryRoute(byteOrderMark + Array("[]".utf8), options: options, reads: .array([]))
    }

    @Test(arguments: [JSONParseOptions.strict, .lenient, .json5])
    func aByteOrderMarkCutAtAnyChunkBoundaryIsStillSkipped(_ options: JSONParseOptions) {
        let document = byteOrderMark + Array(#"{"a":1}"#.utf8)
        for cut in 0 ... document.count {
            let value = ReadRoute.pushValue(of: document, chunks: [0 ..< cut, cut ..< document.count], options: options)
            #expect(value == oneInA, "cut at byte \(cut) read as \(String(describing: value))")
        }
    }

    @Test(arguments: [JSONParseOptions.strict, .lenient])
    func onlyALeadingByteOrderMarkIsSkippedOutsideJSON5(_ options: JSONParseOptions) {
        let body = Array(#"{"a":1}"#.utf8)
        expectEveryRoute(Array(" ".utf8) + byteOrderMark + body, options: options, reads: nil)
        expectEveryRoute(byteOrderMark + byteOrderMark + body, options: options, reads: nil)
        expectEveryRoute(body + byteOrderMark, options: options, reads: nil)
    }

    @Test(arguments: [JSONParseOptions.strict, .lenient, .json5])
    func anIncompleteByteOrderMarkIsRejected(_ options: JSONParseOptions) {
        let body = Array(#"{"a":1}"#.utf8)
        expectEveryRoute([0xEF, 0xBB] + body, options: options, reads: nil)
        expectEveryRoute([0xEF] + body, options: options, reads: nil)
        expectEveryRoute([0xEF, 0xBB], options: options, reads: nil)
        expectEveryRoute(byteOrderMark, options: options, reads: nil)  // a mark and nothing else is no document
    }

    @Test(arguments: [JSONParseOptions.strict, .lenient, .json5])
    func aByteOrderMarkDoesNotChangeWhatTheReadersOfAnEmptyDocumentSay(_ options: JSONParseOptions) {
        expectEveryRoute([UInt8](), options: options, reads: nil)
    }
}
