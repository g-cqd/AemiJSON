import Foundation
import Testing

@testable import ADJSON

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
        profile: MProfile(bio: "yo", city: "NYC", followers: 0)),
]

@Test func macroGeneratedRoundTripsThroughFoundation() throws {
    let data = try ADJSON.JSONEncoder().encode(macroSamples)
    let viaFoundation = try Foundation.JSONDecoder().decode([MUser].self, from: data)
    let viaSelf = try ADJSON.JSONDecoder().decode([MUser].self, from: data)
    #expect(viaFoundation == macroSamples)
    #expect(viaSelf == macroSamples)
}

@Test func macroDecodeMatchesFoundation() throws {
    let foundationData = try Foundation.JSONEncoder().encode(macroSamples)
    let mine = try ADJSON.JSONDecoder().decode([MUser].self, from: foundationData)
    #expect(mine == macroSamples)
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
    let isFastDecode = dType as? any ADJSONFastDecodable.Type != nil
    let isFastEncode = dType as? any ADJSONFastEncodable.Type != nil
    #expect(isFastDecode)  // opted into the fast decode path
    #expect(!isFastEncode)  // but NOT the encode side
    let v = try ADJSON.JSONDecoder().decode(DInput.self, from: Data(#"{"id":7,"name":"x","tags":["a","b"]}"#.utf8))
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
    let isFastEncode = eType as? any ADJSONFastEncodable.Type != nil
    let isFastDecode = eType as? any ADJSONFastDecodable.Type != nil
    #expect(isFastEncode)
    #expect(!isFastDecode)
    let data = try ADJSON.JSONEncoder().encode(EOutput(id: 3, label: "hi"))
    #expect(String(decoding: data, as: UTF8.self) == #"{"id":3,"label":"hi"}"#)
}

// `@JSONCodable` still provides BOTH fast paths (regression after the split).
@Test func jsonCodableProvidesBothFastPaths() {
    let t: Any.Type = MUser.self
    let bothSides = (t as? any ADJSONFastDecodable.Type != nil) && (t as? any ADJSONFastEncodable.Type != nil)
    #expect(bothSides)
}
