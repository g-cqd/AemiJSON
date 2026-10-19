import AemiJSON
import Foundation
import Testing

// JSON5 §8 counts U+00A0, U+FEFF and every Unicode space separator (Zs) as white space, and §6 makes
// U+2028 / U+2029 line terminators that end a `//` comment. The parser used to accept ASCII only, so a
// document the reference implementation (`json5` 2.2.3) reads was rejected here (issue #1).
//
// Every expectation below was probed against `json5` 2.2.3 under bun before it was written down, and
// each document is read by all three routes (tape, pull, push at several chunk sizes) because the
// scanners are separate implementations of one grammar.

/// The characters JSON5 treats as insignificant beyond ASCII, as UTF-8.
private enum SpaceSeparator {
    /// U+00A0, U+1680, U+2000...U+200A, U+202F, U+205F, U+3000 and U+FEFF.
    static let whiteSpace: [Unicode.Scalar] = {
        var values: [UInt32] = [0x00A0, 0x1680]
        values.append(contentsOf: 0x2000 ... 0x200A)
        values.append(contentsOf: [0x202F, 0x205F, 0x3000, 0xFEFF])
        return scalars(values)
    }()
    /// U+2028 and U+2029: line terminators, which are also insignificant between tokens.
    static let lineTerminators: [Unicode.Scalar] = scalars([0x2028, 0x2029])
    /// Every character the grammar skips.
    static let all: [Unicode.Scalar] = whiteSpace + lineTerminators
    /// Characters that look like white space but are not in the JSON5 set: NEL, Mongolian vowel
    /// separator, zero-width space, word joiner, and a general-punctuation dash.
    static let lookalikes: [Unicode.Scalar] = scalars([0x0085, 0x180E, 0x200B, 0x2060, 0x2010])

    private static func scalars(_ values: [UInt32]) -> [Unicode.Scalar] {
        values.compactMap { Unicode.Scalar($0) }
    }
}

private func bytes(_ scalar: Unicode.Scalar) -> [UInt8] { Array(String(scalar).utf8) }

private func hex(_ scalar: Unicode.Scalar) -> String { "U+" + String(scalar.value, radix: 16, uppercase: true) }

private let oneInA: JSONValue = .object(["a": .int(1)])

struct JSON5UnicodeWhitespaceTests {
    @Test(arguments: SpaceSeparator.all)
    func everySpaceSeparatorIsWhiteSpaceBetweenTokens(_ space: Unicode.Scalar) {
        let s = String(space)
        let twice = s + s
        expectEveryRoute("{a:\(s)1}", reads: oneInA)
        expectEveryRoute("\(s){a:1}\(s)", reads: oneInA)
        expectEveryRoute("{\(s)a\(s):\(s)1\(s)}", reads: oneInA)
        expectEveryRoute("{a:\(twice)1\(twice)}", reads: oneInA)
        expectEveryRoute("[\(s)1\(s),\(s)2\(s),\(s)]", reads: .array([.int(1), .int(2)]))
    }

    @Test(arguments: SpaceSeparator.all)
    func aSpaceSeparatorSitsBetweenAnUnquotedKeyAndItsColon(_ space: Unicode.Scalar) {
        // The identifier scanner took any non-ASCII byte as part of the name, so `a<NBSP>` was the key
        // "a\u{A0}". The reference ends the name at the space.
        let s = String(space)
        expectEveryRoute("{a\(s):1}", reads: oneInA)
        expectEveryRoute("{a\(s)\(s):1}", reads: oneInA)
        expectEveryRoute("{é\(s):1}", reads: .object(["é": .int(1)]))
        expectEveryRoute("{$x\(s)b:1}", reads: nil)  // two names with a space between them are not one key
    }

    @Test(arguments: SpaceSeparator.lineTerminators)
    func aLineSeparatorEndsALineComment(_ terminator: Unicode.Scalar) {
        let t = String(terminator)
        expectEveryRoute("// c\(t){a: 1}", reads: oneInA)
        expectEveryRoute("{a: 1 // c\(t)}", reads: oneInA)
        expectEveryRoute("// c\(t)// d\(t)[1]", reads: .array([.int(1)]))
        expectEveryRoute("{a /* x\(t) */ : 1}", reads: oneInA)  // inside a block comment it is just text
    }

    @Test func aLineCommentStillRunsToTheEndOfInputWithoutATerminator() {
        expectEveryRoute("// c é\u{2027}\u{202A}", reads: nil)  // neighbours of U+2028/2029 do not end it
        expectEveryRoute("{a: 1} // trailing é \u{2027}", reads: oneInA)
    }

    @Test(arguments: SpaceSeparator.lookalikes)
    func aCharacterThatOnlyLooksLikeWhiteSpaceIsStillRejected(_ lookalike: Unicode.Scalar) {
        // Guards the fix against accepting too much: json5 2.2.3 rejects each of these (`invalid character`).
        expectEveryRoute("{a:\(lookalike)1}", reads: nil)
        expectEveryRoute("\(lookalike){a:1}", reads: nil)
    }

