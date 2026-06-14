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
