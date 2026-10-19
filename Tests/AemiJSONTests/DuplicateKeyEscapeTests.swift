import AemiJSON
import AemiTestKit
import Foundation
import Testing

@testable import AemiJSONCore

// `duplicateKeys: .throwError` is how a consumer asks for a repeated key to be an error. The scanner used to
// hash and compare the raw, still-escaped key bytes, so two spellings of one key (`a` and `\u0061`) went
// undetected, and because a document accepted under `.throwError` is marked unique, lookups then took the
// FIRST match where `.useLast` and the reference implementation (`json5` 2.2.3) take the last (issue #3).
//
// Keys are one key when their DECODED bytes are equal, the same equality the lookups use. Two distinct
// code-point sequences stay distinct even when they normalize alike: `é` and `e` + U+0301 are two keys,
// exactly as in JavaScript.

/// One key and every way to write it between its quotes; all spellings of a key decode to `key`.
private struct KeySpellings {
    let key: String
    let bodies: [String]
}

/// Strict (RFC 8259) spellings, written as the body of a double-quoted key.
private let strictSpellings: [KeySpellings] = [
    KeySpellings(key: "a", bodies: ["a", "\\u0061"]),
    KeySpellings(key: "A", bodies: ["A", "\\u0041"]),
    KeySpellings(key: "ab", bodies: ["ab", "a\\u0062", "\\u0061b", "\\u0061\\u0062"]),
    KeySpellings(key: "é", bodies: ["é", "\\u00e9", "\\u00E9"]),
    KeySpellings(key: "e\u{301}", bodies: ["e\u{301}", "e\\u0301"]),
    KeySpellings(key: "😀", bodies: ["😀", "\\ud83d\\ude00", "\\uD83D\\uDE00"]),
    KeySpellings(key: "/", bodies: ["/", "\\/", "\\u002f", "\\u002F"]),
    KeySpellings(key: "\n", bodies: ["\\n", "\\u000a", "\\u000A"]),
    KeySpellings(key: "\t", bodies: ["\\t", "\\u0009"]),
    KeySpellings(key: "\"", bodies: ["\\\"", "\\u0022"]),
    KeySpellings(key: "\\", bodies: ["\\\\", "\\u005c", "\\u005C"]),
    KeySpellings(key: "a\nb", bodies: ["a\\nb", "a\\u000ab"]),
    KeySpellings(key: "\0", bodies: ["\\u0000"])
]

/// JSON5 spellings, each a complete key token (quotes included, or none for an identifier).
private let json5Spellings: [KeySpellings] = [
    KeySpellings(key: "a", bodies: ["a", "'a'", "\"a\"", "'\\u0061'", "\"\\u0061\"", "'\\x61'", "'\\a'", "'a\\\n'"]),
    KeySpellings(
        key: "ab", bodies: ["ab", "'ab'", "'a\\\nb'", "'a\\\r\nb'", "'a\\\u{2028}b'", "'a\\\u{2029}b'", "'\\x61b'"]),
    KeySpellings(key: "A", bodies: ["A", "'A'", "'\\x41'", "'\\u0041'"]),
    KeySpellings(key: "é", bodies: ["é", "'é'", "'\\u00e9'", "'\\xe9'", "'\\xE9'"]),
    KeySpellings(key: "\u{A0}", bodies: ["'\u{A0}'", "'\\u00a0'", "'\\xa0'"]),
    KeySpellings(key: "\u{2028}", bodies: ["'\u{2028}'", "'\\u2028'", "'\\\u{2028}\u{2028}'"]),
    KeySpellings(key: "\u{0B}", bodies: ["'\\v'", "'\\u000b'", "'\\x0b'"]),
    KeySpellings(key: "\0", bodies: ["'\\0'", "'\\u0000'", "'\\x00'"]),
    KeySpellings(key: "'", bodies: ["'\\''", "\"'\"", "'\\u0027'", "'\\x27'"]),
    KeySpellings(key: "$_k1", bodies: ["$_k1", "'$_k1'", "'\\x24_k1'"])
]

