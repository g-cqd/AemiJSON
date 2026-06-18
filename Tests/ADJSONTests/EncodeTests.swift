import Foundation
import OrderedCollections
import Testing

@testable import ADJSON

private struct Pt: Codable, Equatable {
    var x: Int
    var y: Int
}

private struct E: Codable, Equatable {
    var id: Int
    var title: String
    var note: String?
    var flag: Bool
    var ratio: Double
    var big: Int64
    var ints: [Int]
    var points: [Pt]
    var meta: [String: Int]
    var maybe: Pt?
}

private let samples: [E] = [
    E(
        id: 1, title: "a\"b\tc\nd", note: nil, flag: true, ratio: 3.5, big: -9_000_000_000,
        ints: [], points: [], meta: [:], maybe: nil),
    E(
        id: 2, title: "héllo", note: "set", flag: false, ratio: -0.25, big: 9_000_000_000,
        ints: [1, 2, 3], points: [Pt(x: 1, y: 2), Pt(x: 3, y: 4)], meta: ["k": 7], maybe: Pt(x: 9, y: 9)),
]

@Test func encodeRoundTripsThroughFoundationAndSelf() throws {
    let encoder = ADJSON.JSONEncoder()
    for v in samples {
        let data = try encoder.encode(v)
        let viaFoundation = try Foundation.JSONDecoder().decode(E.self, from: data)
        let viaSelf = try ADJSON.JSONDecoder().decode(E.self, from: data)
        #expect(viaFoundation == v)
        #expect(viaSelf == v)
    }
}

@Test func encodeArrayRoundTrips() throws {
    let data = try ADJSON.JSONEncoder().encode(samples)
    let back = try Foundation.JSONDecoder().decode([E].self, from: data)
    #expect(back == samples)
}

@Test func encodesTopLevelFragments() throws {
    let encoder = ADJSON.JSONEncoder()
    #expect(String(decoding: try encoder.encode(42), as: UTF8.self) == "42")
    #expect(String(decoding: try encoder.encode("hi"), as: UTF8.self) == "\"hi\"")
    let arr = try encoder.encode([1, 2, 3])
    #expect(try Foundation.JSONDecoder().decode([Int].self, from: arr) == [1, 2, 3])
}

@Test func omitsNilOptionalsLikeFoundation() throws {
    let v = E(
        id: 1, title: "t", note: nil, flag: true, ratio: 1, big: 0,
        ints: [], points: [], meta: [:], maybe: nil)
    let mine = try ADJSON.JSONEncoder().encode(v)
    let obj = try ADJSON.parse(mine).root
    #expect(obj.note.exists == false)
    #expect(obj.maybe.exists == false)
    #expect(obj.title.string == "t")
}

// A `Float` encodes in its own shortest 32-bit form (`Float.description`), not the noisy widened
// `Double` form (`Float(0.1)` was emitting "0.10000000149011612"). Non-integral values match
// Foundation; integral values keep ".0" (faithful, consistent with the Double policy).
@Test func encodesFloatAsShortestFloatForm() throws {
    struct F: Codable, Equatable { var v: Float }
    let cases: [(Float, String)] = [
        (0.1, "0.1"), (0.2, "0.2"), (3.14, "3.14"), (-0.25, "-0.25"), (1.5, "1.5"),
        (0.30000001, "0.3"), (1e20, "1e+20"), (2, "2.0"),
    ]
    let adj = ADJSON.JSONEncoder()
    for (x, s) in cases {
        let bytes = try adj.encode(F(v: x))
        #expect(String(decoding: bytes, as: UTF8.self) == "{\"v\":\(s)}")
        #expect(try ADJSON.JSONDecoder().decode(F.self, from: bytes) == F(v: x))
    }
    // Top-level fragment (single-value container) and array element (unkeyed container).
    #expect(String(decoding: try adj.encode(Float(0.1)), as: UTF8.self) == "0.1")
    #expect(String(decoding: try adj.encode([Float(0.1), 1.5]), as: UTF8.self) == "[0.1,1.5]")
}

@Test func rejectsNonFiniteDouble() {
    struct F: Encodable { var v: Double }
    #expect(throws: EncodingError.self) {
        try ADJSON.JSONEncoder().encode(F(v: .infinity))
    }
}

@Test func jsonValueRejectsNonFiniteOnEncode() {
    #expect(throws: EncodingError.self) { try JSONValue.number(.infinity).encoded() }
    #expect(throws: EncodingError.self) { try JSONValue.number(.nan).encoded() }
    #expect(throws: EncodingError.self) { try JSONValue.object(["v": .number(-.infinity)]).encoded() }
}

