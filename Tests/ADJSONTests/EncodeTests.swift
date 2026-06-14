import Foundation
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