/// A spelling placed in a document: strict bodies sit in double quotes, JSON5 ones are whole tokens.
private struct Placed {
    let key: String
    let token: String
}

private func place(_ spellings: [KeySpellings], quoting: Bool) -> [Placed] {
    spellings.flatMap { group in group.bodies.map { Placed(key: group.key, token: quoting ? "\"\($0)\"" : $0) } }
}

/// Whether two placed spellings decode to the same bytes. Not `String ==`, which also equates canonically
/// equivalent strings (`é` and `e` + U+0301), keys JSON compares as different.
private func sameKey(_ first: Placed, _ second: Placed) -> Bool {
    first.key.utf8.elementsEqual(second.key.utf8)
}

private let throwError = JSONParseOptions(validation: .strict, duplicateKeys: .throwError)
private let json5ThrowError = JSONParseOptions(validation: .json5, duplicateKeys: .throwError)

struct DuplicateKeyEscapeTests {
    // The oracle for everything below: the decoder that already exists. A spelling table that disagrees with
    // it would be testing the table, so check the table first.
    @Test func everySpellingDecodesToItsKey() {
        expectDecodes(place(strictSpellings, quoting: true), options: .strict)
        expectDecodes(place(json5Spellings, quoting: false), options: .json5)
    }

    private func expectDecodes(_ placed: [Placed], options: JSONParseOptions) {
        for spelling in placed {
            let value = ReadRoute.tape.value(of: Array("{\(spelling.token):1}".utf8), options: options)
            #expect(
                value == .object([spelling.key: .int(1)]),
                "\(spelling.token) did not decode to \(spelling.key.debugDescription): \(String(describing: value))")
        }
    }

    @Test func throwErrorReportsTwoSpellingsOfOneKeyAndOnlyThose() {
        let spellings = place(strictSpellings, quoting: true)
        for first in spellings {
            for second in spellings {
                let document = "{\(first.token):1,\(second.token):2}"
                let parsed = try? AemiJSON.parse(document, options: throwError)
                #expect(
                    (parsed == nil) == sameKey(first, second),
                    "\(document): same key=\(sameKey(first, second)), rejected=\(parsed == nil)")
            }
        }
    }

    @Test func throwErrorReportsTwoJSON5SpellingsOfOneKeyAndOnlyThose() {
        let spellings = place(json5Spellings, quoting: false)
        for first in spellings {
            for second in spellings {
                let document = "{\(first.token):1,\(second.token):2}"
                let parsed = try? AemiJSON.parse(document, options: json5ThrowError)
                #expect(
                    (parsed == nil) == sameKey(first, second),
                    "\(document): same key=\(sameKey(first, second)), rejected=\(parsed == nil)")
            }
        }
    }

    @Test func theReportedOffsetIsTheStartOfTheSecondKey() {
        #expect(throws: JSONError.duplicateKey(at: 7)) {
            try AemiJSON.parse(#"{"a":1,"\u0061":2}"#, options: throwError)
        }
        #expect(throws: JSONError.duplicateKey(at: 12)) {
            try AemiJSON.parse(#"{"\u0061":1,"a":2}"#, options: throwError)
        }
        #expect(throws: JSONError.duplicateKey(at: 7)) {
            try AemiJSON.parse("{a: 1, '\\u0061': 2}", options: json5ThrowError)
        }
        #expect(throws: JSONError.duplicateKey(at: 13)) {
            try AemiJSON.parse(#"{"b":1,"a":2,"\u0061":3}"#, options: throwError)
        }
    }

    @Test func aDuplicateIsFoundWhereverTheSpellingsSitInTheObject() {
        let document = #"{"x":1,"\u0079":2,"z":3,"y":4}"#
        #expect(throws: JSONError.duplicateKey(at: 24)) { try AemiJSON.parse(document, options: throwError) }
        let nested = #"{"o":{"p":1,"q":{"k":0,"\u006b":1}}}"#
        #expect(throws: JSONError.self) { try AemiJSON.parse(nested, options: throwError) }
        let inArray = #"[{"k":0},{"k":0,"\u006b":1}]"#
        #expect(throws: JSONError.self) { try AemiJSON.parse(inArray, options: throwError) }
    }

    @Test func theSameKeyInDifferentObjectsIsNotADuplicate() throws {
        let document = #"{"a":{"\u0061":1},"b":{"a":2,"\u0062":3},"c":[{"a":1},{"\u0061":2}]}"#
        let parsed = try AemiJSON.parse(document, options: throwError)
        #expect(parsed.root["a"]["a"].int == 1)
        #expect(parsed.root["b"]["b"].int == 3)
    }

    @Test func keysThatDifferByCodePointsStayDistinctEvenWhenTheyNormalizeAlike() throws {
        // `é` (U+00E9) and `e` + U+0301 are equal as Swift Strings but different keys everywhere JSON is
        // compared, and the lookups compare bytes. Reporting them would reject a legal document.
        let document = "{\"\\u00e9\":1,\"e\\u0301\":2}"
        let parsed = try AemiJSON.parse(document, options: throwError)
        #expect(parsed.root["é"].int == 1)
        #expect(parsed.root["e\u{301}"].int == 2)
    }

    // The symptom that made this more than a missed error: the unique-keys shortcut returned the first match.
    @Test func useLastStillTakesTheLastValueForEscapedSpellings() {
        let strict = try? AemiJSON.parse(#"{"a":1,"\u0061":2}"#)
        #expect(strict?.root["a"].int == 2)
        let json5 = try? AemiJSON.parse("{a: 1, '\\u0061': 2}", options: .json5)
        #expect(json5?.root["a"].int == 2)
    }

    @Test func aDocumentWithoutDuplicatesReadsTheSameUnderBothStrategies() throws {
        let document = #"{"\u0061":1,"b":2,"\u00e9":3,"c\u0064":4}"#
        let unique = try AemiJSON.parse(document, options: throwError)
        let last = try AemiJSON.parse(document)
        for key in ["a", "b", "é", "cd"] {
            #expect(unique.root[key].int == last.root[key].int, "\(key)")
        }
        #expect(unique.root["cd"].int == 4)
    }

    @Test func theDecoderReportsAnEscapedDuplicateInsteadOfDecodingTheFirstValue() throws {
        struct Settings: Decodable, Equatable { let a: Int }
        var decoder = AemiJSON.JSONDecoder()
        decoder.options.duplicateKeys = .throwError
        #expect(throws: JSONError.self) { try decoder.decode(Settings.self, from: Data(#"{"a":1,"\u0061":2}"#.utf8)) }
        decoder.allowsJSON5 = true
        #expect(throws: JSONError.self) { try decoder.decode(Settings.self, from: Data("{a: 1, '\\u0061': 2}".utf8)) }
        decoder.options.duplicateKeys = .useLast
        #expect(try decoder.decode(Settings.self, from: Data("{a: 1, '\\u0061': 2}".utf8)) == Settings(a: 2))
    }

    @Test func theIJSONPresetRejectsEscapedDuplicates() {
        #expect(throws: JSONError.self) { try AemiJSON.parse(#"{"a":1,"\u0061":2}"#, options: .iJSON) }
    }

    @Test func lenientDecodesEscapesTheSameWayForDuplicateDetection() {
        let lenient = JSONParseOptions(validation: .lenient, duplicateKeys: .throwError)
        // Lenient `\q` decodes to `q`, so these are one key.
        #expect(throws: JSONError.self) { try AemiJSON.parse(#"{"q":1,"\q":2}"#, options: lenient) }
        #expect(throws: JSONError.self) { try AemiJSON.parse(#"{"a":1,"\u0061":2}"#, options: lenient) }
        #expect((try? AemiJSON.parse(#"{"q":1,"\r":2}"#, options: lenient)) != nil)
    }

    @Test func identicalEscapedKeysAreStillDuplicatesEvenWhenLenientBytesAreNotValidUTF8() {
        // Raw-byte equality was the old test and still holds: the same escaped bytes, twice. Lenient mode
        // does not validate UTF-8, so the decoded bytes include the stray 0xFF as they stand.
        let lenient = JSONParseOptions(validation: .lenient, duplicateKeys: .throwError)
        let bytes: [UInt8] =
            Array(#"{"\u0061"#.utf8) + [0xFF] + Array(#"":1,"\u0061"#.utf8) + [0xFF] + Array(#"":2}"#.utf8)
        #expect(throws: JSONError.self) { try AemiJSON.parse(bytes, options: lenient) }
        let distinct: [UInt8] =
            Array(#"{"\u0061"#.utf8) + [0xFF] + Array(#"":1,"\u0061"#.utf8) + [0xFE] + Array(#"":2}"#.utf8)
        #expect((try? AemiJSON.parse(distinct, options: lenient)) != nil)
    }

    @Test func manyDistinctEscapedKeysAreNotFalseDuplicatesAndTheLastSpellingIsStillCaught() throws {
        // 2,000 keys, each written with an escape: a hash bucket that mixed decoded and raw keys would
        // report a false duplicate here, or miss the real one at the end.
        var members: [String] = []
        for index in 0 ..< 2_000 { members.append("\"\\u006b\(index)\":\(index)") }
        let unique = "{" + members.joined(separator: ",") + "}"
        let parsed = try AemiJSON.parse(unique, options: throwError)
        #expect(parsed.root["k1999"].int == 1999)
        #expect(parsed.root["k0"].int == 0)
        let repeated = "{" + members.joined(separator: ",") + ",\"k1234\":0}"
        #expect(throws: JSONError.self) { try AemiJSON.parse(repeated, options: throwError) }
    }

    @Test func aVeryLongEscapedKeyIsComparedWithoutLimits() {
        let body = String(repeating: "x", count: 300_000)
        let escaped = "\\u0078" + body.dropFirst()
        let document = "{\"\(body)\":1,\"\(escaped)\":2}"
        #expect(throws: JSONError.self) { try AemiJSON.parse(document, options: throwError) }
        let differing = "{\"\(body)\":1,\"\(escaped)y\":2}"
        #expect((try? AemiJSON.parse(differing, options: throwError)) != nil)
    }

    @Test func escapedKeysDoNotAllocatePerKey() {
        // The decoded form of a key is built in one reused scratch buffer. A per-key String or array would
        // add an allocation for every escaped key, so 500 escaped keys may cost only a handful more than
        // 500 plain ones. (Where allocation counting is unavailable this records nothing.)
        var plain: [String] = []
        var escaped: [String] = []
        for index in 0 ..< 500 {
            plain.append("\"k\(index)\":\(index)")
            escaped.append("\"\\u006b\(index)\":\(index)")
        }
        let plainBytes = Array(("{" + plain.joined(separator: ",") + "}").utf8)
        let escapedBytes = Array(("{" + escaped.joined(separator: ",") + "}").utf8)
        _ = try? AemiJSON.parse(plainBytes, options: throwError)  // warm up lazy one-time work
        _ = try? AemiJSON.parse(escapedBytes, options: throwError)
        let plainCount = minimumAllocations { _ = try? AemiJSON.parse(plainBytes, options: throwError) }
        let escapedCount = minimumAllocations { _ = try? AemiJSON.parse(escapedBytes, options: throwError) }
        guard let plainCount, let escapedCount else { return }
        #expect(escapedCount <= plainCount + 8, "plain \(plainCount) allocations, escaped \(escapedCount)")
    }
}

// Duplicate detection hashes and compares the DECODED bytes of a key, built by `appendUnescaped`, and compares
// an earlier escaped key through `unescapedEquals`. For two keys to be one key exactly when a lookup cannot
// tell them apart, the three decoders must agree. Pin them against each other over every short sequence of
// the escape forms each mode accepts.
struct DecodedKeyBytesTests {
    private static let strictPieces = [
        "a", "é", "😀", "\\n", "\\t", "\\\"", "\\\\", "\\/", "\\u0061", "\\u00e9", "\\u0000", "\\ud83d\\ude00",
        "\\ud800", "\\udc00", "\\ud800x"
    ]
    // Lenient accepts any escaped byte as itself, so `\q` joins the JSON set.
    private static let lenientPieces = strictPieces + ["\\q", "\\v", "\\x41", "\\0"]
    private static let json5Pieces = [
        "a", "é", "😀", "\\n", "\\v", "\\0", "\\x41", "\\xe9", "\\u0061", "\\ud83d\\ude00", "\\q", "\\'",
        "\\\n", "\\\r\n", "\\\r", "\\\u{2028}", "\\\u{2029}", "\\é", "\\😀", "\\ud800"
    ]

    /// Every concatenation of one to three pieces.
    private static func bodies(of pieces: [String]) -> [String] {
        var all: [String] = []
        for first in pieces {
            all.append(first)
            for second in pieces {
                all.append(first + second)
                for third in pieces { all.append(first + second + third) }
            }
        }
        return all
    }

    private func decodedBytes(_ body: String, json5: Bool) -> [UInt8] {
        let bytes = Array(body.utf8)
        var output = ContiguousArray<UInt8>()
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            JSONString.appendUnescaped(base, 0, bytes.count, json5: json5, replacing: &output)
        }
        return Array(output)
    }

    private func stringDecoded(_ body: String, json5: Bool) -> [UInt8] {
        let bytes = Array(body.utf8)
        let decoded = bytes.withUnsafeBufferPointer { buffer -> String in
            guard let base = buffer.baseAddress else { return "" }
            return json5 ? JSONString.unescapeJSON5(base, 0, bytes.count) : JSONString.unescape(base, 0, bytes.count)
        }
        return Array(decoded.utf8)
    }

    private func lookupAgrees(_ body: String, decoded: [UInt8], json5: Bool) -> Bool {
        let bytes = Array(body.utf8)
        return bytes.withUnsafeBufferPointer { source in
            decoded.withUnsafeBufferPointer { target in
                guard let base = source.baseAddress else { return decoded.isEmpty }
                let targetBase = target.baseAddress ?? base
                return json5
                    ? JSONString.unescapedEqualsJSON5(base, 0, bytes.count, targetBase, decoded.count)
                    : JSONString.unescapedEquals(base, 0, bytes.count, targetBase, decoded.count)
            }
        }
    }

    @Test(arguments: [false, true])
    func decodedBytesMatchTheStringDecoderAndTheLookupComparison(_ json5: Bool) {
        let pieces = json5 ? Self.json5Pieces : Self.lenientPieces
        for body in Self.bodies(of: pieces) {
            let decoded = decodedBytes(body, json5: json5)
            #expect(decoded == stringDecoded(body, json5: json5), "json5=\(json5) \(body.debugDescription)")
            #expect(lookupAgrees(body, decoded: decoded, json5: json5), "json5=\(json5) \(body.debugDescription)")
        }
    }

    @Test func theBufferIsRefilledNotAppendedTo() {
        var output = ContiguousArray<UInt8>([1, 2, 3])
        let bytes = Array("a\\u0062".utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            JSONString.appendUnescaped(base, 0, bytes.count, json5: false, replacing: &output)
        }
        #expect(Array(output) == Array("ab".utf8))
    }

    @Test func aRangeInsideALargerBufferIsDecodedInPlace() {
        // Keys sit at an offset in the document; nothing before or after the range may leak in.
        let bytes = Array(#"xx"\u0061b"yy"#.utf8)
        var output = ContiguousArray<UInt8>()
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            JSONString.appendUnescaped(base, 3, 7, json5: false, replacing: &output)
        }
        #expect(Array(output) == Array("ab".utf8))
    }
}