@Test func jsonValueEncodesFiniteNumbersLocaleIndependently() throws {
    let v = JSONValue.object(["i": .number(42), "d": .number(3.5), "neg": .number(-0.25)])
    let back = try JSONValue(parsing: try v.encoded())
    #expect(back == v)
    #expect(String(decoding: try JSONValue.number(3.5).encoded(), as: UTF8.self) == "3.5")
}

@Test func jsonValueEncodedHonorsOptionsProfile() throws {
    // .javaScript: ECMA-262 numbers (5.0 -> "5") and non-finite -> null.
    #expect(String(decoding: try JSONValue.number(5.0).encoded(options: .javaScript), as: UTF8.self) == "5")
    #expect(
        String(decoding: try JSONValue.number(.infinity).encoded(options: .javaScript), as: UTF8.self) == "null")
    // keyOrder: .sorted
    let obj = JSONValue.object(["b": .number(2), "a": .number(1)])
    #expect(
        String(decoding: try obj.encoded(options: JSONEncodingOptions(keyOrder: .sorted)), as: UTF8.self)
            == #"{"a":1.0,"b":2.0}"#)
    // The default profile stays strict.
    #expect(throws: EncodingError.self) { try JSONValue.number(.nan).encoded() }
}

// HTML-safe output must contain no raw `<` `>` `&` or U+2028/U+2029, yet round-trip to the original.
// (Assertions check bytes/round-trip rather than literal escape spellings, to stay robust.)
private let lineSep = String(Unicode.Scalar(0x2028)!)
private let paraSep = String(Unicode.Scalar(0x2029)!)

private func hasNoHTMLUnsafeBytes(_ bytes: [UInt8]) -> Bool {
    if bytes.contains(0x3C) || bytes.contains(0x3E) || bytes.contains(0x26) { return false }  // < > &
    var i = 0
    while i + 2 < bytes.count {
        if bytes[i] == 0xE2, bytes[i + 1] == 0x80, bytes[i + 2] == 0xA8 || bytes[i + 2] == 0xA9 { return false }
        i += 1
    }
    return true
}

@Test func htmlSafeEscapingEscapesUnsafeCharacters() throws {
    let samples: [JSONValue] = [
        .string("a<b>c&d"), .string("x" + lineSep + "y" + paraSep + "z"),
        .object(["a&b": .int(1)]), .array([.string("<x>"), .string("café 😀")]),
    ]
    for v in samples {
        let bytes = try v.encodedBytes(options: JSONEncodingOptions(escapeHTMLUnsafe: true))
        #expect(hasNoHTMLUnsafeBytes(bytes), "raw HTML-unsafe byte left in \(v)")
        #expect(try JSONValue(ADJSON.parse(bytes).root) == v, "round-trip changed \(v)")
    }
    // Off by default: unsafe characters pass through verbatim.
    let plain = try JSONValue.string("a<b>&").encodedBytes()
    #expect(plain.contains(0x3C) && plain.contains(0x26))
}

// The tape-cursor serializer (JSON.encodedBytes) must be byte-identical to materializing a
// JSONValue and serializing that, across every option combination — it backs the encoder's
// pretty/sorted path.
@Test func cursorEncodedBytesMatchesJSONValueAcrossOptions() throws {
    let docs = [
        #"{"b":2,"a":1,"c":[1,2,3],"nested":{"z":true,"y":null,"x":"hi"}}"#,
        #"[1,2.5,3e2,-0.0,1000000,9223372036854775807,99999999999999999999,"s","a/b","<x>",true,false,null]"#,
        #"{"deep":{"a":{"b":{"c":[{"d":1}]}}}}"#,
        "{}", "[]", #"{"only":[]}"#, "3.14", #""x""#,
        #"{"k":[{"m":1,"a":2},{"z":3}],"a":[]}"#,
    ]
    let optionSets: [JSONEncodingOptions] = [
        .rfc8259,
        JSONEncodingOptions(prettyPrinted: true),
        JSONEncodingOptions(keyOrder: .sorted),
        JSONEncodingOptions(keyOrder: .sorted, prettyPrinted: true),
        JSONEncodingOptions(numberFormat: .ecma262, keyOrder: .sorted, prettyPrinted: true),
        JSONEncodingOptions(escapeSlashes: true, prettyPrinted: true),
        JSONEncodingOptions(prettyPrinted: true, escapeHTMLUnsafe: true),
    ]
    for doc in docs {
        let root = try ADJSON.parse(doc).root
        let value = JSONValue(root)
        for opts in optionSets {
            #expect(try root.encodedBytes(options: opts) == value.encodedBytes(options: opts), "mismatch: \(doc)")
        }
    }
}

