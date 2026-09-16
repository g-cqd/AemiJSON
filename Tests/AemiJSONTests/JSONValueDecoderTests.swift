import Foundation
import Testing

@testable import AemiJSON

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

    private func value(_ s: String) throws -> JSONValue { JSONValue(try AemiJSON.parse(s).root) }

    // decode(from: JSONValue) equals decode(from: bytes) equals Foundation, for a representative type.
    @Test func matchesByteAndFoundationDecode() throws {
        let data = Data(sampleJSON.utf8)
        let viaBytes = try AemiJSON.JSONDecoder().decode(Sample.self, from: data)
        let viaValue = try AemiJSON.JSONDecoder().decode(Sample.self, from: value(sampleJSON))
        let viaFoundation = try Foundation.JSONDecoder().decode(Sample.self, from: data)
        #expect(viaValue == viaBytes)
        #expect(viaValue == viaFoundation)
    }

    @Test func topLevelScalarsArraysDictionaries() throws {
        #expect(try AemiJSON.JSONDecoder().decode(Int.self, from: .int(42)) == 42)
        #expect(try AemiJSON.JSONDecoder().decode(Double.self, from: .number(2.5)) == 2.5)
        #expect(try AemiJSON.JSONDecoder().decode(String.self, from: .string("x")) == "x")
        #expect(try AemiJSON.JSONDecoder().decode(Bool.self, from: .bool(true)))
        #expect(try AemiJSON.JSONDecoder().decode([Int].self, from: value("[1,2,3]")) == [1, 2, 3])
        #expect(try AemiJSON.JSONDecoder().decode([String: Double].self, from: value(#"{"a":1.5}"#)) == ["a": 1.5])
    }

    @Test func honorsKeyAndDateStrategies() throws {
        struct K: Codable, Equatable {
            var firstName: String
            var when: Date
        }
        var decoder = AemiJSON.JSONDecoder()
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
        let out = try AemiJSON.JSONDecoder().decode(O.self, from: value(#"{"a":null}"#))
        #expect(out == O(a: nil, b: nil))
    }

    @Test func typeMismatchThrows() {
        #expect(throws: DecodingError.self) { try AemiJSON.JSONDecoder().decode(Int.self, from: .string("x")) }
        #expect(throws: DecodingError.self) { try AemiJSON.JSONDecoder().decode(Sample.self, from: .array([])) }
    }

    // The decoder is necessarily recursive; a low cap makes a deeply nested document fail closed
    // (throws) rather than overflow. The cap is set to 8 so the guard fires while the ~512 KB
    // cooperative-pool stack still has wide margin under ASan frame inflation (`@MainActor` does not
    // move the recursion onto the main thread under swift-testing; see DepthSafetyTests).
    @Test func deepTreeFailsClosed() throws {
        struct Deep: Decodable {
            init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                while !c.isAtEnd { _ = try c.decode(Deep.self) }
            }
        }
        var decoder = AemiJSON.JSONDecoder()
        decoder.maxDecodingDepth = 8  // sanitizer-safe: fires before the ~512 KB pool stack overflows under ASan
        let nested = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        let deep = JSONValue(try AemiJSON.parse(nested, options: JSONParseOptions(maxDepth: 1000)).root)
        #expect(throws: DecodingError.self) { try decoder.decode(Deep.self, from: deep) }
    }
}
