import Foundation
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