@Test func htmlSafeEscapingOnCodablePaths() throws {
    struct Doc: Codable { var html: String }
    var encoder = ADJSON.JSONEncoder()
    encoder.options = JSONEncodingOptions(escapeHTMLUnsafe: true)
    let bytes = [UInt8](try encoder.encode(Doc(html: "<p>&amp;</p>")))
    #expect(hasNoHTMLUnsafeBytes(bytes))
    #expect(try JSONValue(ADJSON.parse(bytes).root) == .object(["html": .string("<p>&amp;</p>")]))
    // Default encoder leaves them verbatim.
    let plain = [UInt8](try ADJSON.JSONEncoder().encode(Doc(html: "<p>&</p>")))
    #expect(plain.contains(0x3C) && plain.contains(0x26))
}

// Pinned to the main actor: `JSONValue.init(_:)` recurses on its fast path up to `maxFastDepth`
// (128) before switching to the explicit-stack builder, and each level is several stack frames
// (`materialize` → `forEachMember` → `withBytePointer` → …). ASan inflates those past the
// swift-testing cooperative-pool thread's ~512 KB budget, so the fast-path recursion would overflow
// before the iterative fallback engages. The 8 MB main-thread stack keeps it safe.
@MainActor @Test func jsonValueMaterializesDeepDocumentWithoutOverflow() throws {
    // Parsed with a large maxDepth, the document nests far deeper than the fast-path recursion cap;
    // `JSONValue.init(_:)` must hand the deep tail to its iterative builder rather than recursing all
    // the way down. (`==` on the result is itself recursive, so navigate iteratively instead.)
    let depth = 5_000
    let nested = String(repeating: #"{"x":"#, count: depth) + "1" + String(repeating: "}", count: depth)
    let root = try ADJSON.parse(nested, options: JSONParseOptions(maxDepth: depth + 1)).root
    var cursor = JSONValue(root)
    var levels = 0
    while case .object(let o) = cursor, let next = o["x"] {
        cursor = next
        levels += 1
    }
    #expect(levels == depth)
    #expect(cursor == .number(1))
}

// Pinned to the main actor (8 MB stack): round-tripping the tree re-materializes it
// (`JSONValue.init` recurses up to `maxFastDepth` = 128 on its fast path) and the deep eager tree is
// torn down by recursive ARC at scope exit — both overflow the swift-testing cooperative-pool
// thread's ~512 KB stack once ASan inflates frames.
@MainActor @Test func jsonValueEncodesDeepTreeIteratively() throws {
    // The iterative writer serializes well beyond the old 512 cap without recursing. 1000 nested
    // objects (≈2× Foundation's hard 512) round-trip through parse → materialize → re-encode.
    let depth = 1000
    var deep = JSONValue.number(1)
    for _ in 0..<depth { deep = .object(["x": deep]) }
    let bytes = try deep.encodedBytes()
    let reEncoded = try JSONValue(
        try ADJSON.parse(bytes, options: JSONParseOptions(maxDepth: depth + 1)).root
    ).encodedBytes()
    #expect(bytes == reEncoded)  // byte compare avoids deep traversal in the assertion
}

@Test func codableEncoderSortsKeysAndRejectsNullNil() throws {
    struct P: Encodable {
        var b = 2
        var a = 1
        var c = 3
    }
    // keyOrder: .sorted is now honored on the Codable path (via the JSONValue model).
    var sorted = ADJSON.JSONEncoder()
    sorted.options = JSONEncodingOptions(keyOrder: .sorted)
    #expect(String(decoding: try sorted.encode(P()), as: UTF8.self) == #"{"a":1,"b":2,"c":3}"#)

    // nilStrategy: .null still can't be honored (omitted nils are never seen) — must throw.
    var nullNil = ADJSON.JSONEncoder()
    nullNil.options = JSONEncodingOptions(nilStrategy: .null)
    #expect(throws: EncodingError.self) { try nullNil.encode(P()) }
}

@Test func codableEncoderPrettyPrintsLikeFoundation() throws {
    struct N: Encodable {
        var a = 1
        var b = [2, 3]
        var c = ["x": 9]
    }
    var adj = ADJSON.JSONEncoder()
    adj.prettyPrinted = true
    adj.options = JSONEncodingOptions(keyOrder: .sorted)  // deterministic key order for comparison
    let fnd = Foundation.JSONEncoder()
    fnd.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let mine = try adj.encode(N())
    let theirs = try fnd.encode(N())
    #expect(String(decoding: mine, as: UTF8.self) == String(decoding: theirs, as: UTF8.self))
}

// Pretty output in declaration order now streams in a single pass (no parse/re-emit). For values
// without integral Doubles it must be byte-identical to the former parse-then-re-emit path.
@Test func codableEncoderSinglePassPrettyMatchesReEmit() throws {
    var adj = ADJSON.JSONEncoder()
    adj.prettyPrinted = true
    for v in samples {  // `ratio` is 3.5 / -0.25 (non-integral), so no integer canonicalization gap
        let single = try adj.encode(v)
        let compact = try ADJSON.JSONEncoder().encode(v)
        let reEmit = try ADJSON.parse(compact).root.encodedBytes(options: JSONEncodingOptions(prettyPrinted: true))
        #expect(String(decoding: single, as: UTF8.self) == String(decoding: reEmit, as: UTF8.self))
    }
}

// Every encode mode shares one number policy: an integral `Double` stays `2.0`. Declaration-order
// pretty (single pass) and sorted+pretty (tape re-emit) now agree — the sorted route no longer
// canonicalizes it to `2`.
@Test func prettyEmitsIntegralDoubleConsistentlyAcrossModes() throws {
    struct F: Encodable {
        var a: Double = 2.0
        var b: Double = 3.5
    }
    var declaration = ADJSON.JSONEncoder()
    declaration.prettyPrinted = true
    #expect(
        String(decoding: try declaration.encode(F()), as: UTF8.self) == "{\n  \"a\" : 2.0,\n  \"b\" : 3.5\n}")

    var sorted = ADJSON.JSONEncoder()
    sorted.prettyPrinted = true
    sorted.options = JSONEncodingOptions(keyOrder: .sorted)
    #expect(
        String(decoding: try sorted.encode(F()), as: UTF8.self) == "{\n  \"a\" : 2.0,\n  \"b\" : 3.5\n}")
}

