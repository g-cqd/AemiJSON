import Foundation
import Testing

@testable import ADJSON

@Suite("JSONValue decoder")
struct JSONValueDecoderTests {
    private struct Sample: Codable, Equatable {
        struct Inner: Codable, Equatable {
            var x: Int
            var y: [Int]
        }
        var id: Int
        var name: String?
        var score: Double
        var active: Bool
        var tags: [String]
        var meta: [String: Int]
        var nested: Inner
    }

    private let sampleJSON =
        #"{"id":1,"name":"hi","score":3.5,"active":true,"tags":["a","b"],"meta":{"k":2},"nested":{"x":7,"y":[1,2,3]}}"#

    private func value(_ s: String) throws -> JSONValue { JSONValue(try ADJSON.parse(s).root) }

    // decode(from: JSONValue) equals decode(from: bytes) equals Foundation, for a representative type.
    @Test func matchesByteAndFoundationDecode() throws {
        let data = Data(sampleJSON.utf8)
        let viaBytes = try ADJSON.JSONDecoder().decode(Sample.self, from: data)
        let viaValue = try ADJSON.JSONDecoder().decode(Sample.self, from: value(sampleJSON))
        let viaFoundation = try Foundation.JSONDecoder().decode(Sample.self, from: data)
        #expect(viaValue == viaBytes)
        #expect(viaValue == viaFoundation)
    }

    @Test func topLevelScalarsArraysDictionaries() throws {
        #expect(try ADJSON.JSONDecoder().decode(Int.self, from: .int(42)) == 42)
        #expect(try ADJSON.JSONDecoder().decode(Double.self, from: .number(2.5)) == 2.5)
        #expect(try ADJSON.JSONDecoder().decode(String.self, from: .string("x")) == "x")
        #expect(try ADJSON.JSONDecoder().decode(Bool.self, from: .bool(true)))
        #expect(try ADJSON.JSONDecoder().decode([Int].self, from: value("[1,2,3]")) == [1, 2, 3])
        #expect(try ADJSON.JSONDecoder().decode([String: Double].self, from: value(#"{"a":1.5}"#)) == ["a": 1.5])
    }

    @Test func honorsKeyAndDateStrategies() throws {
        struct K: Codable, Equatable {
            var firstName: String
            var when: Date
        }
        var decoder = ADJSON.JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        let out = try decoder.decode(K.self, from: value(#"{"first_name":"x","when":1000}"#))
        #expect(out.firstName == "x")
        #expect(out.when == Date(timeIntervalSince1970: 1000))
    }

    @Test func decodesNullOptionalsAndMissingKeys() throws {
        struct O: Codable, Equatable {
            var a: Int?
            var b: Int?
        }
        let out = try ADJSON.JSONDecoder().decode(O.self, from: value(#"{"a":null}"#))
        #expect(out == O(a: nil, b: nil))
    }

    @Test func typeMismatchThrows() {
        #expect(throws: DecodingError.self) { try ADJSON.JSONDecoder().decode(Int.self, from: .string("x")) }
        #expect(throws: DecodingError.self) { try ADJSON.JSONDecoder().decode(Sample.self, from: .array([])) }
    }

    // The decoder is necessarily recursive; a low cap makes a deeply nested document fail closed
    // (throws) rather than overflow. 50 frames stay well inside the test thread's stack even under ASan.
    @Test func deepTreeFailsClosed() throws {
        struct Deep: Decodable {
            init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                while !c.isAtEnd { _ = try c.decode(Deep.self) }
            }
        }
        var decoder = ADJSON.JSONDecoder()
        decoder.maxDecodingDepth = 50
        let nested = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        let deep = JSONValue(try ADJSON.parse(nested, options: JSONParseOptions(maxDepth: 1000)).root)
        #expect(throws: DecodingError.self) { try decoder.decode(Deep.self, from: deep) }
    }
}
