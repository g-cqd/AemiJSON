import Foundation
import Synchronization
import Testing

@testable import AemiJSON

// Custom key strategies (AemiJSON's `(String) -> String` form) plus the fix that routes the
// @JSONCodable fast path through the generic coders whenever a key strategy is active — so any key
// strategy (custom OR the existing convertSnakeCase) is honored for fast types too.

private struct PlainRec: Codable, Equatable {
    var firstName: String
    var ageYears: Int
}

@JSONCodable
private struct FastRec: Codable, Equatable {
    var firstName: String
    var ageYears: Int
}

@Test func customKeyEncodingTransformsEveryKey() throws {
    var enc = AemiJSON.JSONEncoder()
    enc.keyEncodingStrategy = .custom { "x_" + $0 }
    for data in [
        try enc.encode(PlainRec(firstName: "a", ageYears: 1)), try enc.encode(FastRec(firstName: "a", ageYears: 1))
    ] {
        let root = try AemiJSON.parse(data).root
        #expect(root["x_firstName"].string == "a")
        #expect(root["x_ageYears"].int == 1)
        #expect(!root["firstName"].exists)  // the untransformed key must not appear
    }
}

@Test func customKeyDecodingTransformsEveryKey() throws {
    let json = Array(#"{"x_firstName":"a","x_ageYears":1}"#.utf8)
    var dec = AemiJSON.JSONDecoder()
    dec.keyDecodingStrategy = .custom { String($0.dropFirst(2)) }  // strip the "x_" prefix
    #expect(try dec.decode(PlainRec.self, from: json) == PlainRec(firstName: "a", ageYears: 1))
    #expect(try dec.decode(FastRec.self, from: json) == FastRec(firstName: "a", ageYears: 1))
    // The JSONValue decode path honors it too.
    let value = try JSONValue(AemiJSON.parse(json).root)
    #expect(try dec.decode(PlainRec.self, from: value) == PlainRec(firstName: "a", ageYears: 1))
}

@Test func customKeyRoundTrips() throws {
    var enc = AemiJSON.JSONEncoder()
    enc.keyEncodingStrategy = .custom { "x_" + $0 }
    var dec = AemiJSON.JSONDecoder()
    dec.keyDecodingStrategy = .custom { String($0.dropFirst(2)) }
    let plain = PlainRec(firstName: "z", ageYears: 9)
    #expect(try dec.decode(PlainRec.self, from: Array(enc.encode(plain))) == plain)
    let fast = FastRec(firstName: "z", ageYears: 9)
    #expect(try dec.decode(FastRec.self, from: Array(enc.encode(fast))) == fast)
}

@Test func snakeCaseStrategiesNowHonoredForFastTypes() throws {
    // Regression: the @JSONCodable fast path previously byte-matched literal keys, ignoring the key
    // strategy. It now routes to the generic path when a strategy is set.
    let snake = Array(#"{"first_name":"a","age_years":1}"#.utf8)
    var dec = AemiJSON.JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    #expect(try dec.decode(FastRec.self, from: snake) == FastRec(firstName: "a", ageYears: 1))
    #expect(try dec.decode(PlainRec.self, from: snake) == PlainRec(firstName: "a", ageYears: 1))

    var enc = AemiJSON.JSONEncoder()
    enc.keyEncodingStrategy = .convertToSnakeCase
    let root = try AemiJSON.parse(enc.encode(FastRec(firstName: "a", ageYears: 1))).root
    #expect(root["first_name"].string == "a")
    #expect(root["age_years"].int == 1)
}

@Test func defaultKeysUnaffected() throws {
    // No strategy → fast path + verbatim keys (the common case is untouched).
    let data = try AemiJSON.JSONEncoder().encode(FastRec(firstName: "a", ageYears: 1))
    let root = try AemiJSON.parse(data).root
    #expect(root["firstName"].string == "a")
    #expect(try AemiJSON.JSONDecoder().decode(FastRec.self, from: data) == FastRec(firstName: "a", ageYears: 1))
}

/// Counts the keys a custom key-decoding strategy converts.
private final class ConversionCounter: Sendable {
    private let count = Atomic<Int>(0)
    var conversions: Int { count.load(ordering: .relaxed) }
    func convert(_ key: String) -> String {
        count.wrappingAdd(1, ordering: .relaxed)
        return key.lowercased()
    }
}

private struct TwelveFields: Decodable, Equatable {
    let a, b, c, d, e, f, g, h, i, j, k, l: Int
}

// A key strategy converts each JSON key once per object. Before, every field lookup converted every
// key of the object again: 144 conversions for these 12 fields.
@Test func keyDecodingStrategyConvertsEachKeyOncePerObject() throws {
    let keys = "ABCDEFGHIJKL".map(String.init)
    let json = "{" + keys.enumerated().map { #""\#($1)":\#($0)"# }.joined(separator: ",") + "}"
    let counter = ConversionCounter()
    var decoder = AemiJSON.JSONDecoder()
    decoder.keyDecodingStrategy = .custom { counter.convert($0) }
    let decoded = try decoder.decode(TwelveFields.self, from: Data(json.utf8))
    #expect(decoded == TwelveFields(a: 0, b: 1, c: 2, d: 3, e: 4, f: 5, g: 6, h: 7, i: 8, j: 9, k: 10, l: 11))
    #expect(counter.conversions == keys.count)
}

// Converting once per object keeps last-value-wins for keys that collide after conversion.
@Test func keyDecodingStrategyKeepsTheLastOfCollidingKeys() throws {
    struct Named: Decodable, Equatable { let firstName: String }
    var decoder = AemiJSON.JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let json = #"{"first_name":"a","firstName":"b","first__name":"c"}"#  // all three convert to firstName
    #expect(try decoder.decode(Named.self, from: Data(json.utf8)) == Named(firstName: "c"))
}