    @Test(arguments: [JSONParseOptions.strict, .lenient])
    func strictAndLenientDocumentsStillRejectUnicodeWhiteSpace(_ options: JSONParseOptions) {
        for space in SpaceSeparator.all {
            expectEveryRoute("{\"a\":\(space)1}", options: options, reads: nil)
            // A leading U+FEFF is the byte-order mark, which every mode skips.
            if space.value != 0xFEFF { expectEveryRoute("\(space){\"a\":1}", options: options, reads: nil) }
        }
    }

    @Test(arguments: SpaceSeparator.all)
    func aSpaceSeparatorCutAtAnyChunkBoundaryIsReadNotRejected(_ space: Unicode.Scalar) {
        // The push reader must treat a multi-byte space cut by the end of a chunk as unfinished, not as
        // an unexpected character. Cut a document at every byte, in every pair of chunks.
        let document = Array("{a:".utf8) + bytes(space) + Array("1".utf8) + bytes(space) + Array("}".utf8)
        for cut in 0 ... document.count {
            let value = ReadRoute.pushValue(
                of: document, chunks: [0 ..< cut, cut ..< document.count], options: .json5)
            #expect(value == oneInA, "\(hex(space)) cut at byte \(cut) read as \(String(describing: value))")
        }
    }

    @Test(arguments: SpaceSeparator.lineTerminators)
    func aLineSeparatorCutAtAnyChunkBoundaryStillEndsTheComment(_ terminator: Unicode.Scalar) {
        let document = Array("// c".utf8) + bytes(terminator) + Array("{a: 1}".utf8)
        for cut in 0 ... document.count {
            let value = ReadRoute.pushValue(
                of: document, chunks: [0 ..< cut, cut ..< document.count], options: .json5)
            #expect(value == oneInA, "\(hex(terminator)) cut at byte \(cut) read as \(String(describing: value))")
        }
    }

    @Test(arguments: SpaceSeparator.all)
    func aTruncatedSpaceSeparatorIsRejectedAtEveryRoute(_ space: Unicode.Scalar) {
        // Every proper prefix of the sequence, at the end of the input: rejected, never read past the buffer.
        let sequence = bytes(space)
        for length in 1 ..< sequence.count {
            expectEveryRoute(Array("{a:".utf8) + sequence.prefix(length), reads: nil)
            expectEveryRoute(Array("{a:1}".utf8) + sequence.prefix(length), reads: nil)
        }
    }

    @Test func aMalformedSequenceThatStartsLikeASpaceSeparatorIsRejected() {
        let malformed: [[UInt8]] = [
            [0xC2, 0x41], [0xC2, 0x85], [0xE1, 0x9A, 0x41], [0xE1, 0xA0, 0x8E], [0xE2, 0x80, 0x8B],
            [0xE2, 0x80, 0xAA], [0xE2, 0x81, 0xA0], [0xE2, 0x82, 0xA0], [0xE3, 0x80, 0x81], [0xEF, 0xBB, 0xBE],
            [0xEF, 0xBB, 0x41], [0xC2], [0xE2, 0x80], [0xE2]
        ]
        for sequence in malformed {
            expectEveryRoute(Array("{a:".utf8) + sequence + Array("1}".utf8), reads: nil)
        }
    }

    @Test func aSpaceSeparatorOnlyDocumentIsAnEmptyDocument() {
        for space in SpaceSeparator.all {
            expectEveryRoute(String(space), reads: nil)
            expectEveryRoute("\(space)\(space)", reads: nil)
        }
    }

    @Test func replacingEveryAsciiSpaceWithEverySeparatorKeepsTheMeaning() {
        // Metamorphic: a JSON5 document with its insignificant ASCII spaces swapped for any separator
        // reads as the same value.
        let documents = [
            "{ a : 1 , b : [ 1 , 2 ] , 'c' : { d : null } }",
            "[ { a : 1 } , { b : 2 } , ]",
            "{ /* c */ a : 0x10 , b : .5 , c : Infinity }",
            "{ \"k\" : \"two words\" , z : true }"
        ]
        for document in documents {
            let plain = ReadRoute.tape.value(of: Array(document.utf8), options: .json5)
            #expect(plain != nil, "the ASCII form must parse: \(document)")
            for space in SpaceSeparator.all {
                // Only spaces outside strings: the replacement skips the quoted "two words".
                let swapped = document.replacingOccurrences(of: " : ", with: "\(space):\(space)")
                    .replacingOccurrences(of: " , ", with: "\(space),\(space)")
                    .replacingOccurrences(of: "{ ", with: "{\(space)")
                expectEveryRoute(swapped, reads: plain)
            }
        }
    }

    @Test func theDecoderAcceptsUnicodeWhiteSpaceInJSON5() throws {
        struct Settings: Decodable, Equatable { let a: Int }
        var decoder = AemiJSON.JSONDecoder()
        decoder.allowsJSON5 = true
        for space in SpaceSeparator.all {
            let data = Data(Array("{a:".utf8) + bytes(space) + Array("1}".utf8))
            #expect(try decoder.decode(Settings.self, from: data) == Settings(a: 1))
        }
        decoder.allowsJSON5 = false
        #expect(throws: JSONError.self) {
            try decoder.decode(Settings.self, from: Data(Array("{\"a\":".utf8) + bytes("\u{00A0}") + Array("1}".utf8)))
        }
    }
}
