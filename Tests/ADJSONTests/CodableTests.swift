import Foundation
import Testing

@testable import ADJSON

private struct Inner: Codable, Equatable {
    var k: String
    var n: Int?
}

private struct Sample: Codable, Equatable {
    var id: Int
    var name: String?
    var ok: Bool
    var score: Double
    var tags: [String]
    var inner: Inner
    var widths: [Int64]
    var unsigned: UInt64
}

@Test func decodesCodableMatchingFoundation() throws {
    let value = Sample(
        id: 7, name: "héllo", ok: true, score: 3.5,
        tags: ["a", "b\"c"], inner: Inner(k: "v", n: nil),
        widths: [-9_000_000_000, 9_000_000_000],
        unsigned: 18_000_000_000_000_000_000
    )
    let data = try Foundation.JSONEncoder().encode(value)

    let mine = try ADJSON.JSONDecoder().decode(Sample.self, from: data)
    let foundation = try Foundation.JSONDecoder().decode(Sample.self, from: data)

    #expect(mine == value)
    #expect(mine == foundation)
}

@Test func decodesArraysAndOptionals() throws {
    let json =
        #"[{"id":1,"ok":false,"score":1,"tags":[],"inner":{"k":"x"},"widths":[1],"unsigned":0},{"id":2,"name":"n","ok":true,"score":2.25,"tags":["t"],"inner":{"k":"y","n":5},"widths":[2,3],"unsigned":42}]"#
    let mine = try ADJSON.JSONDecoder().decode([Sample].self, from: Data(json.utf8))
    let foundation = try Foundation.JSONDecoder().decode([Sample].self, from: Data(json.utf8))
    #expect(mine == foundation)
    #expect(mine.count == 2)
    #expect(mine[1].inner.n == 5)
    #expect(mine[0].name == nil)
}

@Test func decoderThrowsOnTypeMismatch() {
    let json = #"{"id":"not an int","ok":true,"score":1,"tags":[],"inner":{"k":"x"},"widths":[],"unsigned":0}"#
    #expect(throws: DecodingError.self) {
        try ADJSON.JSONDecoder().decode(Sample.self, from: Data(json.utf8))
    }
}
