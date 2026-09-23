import Foundation
import Testing

@testable import AemiJSON

@JSONCodable
private struct MUser: Codable, Equatable {
    var id: Int
    var name: String
    var nick: String?
    var score: Double
    var active: Bool
    var tags: [String]
    var meta: [String: Int]
    var profile: MProfile
}

@JSONCodable
private struct MProfile: Codable, Equatable {
    var bio: String
    var city: String?
    var followers: Int64
}

private let macroSamples: [MUser] = [
    MUser(
        id: 1, name: "héllo", nick: nil, score: 3.5, active: true, tags: ["x", "y"], meta: ["k": 2],
        profile: MProfile(bio: "hi", city: nil, followers: 9_000_000_000)),
    MUser(
        id: 2, name: "b\"q", nick: "nick", score: -0.25, active: false, tags: [], meta: [:],
        profile: MProfile(bio: "yo", city: "NYC", followers: 0))
]

@Test func macroGeneratedRoundTripsThroughFoundation() throws {
    let data = try AemiJSON.JSONEncoder().encode(macroSamples)
    let viaFoundation = try Foundation.JSONDecoder().decode([MUser].self, from: data)
    let viaSelf = try AemiJSON.JSONDecoder().decode([MUser].self, from: data)
    #expect(viaFoundation == macroSamples)
    #expect(viaSelf == macroSamples)
}

@Test func macroDecodeMatchesFoundation() throws {
    let foundationData = try Foundation.JSONEncoder().encode(macroSamples)
    let mine = try AemiJSON.JSONDecoder().decode([MUser].self, from: foundationData)
    #expect(mine == macroSamples)
}

@JSONCodable
private struct MFloat: Codable, Equatable {
    var ratio: Float
    var name: String
}

// A `Float` field on the `@JSONCodable` fast path must emit the shortest 32-bit form (through the
// fixed `Float` fast conformance), not the widened-Double noise (`0.10000000149011612`).
@Test func macroFastPathEncodesFloatAsShortestForm() throws {
    let bytes = try AemiJSON.JSONEncoder().encode(MFloat(ratio: 0.1, name: "x"))
    #expect(String(decoding: bytes, as: UTF8.self) == #"{"ratio":0.1,"name":"x"}"#)
    #expect(try AemiJSON.JSONDecoder().decode(MFloat.self, from: bytes) == MFloat(ratio: 0.1, name: "x"))
}

// `@JSONDecodable` on a `Decodable`-ONLY type (note: not `Codable`/`Encodable`). That this file
// compiles is the proof the macro doesn't force the encode side.
@JSONDecodable
private struct DInput: Decodable, Equatable {
    var id: Int
    var name: String?
    var tags: [String]
}

@Test func jsonDecodableIsDecodeOnlyAndFast() throws {
    let dType: Any.Type = DInput.self
    let isFastDecode = dType as? any AemiJSONFastDecodable.Type != nil
    let isFastEncode = dType as? any AemiJSONFastEncodable.Type != nil
    #expect(isFastDecode)  // opted into the fast decode path
    #expect(!isFastEncode)  // but NOT the encode side
    let v = try AemiJSON.JSONDecoder().decode(DInput.self, from: Data(#"{"id":7,"name":"x","tags":["a","b"]}"#.utf8))
    #expect(v == DInput(id: 7, name: "x", tags: ["a", "b"]))
}

// `@JSONEncodable` on an `Encodable`-ONLY type.
@JSONEncodable
private struct EOutput: Encodable {
    var id: Int
    var label: String
}

@Test func jsonEncodableIsEncodeOnlyAndFast() throws {
    let eType: Any.Type = EOutput.self
    let isFastEncode = eType as? any AemiJSONFastEncodable.Type != nil
    let isFastDecode = eType as? any AemiJSONFastDecodable.Type != nil
    #expect(isFastEncode)
    #expect(!isFastDecode)
    let data = try AemiJSON.JSONEncoder().encode(EOutput(id: 3, label: "hi"))
    #expect(String(decoding: data, as: UTF8.self) == #"{"id":3,"label":"hi"}"#)
}

// `@JSONCodable` still provides BOTH fast paths (regression after the split).
@Test func jsonCodableProvidesBothFastPaths() {
    let t: Any.Type = MUser.self
    let bothSides = (t as? any AemiJSONFastDecodable.Type != nil) && (t as? any AemiJSONFastEncodable.Type != nil)
    #expect(bothSides)
}

// MARK: - Non-object input and backticked names

// Synthesized `Codable` rejects a non-object with `typeMismatch` before it reads a key. The fast path
// walks members with `forEachMember`, which visits nothing on a non-object, so a struct of optionals
// used to decode `42` as all-`nil`, and one with no fields as a value.
@JSONDecodable
private struct OnlyOptionals: Decodable, Equatable {
    var contents: String?
    var count: Int?
}

@JSONCodable
private struct NoFields: Codable, Equatable {}

/// `OnlyOptionals` without the macro: the generic container path, for comparison.
private struct OnlyOptionalsGeneric: Decodable, Equatable {
    var contents: String?
    var count: Int?
}

@Test(arguments: ["42", #""text""#, "[1]", "true", "null"])
func fastPathRejectsANonObjectLikeTheGenericPath(_ json: String) {
    let data = Data(json.utf8)
    let decoder = AemiJSON.JSONDecoder()
    let errors = [
        #expect(throws: DecodingError.self) { try decoder.decode(OnlyOptionals.self, from: data) },
        #expect(throws: DecodingError.self) { try decoder.decode(NoFields.self, from: data) },
        #expect(throws: DecodingError.self) { try decoder.decode(OnlyOptionalsGeneric.self, from: data) }
    ]
    for error in errors {
        if case .typeMismatch? = error { continue }
        Issue.record("\(json): expected typeMismatch, got \(String(describing: error))")
    }
}

// A property spelled with backticks is keyed by its name without them, as synthesized `Codable` keys
// it. The generated code used to splice the backticked spelling into its own identifiers and did not
// compile; a property named `c`, like the generated cursor parameter, broke it the same way.
@JSONCodable
private struct KeywordNamed: Codable, Equatable {
    var `default`: Int
    var `class`: String?
    var c: Bool
    var `let`: Int
    var `inout`: Int  // the one keyword a call site's argument label must still escape
    var `two words`: Int  // a raw identifier
}

@Test func fastPathKeysBacktickedPropertiesByTheirNames() throws {
    let json = #"{"default":1,"class":"x","c":true,"let":2,"inout":3,"two words":4}"#
    let value = KeywordNamed(default: 1, class: "x", c: true, let: 2, `inout`: 3, `two words`: 4)
    #expect(try AemiJSON.JSONDecoder().decode(KeywordNamed.self, from: Data(json.utf8)) == value)
    #expect(String(decoding: try AemiJSON.JSONEncoder().encode(value), as: UTF8.self) == json)
    #expect(try Foundation.JSONDecoder().decode(KeywordNamed.self, from: Data(json.utf8)) == value)
}
