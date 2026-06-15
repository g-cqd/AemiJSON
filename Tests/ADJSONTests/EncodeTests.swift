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
            == #"{"a":1,"b":2}"#)
    // The default profile stays strict.
    #expect(throws: EncodingError.self) { try JSONValue.number(.nan).encoded() }
}

@Test func jsonValueMaterializesDeepDocumentWithoutOverflow() throws {
    // Parsed with a large maxDepth, the document nests far deeper than the call stack tolerates;
    // the now-iterative `JSONValue.init(_:)` must materialize it without recursing. (`==` on the
    // result is itself recursive, so navigate iteratively instead.)
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

@Test func jsonValueEncodesDeepTreeIteratively() throws {
    // The iterative writer serializes well beyond the old 512 cap without recursing. 1000 nested
    // objects (≈2× Foundation's hard 512) round-trip through parse → materialize → re-encode.
    // (Bounded at 1000 here only because the *test* thread's small stack limits the bulk ARC
    // deallocation of the deep JSONValue tree at scope exit — the writer itself is iterative and
    // handles hundreds of thousands of levels on the main thread; see the depth-safety harness.)
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

@Test func jsonValuePrettyPrintsNestedStructure() throws {
    let v = JSONValue.object(["a": .number(1), "b": .array([.number(2), .string("x")]), "e": .object([:])])
    let out = String(
        decoding: try v.encodedBytes(options: JSONEncodingOptions(keyOrder: .sorted, prettyPrinted: true)),
        as: UTF8.self)
    #expect(
        out == """
            {
              "a" : 1,
              "b" : [
                2,
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