@Test func jsonValuePrettyPrintsNestedStructure() throws {
    let v = JSONValue.object(["a": .number(1), "b": .array([.number(2), .string("x")]), "e": .object([:])])
    let out = String(
        decoding: try v.encodedBytes(options: JSONEncodingOptions(keyOrder: .sorted, prettyPrinted: true)),
        as: UTF8.self)
    #expect(
        out == """
            {
              "a" : 1.0,
              "b" : [
                2.0,
                "x"
              ],
              "e" : {}
            }
            """)
}

@Test func jsonValueLosslessLargeIntegers() throws {
    // A 64-bit ID beyond 2^53 round-trips exactly via the `.int` case (the Double model could not).
    let maxInt = "9223372036854775807"  // Int64.max
    let vMax = try JSONValue(parsing: maxInt)
    #expect(vMax == .int(.max))
    #expect(String(decoding: try vMax.encodedBytes(), as: UTF8.self) == maxInt)

    let minInt = "-9223372036854775808"  // Int64.min
    let vMin = try JSONValue(parsing: minInt)
    #expect(vMin == .int(.min))
    #expect(String(decoding: try vMin.encodedBytes(), as: UTF8.self) == minInt)

    // `.int` and `.number` are one number domain: equal exactly when numerically equal.
    #expect(JSONValue.int(5) == .number(5))
    #expect(JSONValue.number(5) == .int(5))
    #expect(JSONValue.int(5) != .number(5.5))
    #expect(JSONValue.int(5) != .int(6))

    // A magnitude beyond Int64 (UInt64 range) falls back to `.number` (documented precision loss).
    if case .number = try JSONValue(parsing: "18446744073709551615") {  // UInt64.max
    } else {
        Issue.record("UInt64.max should fall back to .number")
    }
    // Fractions / exponents stay `.number`.
    if case .number = try JSONValue(parsing: "3.5") {} else { Issue.record("3.5 should be .number") }
    if case .number = try JSONValue(parsing: "10e2") {} else { Issue.record("10e2 should be .number") }

    // A mixed tree round-trips and equals a hand-built tree spelling integers either way.
    let tree = try JSONValue(parsing: #"{"id":9007199254740993,"ratio":0.5,"small":7}"#)
    #expect(tree == .object(["id": .int(9_007_199_254_740_993), "ratio": .number(0.5), "small": .number(7)]))
    #expect(
        String(decoding: try tree.encodedBytes(options: JSONEncodingOptions(keyOrder: .sorted)), as: UTF8.self)
            == #"{"id":9007199254740993,"ratio":0.5,"small":7}"#)
}

@Test func codableEncoderHonorsOptionsProfile() throws {
    struct F: Encodable {
        var a: Double
        var b: Double
    }
    var enc = ADJSON.JSONEncoder()
    enc.options = .javaScript
    // ECMA numbers + non-finite -> null, via the Codable path.
    #expect(String(decoding: try enc.encode(F(a: 5.0, b: .infinity)), as: UTF8.self) == #"{"a":5,"b":null}"#)
    // Default profile stays strict (rejects non-finite, keeps Double.description form).
    #expect(throws: EncodingError.self) { try ADJSON.JSONEncoder().encode(F(a: 1, b: .nan)) }
    #expect(String(decoding: try ADJSON.JSONEncoder().encode(F(a: 1.5, b: 2)), as: UTF8.self) == #"{"a":1.5,"b":2.0}"#)
}
